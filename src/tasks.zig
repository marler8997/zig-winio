//! What winio's Ios share: a `Scheduler` that runs tasks (`io.concurrent`, `io.async`) as fibers
//! on one thread, the std.Io operations that need only it, and building an Io's vtables: its own
//! (`Own`, `makeOwnVtable`) and a `Layer`'s.
//!
//! A task's waiting call parks it (`SwitchToFiber` back to the root fiber: the thread itself,
//! made a fiber, which runs the tasks), and the scheduler switches back once what it waits for
//! has happened. The root fiber can't
//! park, as it is the one that runs the tasks; what it does when it would wait is up to the Io
//! (`Scheduler.waitRoot`): it runs the loop meanwhile, except in a message loop's window procedures.
//!
//! A thread has at most one scheduler: `init` makes the thread a fiber, which it can be only
//! once. Operations find the calling thread's scheduler in the running fiber's data
//! (`currentFiber`); only starting a task uses std.Io's userdata, which is the scheduler of the
//! `io`. No thread-local storage.
//!
//! Threads: a task runs on its scheduler's thread, start to finish; no fiber changes threads.
//! What crosses threads: futex waits and wakes (`futex.zig`), awaiting and canceling a task, and
//! starting one on a scheduler that takes tasks from other threads (`Hooks.accepts_remote_tasks`).
//! Each nudges the scheduler's thread (`Scheduler.notify`) when it changes something that thread
//! may be waiting for.

/// Tests only (nothing in other builds): places to stop a thread inside a race window, so a test
/// can land the other side of the race there for certain.
pub const test_hooks = if (builtin.is_test) struct {
    /// A parked task was chosen to resume for its cancelation, and hasn't left its futex queue
    /// yet: a wake landing now goes to it.
    pub var cancel_window: ?*const fn () void = null;
    /// A futex waiter found its word still holding the expected value and is about to queue: a
    /// change and wake landing now must still end its wait. Called with the word.
    pub var enqueue_window: ?*const fn (word: *const u32) void = null;
    /// A cross-thread `cancel` found the task not done and is about to nudge its scheduler: the
    /// scheduler must not get through `deinit` meanwhile.
    pub var cancel_nudge_window: ?*const fn () void = null;
} else struct {};

/// Between a cross-thread `cancel`'s "not done yet" and its nudge, and a scheduler's `deinit`
/// (see `operations.cancel`).
var deinit_barrier: win32.RTL_SRWLOCK = .{ .Ptr = null };

/// What an Io tells its scheduler about how its thread waits.
pub const Hooks = struct {
    /// How the root fiber waits until `root` is ready (`isReady`). Called only when it
    /// isn't ready yet.
    waitRoot: *const fn (*Scheduler) void,
    /// Wakes the scheduler's thread from wherever it waits for its tasks (from any thread), so
    /// it runs `runReady`; it then calls `clearNotified` first.
    notify: *const fn (*Scheduler) void,
    /// Other threads may start tasks here (`io.concurrent` with this scheduler's io).
    accepts_remote_tasks: bool,
    /// Set for a scheduler that binds to a thread on first use (`bindOnFirstUse`), not in its
    /// Io's init: called on that thread, after it became a fiber, for the Io's own setup.
    bound: ?*const fn (*Scheduler) void = null,
};

pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    /// The Io's name for messages: "Fibers", "Iocp".
    name: []const u8,
    /// The root fiber: the one that runs the tasks.
    fiber: *anyopaque,
    /// That fiber's data.
    fiber_data: FiberData,
    tasks: std.ArrayList(*Task),
    /// What the root fiber waits for, while it does (`block`).
    root: Waiter,
    /// The root fiber's cancelation state. Nothing can request it (the fiber has no
    /// future), but it has a protection to swap.
    root_cancel: Cancel,
    hooks: Hooks,
    /// A notify is on its way (atomic): later ones until `clearNotified` add nothing.
    notified: bool,
    /// Tasks started from other threads, not yet given fibers (`runReady` does that): a list
    /// through `Task.next_incoming`, under `incoming_lock`.
    incoming: ?*Task,
    incoming_lock: win32.RTL_SRWLOCK,
    /// The scheduler's thread, for `checkThread`; 0 after deinit.
    safety_thread_id: SafetyThreadId,
    /// The thread bound to it (atomic): 0 before it is, `owner_deinited` after `deinit`.
    owner: u32,

    /// Makes the calling thread a fiber that runs `scheduler`'s tasks.
    /// A scheduler not yet bound to a thread (`attach`, or `bindOnFirstUse`, binds it). Needs
    /// nothing at runtime, so it can initialize a global.
    pub fn init(gpa: std.mem.Allocator, name: []const u8, hooks: Hooks) Scheduler {
        return .{
            .gpa = gpa,
            .name = name,
            .fiber = undefined,
            .fiber_data = .{ .scheduler = undefined, .task = null },
            .tasks = .empty,
            .root = .{},
            .root_cancel = .{},
            .hooks = hooks,
            .notified = false,
            .incoming = null,
            .incoming_lock = .{ .Ptr = null },
            .safety_thread_id = if (std.debug.runtime_safety) 0 else {},
            .owner = 0,
        };
    }

    /// `owner` once `deinit` has run: no thread can bind it again.
    const owner_deinited = std.math.maxInt(u32);

    /// Binds the scheduler to the calling thread, which becomes a fiber. It must not move after.
    pub fn attach(s: *Scheduler) void {
        if (@cmpxchgStrong(u32, &s.owner, 0, win32.GetCurrentThreadId(), .acq_rel, .monotonic) != null)
            std.debug.panic("winio.{s}: attached twice, or after deinit", .{s.name});
        s.becomeFiber();
    }

    /// For a scheduler that binds on first use (`Hooks.bound`): binds it to the calling thread
    /// if no thread has it yet. True if it's the calling thread's now (bound by this call);
    /// false if it isn't (another thread's, deinited, or one that doesn't bind on first use).
    pub fn bindOnFirstUse(s: *Scheduler) bool {
        const bound = s.hooks.bound orelse return false;
        if (@cmpxchgStrong(u32, &s.owner, 0, win32.GetCurrentThreadId(), .acq_rel, .monotonic) != null) return false;
        s.becomeFiber();
        bound(s);
        return true;
    }

    fn becomeFiber(s: *Scheduler) void {
        s.fiber_data.scheduler = s;
        s.safety_thread_id = currentSafetyThreadId();
        s.fiber = win32.ConvertThreadToFiber(&s.fiber_data) orelse switch (win32.GetLastError()) {
            .ERROR_ALREADY_FIBER => std.debug.panic("winio: this thread is a fiber already: it has a winio Io, or something else made it one", .{}),
            else => |err| win32.panicWin32("ConvertThreadToFiber", err),
        };
    }

    /// Back to a plain thread. Every task must have finished. A scheduler never bound (it binds on
    /// first use, and nothing used it) only can't be bound anymore.
    pub fn deinit(s: *Scheduler) void {
        if (@cmpxchgStrong(u32, &s.owner, 0, owner_deinited, .acq_rel, .monotonic) == null) return;
        s.checkThread();
        s.deleteFinished();
        if (s.tasks.items.len > 0) std.debug.panic("winio: deinit with {} tasks not finished", .{s.tasks.items.len});
        if (s.takeIncoming() != null) std.debug.panic("winio: deinit with tasks started from another thread that haven't run", .{});
        // Every task is done: wait out any `cancel` that saw one not done and is nudging.
        win32.AcquireSRWLockExclusive(&deinit_barrier);
        win32.ReleaseSRWLockExclusive(&deinit_barrier);
        s.tasks.deinit(s.gpa);
        if (0 == win32.ConvertFiberToThread()) win32.panicWin32("ConvertFiberToThread", win32.GetLastError());
        if (std.debug.runtime_safety) s.safety_thread_id = 0;
        @atomicStore(u32, &s.owner, owner_deinited, .release);
    }

    /// Whether `deinit` has run.
    pub fn isDeinited(s: *const Scheduler) bool {
        return @atomicLoad(u32, &s.owner, .acquire) == owner_deinited;
    }

    /// In a safe build, panics unless this is the calling thread's scheduler. Otherwise nothing.
    pub fn checkThread(s: *const Scheduler) void {
        if (!std.debug.runtime_safety) return;
        if (s.safety_thread_id != currentSafetyThreadId()) std.debug.panic("winio.{s} used on a thread it doesn't belong to, or after deinit", .{s.name});
    }

    /// Runs every task that can go on, until none can, starting those other threads started.
    /// Finished tasks' fibers are deleted.
    pub fn runReady(s: *Scheduler) void {
        std.debug.assert(currentFiber().? == &s.fiber_data);
        var ran = true;
        while (ran) {
            ran = false;
            s.startIncoming();
            var i: usize = 0;
            while (i < s.tasks.items.len) {
                const task = s.tasks.items[i];
                if (task.isDone()) {
                    s.remove(i);
                    continue;
                }
                i += 1;
                // A cancelable wait also ends on a cancelation request (`block`). The waiter
                // stays as it is: the task leaves the futex queue itself.
                if (task.waiter.isReady(win32.GetTickCount64())) {
                    task.woken_by_cancel = false;
                } else if (task.waiter.cancelable and task.cancel.isPending()) {
                    task.woken_by_cancel = true;
                } else continue;
                win32.SwitchToFiber(task.fiber);
                ran = true;
            }
        }
    }

    /// Wakes the scheduler's thread (from any thread) to look at its tasks again, unless a
    /// notify is on its way already.
    pub fn notify(s: *Scheduler) void {
        if (@atomicRmw(bool, &s.notified, .Xchg, true, .seq_cst)) return;
        s.hooks.notify(s);
    }

    /// The notify arrived: the next changes notify again. Called before looking at the tasks.
    ///
    /// An exchange, not a store: a waker stores its change (`woken`, a cancel request) and then
    /// exchanges `notified`, skipping the nudge if it was set. A plain store here could be
    /// reordered after the loop's reads of those changes (x86 reorders a store with a later
    /// load), so the loop could miss a change whose waker saw `notified` still set and stayed
    /// quiet: a lost wake. An exchange orders the reads after it, and sees the waker's exchange.
    pub fn clearNotified(s: *Scheduler) void {
        _ = @atomicRmw(bool, &s.notified, .Xchg, false, .seq_cst);
    }

    fn takeIncoming(s: *Scheduler) ?*Task {
        win32.AcquireSRWLockExclusive(&s.incoming_lock);
        defer win32.ReleaseSRWLockExclusive(&s.incoming_lock);
        defer s.incoming = null;
        return s.incoming;
    }

    /// Gives the tasks started from other threads their fibers, in the order they came.
    fn startIncoming(s: *Scheduler) void {
        // The list is newest first.
        var reversed: ?*Task = null;
        var next = s.takeIncoming();
        while (next) |task| {
            next = task.next_incoming;
            task.next_incoming = reversed;
            reversed = task;
        }
        while (reversed) |task| {
            reversed = task.next_incoming;
            s.adopt(task);
        }
    }

    /// Gives `task` its fiber and its place in the list: on the scheduler's thread.
    fn adopt(s: *Scheduler, task: *Task) void {
        task.fiber = win32.CreateFiber(0, &Task.entry, &task.fiber_data) orelse win32.panicWin32("CreateFiber", win32.GetLastError());
        s.tasks.append(s.gpa, task) catch @panic("out of memory");
    }

    /// Deletes the fibers of the tasks that finished, without running any.
    fn deleteFinished(s: *Scheduler) void {
        var i: usize = 0;
        while (i < s.tasks.items.len) {
            if (s.tasks.items[i].isDone()) s.remove(i) else i += 1;
        }
    }

    fn remove(s: *Scheduler, i: usize) void {
        const task = s.tasks.swapRemove(i);
        win32.DeleteFiber(task.fiber);
        task.unref();
    }

    /// The nearest deadline (GetTickCount64) a task or the root fiber waits for.
    pub fn nearestDeadline(s: *const Scheduler) ?u64 {
        var nearest = s.root.wait.deadline();
        for (s.tasks.items) |task| {
            const d = task.waiter.wait.deadline() orelse continue;
            nearest = if (nearest) |n| @min(n, d) else d;
        }
        return nearest;
    }

    /// Whether any task can run now.
    pub fn anyReady(s: *const Scheduler) bool {
        const now_ms = win32.GetTickCount64();
        for (s.tasks.items) |task| if (task.isDone() or task.waiter.isReady(now_ms)) return true;
        return false;
    }
};

