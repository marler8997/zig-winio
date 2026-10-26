//! A std.Io of fibers on one thread: tasks, futexes and time, nothing that blocks.
//!
//! Tasks (`io.concurrent`, `io.async`) are fibers on the thread. The thread itself becomes a fiber
//! too, the root fiber: it runs the thread's own code (`main`, window procedures) and the tasks. A
//! task's waiting Io call switches back to the root fiber, which switches to the task again once
//! what it waits for has happened: a futex changing, a deadline passing, a task finishing. The root fiber runs the tasks
//! whenever it waits itself (an `await`, a `cancel`, a sleep, a Mutex...), until its own wait is
//! over: so a thread's code just awaits what it started. Only one fiber runs at a time.
//!
//! On a thread with windows, `runMessageLoop` drives it instead: it runs the tasks, dispatches
//! window messages, and waits with MsgWaitForMultipleObjectsEx for whichever comes next: a window
//! message, a nudge from another thread (the `wake` Event), or the nearest deadline. The tasks and
//! the window procedures never run simultaneously, but can run concurrently.
//!
//! Inside the message loop, the root fiber is in a window procedure, which the loop called: it
//! can't run tasks while it waits, so it may not wait on a futex at all. A Mutex, Event,
//! Condition or await that has to wait panics, as a task it waited for could never run meanwhile
//! (a task holding the Mutex across a wait: a deadlock nothing could detect). Window procedures
//! hand such waiting to a task (`tryLock` doesn't wait; neither does a Queue put with `min` 0).
//! Sleeps there just block. Outside it (before, or after, as when cleaning up), the root fiber's
//! waits run the tasks as usual: `future.cancel` after it returns runs the task until it returns.
//! Window messages aren't dispatched then; they wait for the message loop.
//!
//! Limitation: while a modal loop runs (Windows' own message loop while the window is resized or
//! moved, a menu is open, a MessageBox or dialog is up), `runMessageLoop` doesn't, so no task is
//! resumed. A sleep or timeout that comes due during the loop, or a wake from a window procedure
//! or another thread, isn't lost: the task resumes as soon as the modal loop ends, late by however
//! long it lasted (dragging the window for a second delays a 50 ms sleep by about that second).
//! The window procedures do run (the modal loop dispatches their messages), so a program can keep
//! its window current itself: compute what WM_PAINT shows from the clock (`now` doesn't wait),
//! and set a window timer of its own (SetTimer, whose WM_TIMER modal loops dispatch too) to
//! repaint while a loop runs. Work that must keep time during a modal loop belongs in timer
//! messages, not in tasks. (Not done here: resuming tasks from a timer of its own.)
//!
//! Other threads may await and cancel its tasks and share futexes with them: each nudges the
//! thread by setting its `wake` Event, which its waits (and the message loop's) wait on. They
//! may not start tasks here.
//!
//! What `io()` implements: tasks, futexes (and so Mutex, Event, Condition, Queue...) and time
//! (`now`, `sleep`), the operations that need its scheduler, none of which blocks the thread.
//! Every other operation (files, directories, pipes, processes, the network, random...) is
//! `unreachable`: code using this io guarantees it never calls one, so nothing it does through
//! this io blocks the thread. (In safe builds, a call panics with "reached unreachable code";
//! otherwise it's undefined behavior.) Group isn't implemented yet (it panics saying so);
//! `support` says which is which.
//!
//! Code that needs blocking operations too (a library taking an Io that also reads files) gets a
//! `Layer`'s io: the same tasks, futexes and time, with everything else forwarded to the Io under
//! it, after a cancelation check where the operation can return error.Canceled. Choosing that Io
//! is a decision made where the io is handed over, visibly; one Fibers can have several Layers.
//! Code that only blocks (reading a file, no waiting on tasks) can use the blocking Io directly.
//!
//! The Io under a Layer must finish its operations on the calling thread, without a scheduler of
//! its own: a forwarded call runs in a task, and nothing else on the thread runs until it returns.
//! std.Io.Threaded does (single-threaded is enough: its own concurrency is never reached through
//! a Layer, which has `concurrent`); winio.Iocp and other fiber or event-loop Ios don't, as their
//! waits would park the caller in a scheduler not running here. Its calls block the thread: on a
//! window's thread, a slow file operation, or a pipe read waiting on another process, freezes
//! the window. Non-blocking I/O needs its completion delivered somewhere the thread looks: an
//! I/O completion port, which only another thread can wait on alongside window messages, or
//! APCs, which modal loops don't run. So for non-blocking I/O, do it on another thread without a
//! message loop (a `winio.Iocp`), and wait for it from a task. And a Mutex (or any futex) shared
//! with these tasks goes through this io or a Layer's, never the Io under it directly: that one
//! waits and wakes its own way, which these tasks don't see.
//!
//! Tasks, futexes, sleeps and awaits are `tasks.zig`'s, shared with winio's other Ios: a thread
//! has at most one, and operations find it in the running fiber's data, with no thread-local
//! storage.
const Fibers = @This();