/// A fiber run by a scheduler: `start(context, result)`. Its `*std.Io.AnyFuture`.
pub const Task = struct {
    fiber: *anyopaque,
    /// Its fiber's data: its scheduler, and itself.
    fiber_data: FiberData,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    /// The scheduler's, kept here: the task may outlive the scheduler (finished, but awaited
    /// after the scheduler's deinit), and its last owner frees it with this.
    gpa: std.mem.Allocator,
    /// Copies, allocated with `gpa` at the alignments std.Io gave.
    context: []u8,
    context_alignment: std.mem.Alignment,
    result: []u8,
    result_alignment: std.mem.Alignment,
    waiter: Waiter = .{},
    cancel: Cancel = .{},
    /// Its last wait ended on a cancelation request, not on what it waited for.
    woken_by_cancel: bool = false,
    /// 1 once `start` returned (atomic): the futex word an await waits on.
    done: u32 = 0,
    /// Two owners, each dropping its reference once done with the task: the scheduler (once it
    /// deleted the fiber) and the awaiter (once it took the result). The last one frees it.
    refs: u32 = 2,
    /// The next in `Scheduler.incoming`, for a task started from another thread.
    next_incoming: ?*Task = null,

    fn fromFuture(future: *std.Io.AnyFuture) *Task {
        return @ptrCast(@alignCast(future));
    }

    fn asFuture(task: *Task) *std.Io.AnyFuture {
        return @ptrCast(task);
    }

    fn isDone(task: *const Task) bool {
        return @atomicLoad(u32, &task.done, .acquire) != 0;
    }

    fn unref(task: *Task) void {
        if (@atomicRmw(u32, &task.refs, .Sub, 1, .acq_rel) != 1) return;
        const gpa = task.gpa;
        gpa.rawFree(task.context, task.context_alignment, @returnAddress());
        gpa.rawFree(task.result, task.result_alignment, @returnAddress());
        gpa.destroy(task);
    }

    fn entry(param: ?*anyopaque) callconv(.winapi) void {
        const data: *FiberData = @ptrCast(@alignCast(param));
        const task = data.task.?;
        task.start(task.context.ptr, task.result.ptr);
        @atomicStore(u32, &task.done, 1, .release);
        futex.wake(&task.done, std.math.maxInt(u32));
        // Back to the scheduler for good; it deletes this fiber.
        win32.SwitchToFiber(data.scheduler.fiber);
        unreachable;
    }
};

/// What a fiber waits for; the scheduler checks it after every wakeup.
pub const Wait = union(enum) {
    ready,
    /// `ptr.*` changed from `expected`, or woken, or the deadline (GetTickCount64) passed.
    futex: struct { ptr: *const u32, expected: u32, deadline: ?u64 },
    /// The deadline (GetTickCount64) passed.
    sleep: u64,
    /// The Io set this flag, on this thread (an I/O operation it started completed), or the
    /// deadline (GetTickCount64) passed.
    flag: struct { ptr: *const bool, deadline: ?u64 = null },

    fn deadline(wait: Wait) ?u64 {
        return switch (wait) {
            .futex => |f| f.deadline,
            .flag => |f| f.deadline,
            .sleep => |d| d,
            .ready => null,
        };
    }
};

/// A fiber's wait, and whether a futex wake ended it. Where it waits on a futex, it's queued in
/// the futex's bucket (`futex.zig`), and must not move until it leaves.
pub const Waiter = struct {
    wait: Wait = .ready,
    /// 1 once a futex wake ended the wait (atomic: the waker may be on another thread). Also the
    /// word a waiter that waits on its address (`Notify.address`) waits on.
    woken: u32 = 0,
    /// A cancelation request ends the wait too (`blockCancelable`).
    cancelable: bool = false,
    /// Who a wake nudges.
    notify: Notify = .address,
    /// The futex bucket's queue (`futex.zig`), under the bucket's lock.
    prev: ?*Waiter = null,
    next: ?*Waiter = null,
    queued: bool = false,

    pub fn isReady(w: *const Waiter, now_ms: u64) bool {
        return switch (w.wait) {
            .ready => true,
            .futex => |f| @atomicLoad(u32, &w.woken, .acquire) != 0 or @atomicLoad(u32, f.ptr, .acquire) != f.expected or (if (f.deadline) |d| now_ms >= d else false),
            .sleep => |d| now_ms >= d,
            .flag => |f| f.ptr.* or (if (f.deadline) |d| now_ms >= d else false),
        };
    }
};

/// Who a futex wake nudges, so the waiter's thread looks at it.
pub const Notify = union(enum) {
    /// A scheduler running its loop: a task, or an Iocp's root fiber.
    scheduler: *Scheduler,
    /// A thread blocked on the waiter's `woken` word (WaitOnAddress): a thread without a winio Io.
    address,

    /// Called by the waker, under the futex bucket's lock, with the waiter's `woken`.
    pub fn nudge(n: Notify, woken: *u32) void {
        switch (n) {
            // Running now on this thread, it will look anyway.
            .scheduler => |s| if (currentScheduler() != s) s.notify(),
            .address => win32.WakeByAddressSingle(woken),
        }
    }
};

/// What each of a scheduler's fibers carries as its fiber data (GetFiberData).
const FiberData = struct {
    scheduler: *Scheduler,
    /// Null for the root fiber.
    task: ?*Task,
};

/// The running fiber's data, or null on a thread that isn't a fiber (has no scheduler). A
/// thread that something else made a fiber isn't supported: its fiber data isn't a `FiberData`.
fn currentFiber() ?*FiberData {
    const teb = windows.teb();
    // The TEB's SameTebFlags bit HasFiberData: what IsThreadAFiber reads, without the call.
    const same_teb_flags: *const u16 = switch (builtin.cpu.arch) {
        .x86_64 => @ptrFromInt(@intFromPtr(teb) + 0x17EE),
        else => @compileError("winio: the TEB's SameTebFlags offset isn't known for this architecture"),
    };
    const is_fiber = same_teb_flags.* & 4 != 0;
    if (std.debug.runtime_safety) std.debug.assert(is_fiber == (win32.IsThreadAFiber() != 0));
    if (!is_fiber) return null;
    // GetFiberData: the running fiber's first field is its data.
    const fiber: *const *FiberData = @ptrCast(@alignCast(teb.NtTib.DUMMYUNIONNAME.FiberData));
    return fiber.*;
}

/// The calling thread's scheduler, if it has one.
pub fn currentScheduler() ?*Scheduler {
    const data = currentFiber() orelse return null;
    return data.scheduler;
}

/// The task running now on the calling thread: null on the root fiber, or on a thread
/// without a scheduler.
pub fn currentTask() ?*Task {
    const data = currentFiber() orelse return null;
    return data.task;
}

/// The calling fiber waits until `wait` is ready: a task parks; the root fiber does what
/// its Io says (`waitRoot`); a thread without a scheduler sleeps out a deadline, and panics if
/// nothing could end the wait.
pub fn block(wait: Wait) void {
    blockMaybeCancelable(wait, false) catch unreachable; // not cancelable
}

/// `block`, as a cancelation point: error.Canceled if the calling task has a cancelation request
/// (not blocked by its protection), made before or during the wait. Only a task can be
/// canceled; the root fiber has no future to cancel.
pub fn blockCancelable(wait: Wait) std.Io.Cancelable!void {
    return blockMaybeCancelable(wait, true);
}

fn blockMaybeCancelable(wait: Wait, cancelable: bool) std.Io.Cancelable!void {
    const data = currentFiber() orelse {
        var waiter: Waiter = .{ .wait = wait, .notify = .address };
        if (!enter(&waiter)) return;
        defer leave(&waiter);
        return waitOnAddress(&waiter);
    };
    const s = data.scheduler;
    if (data.task) |task| {
        if (cancelable) try task.cancel.check();
        task.waiter = .{ .wait = wait, .cancelable = cancelable, .notify = .{ .scheduler = s } };
        defer task.waiter = .{};
        if (!enter(&task.waiter)) return;
        defer leave(&task.waiter);
        win32.SwitchToFiber(s.fiber);
        std.debug.assert(currentTask() == task);
        if (task.woken_by_cancel) {
            task.woken_by_cancel = false;
            if (builtin.is_test) if (test_hooks.cancel_window) |hook| hook();
            leave(&task.waiter);
            // A wake that reached it anyway (between `runReady` choosing to cancel and `leave`)
            // goes to another waiter: the caller gives up what it waited for (a Mutex's unlock
            // wakes only one waiter), so the wake must not die with it. An extra wake is
            // harmless: futex waits may end spuriously.
            switch (task.waiter.wait) {
                .futex => |f| if (@atomicLoad(u32, &task.waiter.woken, .acquire) != 0) futex.wake(f.ptr, 1),
                else => {},
            }
            return task.cancel.check();
        }
        return;
    }
    s.root = .{ .wait = wait, .notify = .{ .scheduler = s } };
    defer s.root = .{};
    if (!enter(&s.root)) return;
    defer leave(&s.root);
    s.hooks.waitRoot(s);
}