scheduler: tasks.Scheduler,
/// An auto-reset event other threads set to nudge the thread (`notifyEvent`). Not a posted
/// message: the root fiber's waits outside the message loop would have to peek for it, and
/// PeekMessage also dispatches sent messages, running window procedures mid-wait.
wake: win32.HANDLE,
/// A message loop (`Fibers.runMessageLoop`) is driving it: what the root fiber does is in a window
/// procedure (or in a hook), and it may not wait on a futex (`waitRootHere`).
in_message_loop: bool,

/// Fibers not yet bound to a thread. The first thread that starts a task with its io (or runs
/// a message loop with it) becomes its: a fiber, from then on. Needs nothing at runtime, so it
/// can initialize a global (as can `io()`, and a `Layer`):
///     var fibers: winio.Fibers = .init(gpa);
///     const fibers_io = fibers.io();
/// The rest of the io works on any thread before then, and on other threads after: it only
/// needs its thread for tasks. A global needs no `deinit`: the process's exit cleans it up.
pub fn init(gpa: std.mem.Allocator) Fibers {
    return .{
        .scheduler = .init(gpa, "Fibers", .{
            .waitRoot = &waitRootHere,
            .notify = &notifyEvent,
            .accepts_remote_tasks = false,
            .bound = &bound,
        }),
        .wake = undefined,
        .in_message_loop = false,
    };
}

/// Its own setup once a thread has become its (`Scheduler.bindOnFirstUse`).
fn bound(s: *tasks.Scheduler) void {
    const fibers: *Fibers = @fieldParentPtr("scheduler", s);
    fibers.wake = win32.CreateEventW(null, 0, 0, null) orelse win32.panicWin32("CreateEventW", win32.GetLastError());
}

/// Back to a plain thread. Every task must have finished. If no thread became its (nothing
/// started a task or ran its message loop), it only makes it unusable.
pub fn deinit(fibers: *Fibers) void {
    const was_bound = fibers.scheduler.owner != 0;
    fibers.scheduler.deinit();
    if (was_bound) windows.CloseHandle(fibers.wake);
}

/// Nudges its thread (from another thread): sets `wake`, after which it clears the notified flag
/// and looks at the tasks.
fn notifyEvent(s: *tasks.Scheduler) void {
    const fibers: *Fibers = @fieldParentPtr("scheduler", s);
    if (0 == win32.SetEvent(fibers.wake)) win32.panicWin32("SetEvent", win32.GetLastError());
}

/// Its std.Io: tasks, futexes and time; anything that would block is `unreachable` (see the
/// file's comment). Only builds the value, so it can initialize a global.
pub fn io(fibers: *Fibers) std.Io {
    return .{ .userdata = &fibers.scheduler, .vtable = &vtable };
}

/// The Fibers' tasks, futexes and time, with every other operation forwarded to `inner` (see the
/// file's comment and `tasks.Layer`): an Io for code that also needs blocking operations. A plain
/// value, so it can initialize a global:
///     var threaded: std.Io.Threaded = .init_single_threaded;
///     var files_layer: winio.Fibers.Layer = .{ .base = &fibers, .inner = threaded.io() };
///     some_library.run(files_layer.io());
pub const Layer = tasks.Layer(Fibers);