/// Before `w` waits: false if it's ready already (no wait); a futex wait is queued then.
fn enter(w: *Waiter) bool {
    if (w.isReady(win32.GetTickCount64())) return false;
    return switch (w.wait) {
        .futex => |f| {
            if (builtin.is_test) if (test_hooks.enqueue_window) |hook| hook(f.ptr);
            return futex.enqueue(w);
        },
        else => true,
    };
}

/// After `w`'s wait ended, however it did: out of the futex's queue.
fn leave(w: *Waiter) void {
    switch (w.wait) {
        .futex => futex.leave(w),
        else => {},
    }
}

/// Blocks the thread until `w` is ready: a futex wait on its `woken` word (WaitOnAddress, woken
/// by `Notify.address`), anything else by sleeping out its deadline. For a thread that can't run
/// a loop meanwhile: one without a winio Io, or a Fibers' root fiber sleeping in a window
/// procedure.
pub fn waitOnAddress(w: *Waiter) void {
    while (true) {
        const now_ms = win32.GetTickCount64();
        if (w.isReady(now_ms)) return;
        const deadline = w.wait.deadline();
        if (builtin.single_threaded and deadline == null) std.debug.panic("winio: a thread without a winio Io waits for something nothing could end (single-threaded: no other thread can): a deadlock", .{});
        const timeout: u32 = if (deadline) |d| @intCast(@min(d -| now_ms, win32.INFINITE - 1)) else win32.INFINITE;
        switch (w.wait) {
            .futex => {
                var zero: u32 = 0;
                // FALSE on a timeout, which the loop sees.
                _ = win32.WaitOnAddress(&w.woken, &zero, @sizeOf(u32), timeout);
            },
            .sleep => win32.Sleep(timeout),
            // Only a scheduler's own I/O sets a flag, on its thread, which isn't this one.
            .flag, .ready => unreachable,
        }
    }
}

/// A fiber's cancelation state (std.Io's `Future.cancel`, `recancel`, `CancelProtection`).
pub const Cancel = struct {
    /// `cancel` was called and no cancelation point has returned error.Canceled for it yet.
    /// Atomic: `cancel` may be on another thread. The rest is the fiber's own thread's.
    requested: bool = false,
    /// The last cancelation point returned error.Canceled (`recancel` may re-arm it).
    delivered: bool = false,
    protection: std.Io.CancelProtection = .unblocked,

    /// A request a cancelation point would return error.Canceled for now.
    pub fn isPending(c: *const Cancel) bool {
        return @atomicLoad(bool, &c.requested, .acquire) and c.protection == .unblocked;
    }

    /// A cancelation point: error.Canceled for a pending request, which is then delivered.
    pub fn check(c: *Cancel) std.Io.Cancelable!void {
        if (!c.isPending()) return;
        @atomicStore(bool, &c.requested, false, .release);
        c.delivered = true;
        return error.Canceled;
    }

    /// The request stands again, for the next cancelation point: after error.Canceled was
    /// returned and handled (`recancel`), or when a canceled operation finished anyway.
    pub fn rearm(c: *Cancel) void {
        @atomicStore(bool, &c.requested, true, .release);
        c.delivered = false;
    }
};

/// The calling fiber's cancelation state: a task's, or the root fiber's. Null on a
/// thread without a scheduler.
pub fn currentCancel() ?*Cancel {
    const data = currentFiber() orelse return null;
    return if (data.task) |task| &task.cancel else &data.scheduler.root_cancel;
}

/// The thread a scheduler is for, kept only to check it (`Scheduler.checkThread`): nothing
/// without runtime safety.
const SafetyThreadId = if (std.debug.runtime_safety) u32 else void;

/// GetCurrentThreadId, read from the TEB; nothing without runtime safety.
fn currentSafetyThreadId() SafetyThreadId {
    if (!std.debug.runtime_safety) return {};
    return @truncate(@intFromPtr(windows.teb().ClientId.UniqueThread));
}

/// A deadline (GetTickCount64) `timeout` from now; null for none.
pub fn deadlineMs(timeout: std.Io.Timeout) ?u64 {
    return switch (timeout) {
        .none => null,
        else => win32.GetTickCount64() + timeoutMs(timeout),
    };
}

/// `timeout` in whole milliseconds from now, rounded up; INFINITE for none.
pub fn timeoutMs(timeout: std.Io.Timeout) u32 {
    const ns: i96 = switch (timeout) {
        .none => return win32.INFINITE,
        .duration => |d| d.raw.nanoseconds,
        .deadline => |d| d.raw.nanoseconds - operations.now(null, d.clock).nanoseconds,
    };
    if (ns <= 0) return 0;
    const ms = std.math.divCeil(i96, ns, std.time.ns_per_ms) catch unreachable;
    // INFINITE itself is the largest u32; anything at or past it waits the longest finite time.
    return @intCast(@min(ms, win32.INFINITE - 1));
}

// ---------------------------------------------------------------------------------------------
// The operations every winio Io shares.

pub const operations = struct {
    /// Starts a task on the scheduler of the `io` (std.Io's userdata), first run once that
    /// scheduler runs its tasks. From another thread, if the scheduler takes tasks from other
    /// threads: queued (`Scheduler.incoming`), and its thread nudged.
    pub fn concurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) std.Io.ConcurrentError!*std.Io.AnyFuture {
        const s: *Scheduler = @ptrCast(@alignCast(userdata));
        const here = currentScheduler() == s or s.bindOnFirstUse();
        if (here) s.checkThread() else if (!s.hooks.accepts_remote_tasks or s.isDeinited())
            std.debug.panic("winio.{s} used on a thread it doesn't belong to, or after deinit", .{s.name});
        const task = s.gpa.create(Task) catch @panic("out of memory");
        task.* = .{
            .fiber = undefined,
            .fiber_data = .{ .scheduler = s, .task = task },
            .start = start,
            .gpa = s.gpa,
            .context = allocAligned(s.gpa, context.len, context_alignment),
            .context_alignment = context_alignment,
            .result = allocAligned(s.gpa, result_len, result_alignment),
            .result_alignment = result_alignment,
        };
        @memcpy(task.context[0..context.len], context);
        if (here) {
            s.adopt(task);
        } else {
            // Its fiber is made on its scheduler's thread (`startIncoming`).
            win32.AcquireSRWLockExclusive(&s.incoming_lock);
            task.next_incoming = s.incoming;
            s.incoming = task;
            win32.ReleaseSRWLockExclusive(&s.incoming_lock);
            s.notify();
        }
        return task.asFuture();
    }

    pub fn async(
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*std.Io.AnyFuture {
        return concurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch unreachable; // never fails
    }

    /// Until the task has finished, then its result: from any thread (a futex wait on its `done`).
    /// Not a cancelation point.
    pub fn await(_: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
        const task: *Task = .fromFuture(any_future);
        while (!task.isDone()) block(.{ .futex = .{ .ptr = &task.done, .expected = 0, .deadline = null } });
        std.debug.assert(result_alignment == task.result_alignment);
        @memcpy(result, task.result[0..result.len]);
        task.unref();
    }

    /// Requests the task's cancelation (its next cancelation point returns error.Canceled; one
    /// it is parked in ends now: its thread is nudged), then awaits it.
    pub fn cancel(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
        const task: *Task = .fromFuture(any_future);
        {
            // While the task isn't done its scheduler can't have passed `deinit`'s barrier, and
            // it can't while this holds it: the nudge reaches a live scheduler.
            win32.AcquireSRWLockShared(&deinit_barrier);
            defer win32.ReleaseSRWLockShared(&deinit_barrier);
            if (!task.isDone()) {
                if (builtin.is_test) if (test_hooks.cancel_nudge_window) |hook| hook();
                @atomicStore(bool, &task.cancel.requested, true, .release);
                const s = task.fiber_data.scheduler;
                if (currentScheduler() != s) s.notify();
            }
        }
        await(userdata, any_future, result, result_alignment);
    }

    /// Re-arms the cancelation request whose error.Canceled the calling fiber just got.
    pub fn recancel(_: ?*anyopaque) void {
        const c = currentCancel() orelse std.debug.panic("winio: recancel on a thread without a winio Io", .{});
        if (!c.delivered) std.debug.panic("winio: recancel without an error.Canceled to re-arm", .{});
        c.rearm();
    }

    /// On a thread without a winio Io (no task to cancel), `.unblocked`, as std's Threaded on a
    /// thread it didn't start.
    pub fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
        const c = currentCancel() orelse return .unblocked;
        defer c.protection = new;
        return c.protection;
    }

    /// A cancelation point that does nothing else. (`makeOwnVtable` puts the check in front of
    /// every operation that can return error.Canceled; this is that check alone.)
    pub fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

    // Waiting: std.Io.Mutex, Event, sleeps. A wait ends when woken, changed, timed out, or (for
    // a task, where cancelable) canceled.
    pub fn futexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        return blockCancelable(.{ .futex = .{ .ptr = ptr, .expected = expected, .deadline = deadlineMs(timeout) } });
    }

    pub fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
        block(.{ .futex = .{ .ptr = ptr, .expected = expected, .deadline = null } });
    }

    /// Wakes waiters on any thread (`futex.zig`).
    pub fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        futex.wake(ptr, max_waiters);
    }

    pub fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        return blockCancelable(.{ .sleep = win32.GetTickCount64() + timeoutMs(timeout) });
    }

    pub fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        return switch (clock) {
            .real => .{ .nanoseconds = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + std.time.epoch.windows * std.time.ns_per_s },
            .awake, .boot => .{ .nanoseconds = @intCast(@as(u128, qpc()) * std.time.ns_per_s / qpf()) },
            .cpu_process, .cpu_thread => std.debug.panic("winio: the {t} clock isn't implemented", .{clock}),
        };
    }

    /// Nothing to do: no task state to mark when the program crashes (std calls this, mid-panic,
    /// when the Io is `std.Options.debug_io`, so it must not panic).
    pub fn crashHandler(_: ?*anyopaque) void {}
};