/// The message loop: runs `fibers`' tasks, dispatches window messages, and waits for whichever
/// comes next, until WM_QUIT. Returns its wParam: the exit code given to PostQuitMessage. The
/// calling thread becomes `fibers`' if no thread has yet.
pub fn runMessageLoop(fibers: *Fibers) win32.WPARAM {
    const s = &fibers.scheduler;
    // In every build mode: in_message_loop another thread's fibers would switch fibers on a thread that
    // isn't one, or isn't theirs.
    if (tasks.currentScheduler() != s and !s.bindOnFirstUse())
        std.debug.panic("winio.Fibers.runMessageLoop: the Fibers belong to another thread, or were deinited", .{});
    if (fibers.in_message_loop) std.debug.panic("winio.Fibers.runMessageLoop: called from inside runMessageLoop (a window procedure)", .{});
    fibers.in_message_loop = true;
    defer fibers.in_message_loop = false;
    while (true) {
        s.runReady();
        const timeout: u32 = if (s.nearestDeadline()) |d|
            @intCast(@min(d -| win32.GetTickCount64(), win32.INFINITE - 1))
        else
            win32.INFINITE;
        const rc = win32.MsgWaitForMultipleObjectsEx(1, @ptrCast(&fibers.wake), timeout, win32.QS_ALLINPUT, .{ .INPUTAVAILABLE = 1 });
        if (rc == 0) {
            // A nudge (`wake`, now reset): runReady looks at the tasks.
            s.clearNotified();
        } else if (rc == 1) {
            // Window messages.
            var msg: win32.MSG = undefined;
            while (0 != win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE)) {
                if (msg.message == win32.WM_QUIT) return msg.wParam;
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        } else if (rc == @backingInt(win32.WAIT_TIMEOUT)) {
            // A deadline passed: runReady runs whichever task it was.
        } else win32.panicWin32("MsgWaitForMultipleObjectsEx", win32.GetLastError());
    }
}

/// The root fiber waits (see the file's comment): runs the tasks until the wait is over. Inside a
/// message loop (a window procedure): a futex wait panics, a sleep blocks.
fn waitRootHere(s: *tasks.Scheduler) void {
    const fibers: *Fibers = @fieldParentPtr("scheduler", s);
    if (fibers.in_message_loop) switch (s.root.wait) {
        .futex => std.debug.panic(
            "winio.Fibers: a window procedure (the root fiber, inside runMessageLoop) waits on a futex (a Mutex, Event, " ++
                "Condition or await that had to wait): no task can run meanwhile, so one holding what it waits for " ++
                "would deadlock; wait in a task instead (a window procedure can tryLock, or wake a task)",
            .{},
        ),
        else => return tasks.waitOnAddress(&s.root),
    };
    while (true) {
        s.runReady();
        const now_ms = win32.GetTickCount64();
        if (s.root.isReady(now_ms)) return;
        const timeout: u32 = if (s.nearestDeadline()) |d|
            @intCast(@min(d -| now_ms, win32.INFINITE - 1))
        else if (!builtin.single_threaded)
            // Another thread may end it (a futex wake, a cancelation).
            win32.INFINITE
        else
            std.debug.panic("winio.Fibers: a wait nothing could end: no task can go on and no deadline is set: a deadlock", .{});
        switch (win32.WaitForSingleObject(fibers.wake, timeout)) {
            win32.WAIT_OBJECT_0 => s.clearNotified(),
            win32.WAIT_TIMEOUT => {},
            else => win32.panicWin32("WaitForSingleObject", win32.GetLastError()),
        }
    }
}

/// Its own operations (`io()`'s, and a Layer's own): tasks, futexes and time. Group's aren't
/// implemented yet: they run tasks, so they can't be forwarded (the Io under a Layer would run them
/// its own way, with futexes these tasks don't share).
pub const own: tasks.Own = .{
    .name = "Fibers",
    .sources = &.{tasks.operations},
    .not_implemented = &.{ "groupAsync", "groupConcurrent", "groupAwait", "groupCancel" },
};

pub const vtable = tasks.makeOwnVtable(own);

/// Whether std.Io's operation `op` is implemented by `io()`, not implemented yet (it panics saying
/// so), or `unreachable` (it would block: code that needs it uses a `Layer`, which forwards it).
pub fn support(comptime op: []const u8) tasks.Support {
    return own.ownSupport(op);
}

const builtin = @import("builtin");
const std = @import("std");
const tasks = @import("tasks.zig");
const win32 = @import("win32").everything;
const windows = std.os.windows;