/// What an Io built on a scheduler does itself: std.Io's operations defined in `sources` (structs
/// of operations, such as `&.{ specific, tasks.operations }`), and those in `not_implemented`,
/// its own but not implemented yet (they panic saying so). Every other one is either
/// `unreachable` (`makeOwnVtable`) or forwarded to another Io (`makeForwardingVtable`).
pub const Own = struct {
    /// For messages: "Fibers", "Iocp".
    name: []const u8,
    sources: []const type,
    not_implemented: []const []const u8,

    /// Whether std.Io's operation `op` is implemented, not implemented yet, or forwarded
    /// (`makeForwardingVtable`).
    pub fn support(comptime own: Own, comptime op: []const u8) Support {
        @setEvalBranchQuota(100_000);
        const listed = for (own.not_implemented) |u| {
            if (std.mem.eql(u8, u, op)) break true;
        } else false;
        if (source(own.sources, op) != null) {
            if (listed) @compileError(op ++ " is both implemented and listed as not implemented");
            return .implemented;
        }
        return if (listed) .unimplemented else .forwarded;
    }

    /// `support`, for the Io's own io: what a Layer would forward is `unreachable`.
    pub fn ownSupport(comptime own: Own, comptime op: []const u8) Support {
        return switch (own.support(op)) {
            .forwarded => .@"unreachable",
            else => |s| s,
        };
    }
};

pub const Support = enum {
    implemented,
    /// It panics saying it isn't implemented.
    unimplemented,
    /// Forwarded to the Io under a `Layer`.
    forwarded,
    /// `unreachable`: the caller guarantees it never calls it (`makeOwnVtable`).
    @"unreachable",
};

/// The vtable of an Io's own io: `own`'s operations, every other one `unreachable`, its caller
/// guaranteeing it never calls them. Each that can return error.Canceled starts with a
/// cancelation point.
pub fn makeOwnVtable(comptime own: Own) std.Io.VTable {
    const info = @typeInfo(std.Io.VTable).@"struct";
    var v: std.Io.VTable = undefined;
    for (info.field_names, info.field_types) |op, Field| {
        @field(v, op) = switch (own.support(op)) {
            .implemented => cancelationPoint(op, Field, &@field(source(own.sources, op).?, op)),
            .unimplemented => panicking(own.name, op, Field, "isn't implemented"),
            .forwarded => withArgs(op, Field, struct {
                fn body(_: anytype) noreturn {
                    unreachable;
                }
            }.body),
            .@"unreachable" => unreachable,
        };
    }
    return v;
}

/// An Io's own operations (`Base.own`, called with `base.scheduler` as their userdata), with
/// every other one forwarded to `inner`, behind a cancelation point if it can return
/// error.Canceled, so a canceled task doesn't start it. A plain value, so it can initialize a
/// global. It must not move while its io is in use.
///
/// `inner` must finish its operations on the calling thread without a scheduler of its own, such
/// as a std.Io.Threaded (single-threaded is enough: its own concurrency is never reached through
/// a Layer, which has `concurrent`); not a winio Io or another fiber or event-loop Io, whose waits
/// would park the caller in a scheduler not running here.
pub fn Layer(comptime Base: type) type {
    return struct {
        base: *Base,
        inner: std.Io,

        const L = @This();

        pub fn io(layer: *L) std.Io {
            return .{ .userdata = layer, .vtable = &vtable };
        }

        /// Whether std.Io's operation `op` is the base's own (implemented), its own but not
        /// implemented yet (it panics saying so), or forwarded to `inner`.
        pub fn support(comptime op: []const u8) Support {
            return Base.own.support(op);
        }

        const vtable = makeForwardingVtable(Base.own, schedulerOf, innerOf);

        fn schedulerOf(userdata: ?*anyopaque) ?*anyopaque {
            const layer: *L = @ptrCast(@alignCast(userdata));
            return &layer.base.scheduler;
        }

        fn innerOf(userdata: ?*anyopaque) std.Io {
            const layer: *L = @ptrCast(@alignCast(userdata));
            return layer.inner;
        }
    };
}

/// The vtable of an Io with `own`'s operations, every other one forwarded to the Io `inner` finds
/// from the userdata, behind a cancelation point if it can return error.Canceled, so a canceled
/// task doesn't start it. `own`'s operations are called with the userdata `ownOf` finds (null:
/// the userdata itself).
pub fn makeForwardingVtable(
    comptime own: Own,
    comptime ownOf: ?fn (?*anyopaque) ?*anyopaque,
    comptime inner: fn (?*anyopaque) std.Io,
) std.Io.VTable {
    const info = @typeInfo(std.Io.VTable).@"struct";
    var v: std.Io.VTable = undefined;
    for (info.field_names, info.field_types) |op, Field| {
        @field(v, op) = switch (own.support(op)) {
            .implemented => cancelationPoint(op, Field, if (ownOf) |f|
                withUserdata(op, Field, &@field(source(own.sources, op).?, op), f)
            else
                &@field(source(own.sources, op).?, op)),
            .unimplemented => panicking(own.name, op, Field, "isn't implemented"),
            .forwarded => cancelationPoint(op, Field, forwarding(op, Field, inner)),
            .@"unreachable" => unreachable,
        };
    }
    return v;
}

/// `f`, a function of type `Fn` (a std.Io.VTable field, std.Io's `op`), called with the
/// userdata `own` finds from its own.
fn withUserdata(comptime op: []const u8, comptime Fn: type, comptime f: Fn, comptime own: fn (?*anyopaque) ?*anyopaque) Fn {
    const R = @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    return withArgs(op, Fn, struct {
        fn body(args: anytype) R {
            var with = args;
            with[0] = own(args[0]);
            return @call(.auto, f, with);
        }
    }.body);
}

/// A function of type `Fn` (a std.Io.VTable field, std.Io's `op`) that calls `op` on the Io
/// that `inner` finds from its userdata, with that Io's userdata.
fn forwarding(comptime op: []const u8, comptime Fn: type, comptime inner: fn (?*anyopaque) std.Io) Fn {
    const R = @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    return withArgs(op, Fn, struct {
        fn body(args: anytype) R {
            const io = inner(args[0]);
            var forwarded = args;
            forwarded[0] = io.userdata;
            return @call(.auto, @field(io.vtable, op), forwarded);
        }
    }.body);
}

/// The one struct in `sources` with a `pub fn` named `op`, if any. Two having it is a compile
/// error: one would silently hide the other.
fn source(comptime sources: []const type, comptime op: []const u8) ?type {
    @setEvalBranchQuota(10_000);
    var found: ?type = null;
    for (sources) |S| {
        if (!@hasDecl(S, op)) continue;
        if (found != null) @compileError(op ++ " is defined by two of an Io's sources of operations");
        found = S;
    }
    return found;
}

/// A function of type `Fn` (a std.Io.VTable field) that panics: std.Io's `op` `what`.
fn panicking(comptime name: []const u8, comptime op: []const u8, comptime Fn: type, comptime what: []const u8) Fn {
    return withArgs(op, Fn, struct {
        fn body(_: anytype) noreturn {
            @panic("winio." ++ name ++ ": std.Io's " ++ op ++ " " ++ what);
        }
    }.body);
}

/// `f`, std.Io's `op`, behind a cancelation point if it can return error.Canceled: then it
/// returns error.Canceled, not calling `f`, when the calling fiber has a pending cancelation
/// request.
fn cancelationPoint(comptime op: []const u8, comptime Fn: type, comptime f: Fn) Fn {
    const R = @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    const can_cancel = switch (@typeInfo(R)) {
        .error_union => |eu| for (@typeInfo(eu.error_set).error_set.error_names.?) |e| {
            if (std.mem.eql(u8, e, "Canceled")) break true;
        } else false,
        else => false,
    };
    if (!can_cancel) return f;
    return withArgs(op, Fn, struct {
        fn body(args: anytype) R {
            if (currentCancel()) |c| try c.check();
            return @call(.auto, f, args);
        }
    }.body);
}

/// A function of type `Fn` (a std.Io.VTable field, std.Io's `op`) that calls `body` with its
/// arguments as a tuple.
fn withArgs(comptime op: []const u8, comptime Fn: type, comptime body: anytype) Fn {
    const info = @typeInfo(@typeInfo(Fn).pointer.child).@"fn";
    const R = info.return_type.?;
    const P = info.param_types;
    return switch (P.len) {
        1 => &struct {
            fn f(a0: P[0].?) R {
                return body(.{a0});
            }
        }.f,
        2 => &struct {
            fn f(a0: P[0].?, a1: P[1].?) R {
                return body(.{ a0, a1 });
            }
        }.f,
        3 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?) R {
                return body(.{ a0, a1, a2 });
            }
        }.f,
        4 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?) R {
                return body(.{ a0, a1, a2, a3 });
            }
        }.f,
        5 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?, a4: P[4].?) R {
                return body(.{ a0, a1, a2, a3, a4 });
            }
        }.f,
        6 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?, a4: P[4].?, a5: P[5].?) R {
                return body(.{ a0, a1, a2, a3, a4, a5 });
            }
        }.f,
        7 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?, a4: P[4].?, a5: P[5].?, a6: P[6].?) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6 });
            }
        }.f,
        8 => &struct {
            fn f(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?, a4: P[4].?, a5: P[5].?, a6: P[6].?, a7: P[7].?) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
            }
        }.f,
        else => @compileError("std.Io's " ++ op ++ " has more parameters than `withArgs` handles"),
    };
}

/// `len` bytes (at least one) at `alignment`, allocated with `gpa`.
fn allocAligned(gpa: std.mem.Allocator, len: usize, alignment: std.mem.Alignment) []u8 {
    const n = @max(len, 1);
    const ptr = gpa.rawAlloc(n, alignment, @returnAddress()) orelse @panic("out of memory");
    return ptr[0..n];
}

fn qpc() u64 {
    var counter: windows.LARGE_INTEGER = undefined;
    std.debug.assert(windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool());
    return @intCast(counter);
}

fn qpf() u64 {
    var frequency: windows.LARGE_INTEGER = undefined;
    std.debug.assert(windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool());
    return @intCast(frequency);
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const windows = std.os.windows;
const futex = @import("futex.zig");
