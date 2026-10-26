//! A std.Io for a thread without a message loop: tasks are fibers on the thread, and one wait
//! on an I/O completion port covers everything they wait for (I/O completing, deadlines).
//!
//! There is no `run`: whenever the root fiber waits (an `await`, a sleep, a read), it
//! runs the loop until its wait is over: it switches to each task that can go on, then waits on
//! the port for the next completion or deadline. A wait nothing could end (no task can go on, no
//! I/O is pending, no deadline is set) is a deadlock, and panics.
//!
//! The thread that runs it creates it at runtime, and deinits it when done:
//!     var iocp: winio.Iocp = undefined;
//!     iocp.init(gpa, .{}); // binds this thread
//!     defer iocp.deinit();
//!     const io = iocp.io(); // other threads get it from here
//! Not a global, unlike Fibers: nothing can use it before its thread runs. Nor a logging io: stderr
//! is synchronous (log through a std.Io.Threaded).
//!
//! What `io()` does without blocking the thread: tasks, futexes and time; reads and writes, which
//! complete as packets on the port; batches of them; seeking; closing; waiting for and killing a
//! child, whose exit is a wait completion packet on the port. Not implemented yet (they panic
//! saying so): Group, file locks, the network.
//!
//! What blocks the thread (every task waits meanwhile):
//! - briefly: opening files, overlapped, while NtCreateFile runs (`dirOpenFile`, `dirCreateFile`,
//!   `dirCreateFileAtomic`, `processExecutableOpen`: every operation that gives a `File`);
//!   spawning (`processSpawn`, `spawn.zig`: each pipe overlapped on this end, stdin too), while
//!   CreateProcessW runs;
//! - every other operation (directories, stat, length, sync, rename, random, the executable's
//!   path...): forwarded to a std.Io.Threaded the Iocp owns (`threaded`).
//! `support` says which is which.
//!
//! Every handle it does I/O on must be overlapped (FILE_FLAG_OVERLAPPED, or NtCreateFile without
//! a SYNCHRONOUS_IO option) with `File.flags.nonblocking` set: as the files it opens and the pipes
//! it creates are. A file opened elsewhere must be opened that way. A synchronous handle is invalid
//! use: in safe builds every operation checks; `checkHandle` checks in any build. A handle is
//! bound to the port on its first read or write, and must be closed through this io (`fileClose`,
//! or a child's wait or kill): a handle closed elsewhere whose value is reused can't be told apart.
//!
//! An overlapped disk file has no file position of its own, so the Iocp keeps one for streaming
//! reads and writes (`bound`), which `fileSeekBy` and `fileSeekTo` move. Like a file position,
//! two tasks streaming the same file at once both read it before either advances it.
//!
//! Other threads may start tasks here (`iocp.io().concurrent` from any thread: they run on this
//! one), await and cancel them, and share futexes with them; each nudges this thread with an
//! empty packet on the port (`notifyPort`). They may also make the calls that don't touch the
//! port: the forwarded ones, opening files and spawning. What uses the port is this thread's: a
//! read, write, seek, close, batch, or a child's wait or kill from another thread panics (so a
//! file opened or a child spawned there is handed to this thread for its I/O). In a multithreaded build a wait nothing on this
//! thread could end waits for another thread; in a single-threaded one it's a deadlock, and
//! panics.

scheduler: tasks.Scheduler,
port: windows.HANDLE,
/// Reads and writes started and not yet completed.
pending: usize,
/// The handles bound to `port`, each with its position for streaming: null if it isn't a disk
/// file (a pipe has no position).
bound: std.AutoHashMapUnmanaged(windows.HANDLE, ?u64),
/// What the forwarded operations run on.
threaded: std.Io.Threaded,
spawn_file_writes: SpawnFileWrites,
spawn_inheritance: SpawnInheritance,

pub const InitOptions = struct {
    /// How a child writes a `.file` given as its stdout or stderr (`processSpawn`).
    spawn_file_writes: SpawnFileWrites = .from_start,
    /// Which handles a child inherits (`processSpawn`).
    spawn_inheritance: SpawnInheritance = .all_inheritable,
};

pub const SpawnFileWrites = spawn.FileWrites;
pub const SpawnInheritance = spawn.Inheritance;

const Iocp = @This();

/// Call on the Io's thread before anything uses `io()`. It must not move after this.
/// `gpa` must be thread-safe: tasks and spawns from other threads allocate with it there.
pub fn init(iocp: *Iocp, gpa: std.mem.Allocator, options: InitOptions) void {
    iocp.* = .{
        .scheduler = undefined,
        .port = win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, null, 0, 1) orelse
            win32.panicWin32("CreateIoCompletionPort", win32.GetLastError()),
        .pending = 0,
        .bound = .empty,
        .threaded = threaded: {
            var threaded: std.Io.Threaded = .init_single_threaded;
            // Not only its tasks allocate, as its init says: so does spawning, for one.
            threaded.allocator = gpa;
            break :threaded threaded;
        },
        .spawn_file_writes = options.spawn_file_writes,
        .spawn_inheritance = options.spawn_inheritance,
    };
    iocp.scheduler = .init(gpa, "Iocp", .{
        .waitRoot = &waitRoot,
        .notify = &notifyPort,
        .accepts_remote_tasks = true,
    });
    iocp.scheduler.attach();
}

/// Back to a plain thread. Every task must have finished.
pub fn deinit(iocp: *Iocp) void {
    iocp.scheduler.deinit();
    std.debug.assert(iocp.pending == 0);
    iocp.bound.deinit(iocp.scheduler.gpa);
    windows.CloseHandle(iocp.port);
    iocp.threaded.deinit();
}

pub fn io(iocp: *Iocp) std.Io {
    iocp.scheduler.checkThread();
    return .{ .userdata = &iocp.scheduler, .vtable = &vtable };
}

/// Its own operations (see the file's comment); the rest are forwarded to `threaded`. Not
/// implemented yet: Group's, file locks (a lock request can complete through the port) and the
/// network.
pub const own: tasks.Own = .{
    .name = "Iocp",
    .sources = &.{ operations, tasks.operations },
    .not_implemented = &.{
        "groupAsync",    "groupConcurrent", "groupAwait",          "groupCancel",
        "fileLock",      "fileTryLock",     "fileUnlock",          "fileDowngradeLock",
        "netListenIp",   "netAccept",       "netBindIp",           "netConnectIp",
        "netListenUnix", "netConnectUnix",  "netSocketCreatePair", "netWriteFile",
        "netClose",      "netShutdown",
    },
};

pub const vtable = tasks.makeForwardingVtable(own, null, threadedOf);

fn threadedOf(userdata: ?*anyopaque) std.Io {
    return anyThread(userdata).threaded.io();
}

/// Whether std.Io's operation `op` is the Iocp's own (implemented), its own but not implemented yet
/// (it panics saying so), or forwarded to `threaded`.
pub fn support(comptime op: []const u8) tasks.Support {
    return own.support(op);
}

/// Whether the Iocp can do I/O on `file`: its handle overlapped, and `flags.nonblocking` saying so.
/// `synchronous`: opened for synchronous I/O (a disk file opened without FILE_FLAG_OVERLAPPED, a
/// CreatePipe pipe, the console). In safe builds every operation checks this.
pub fn checkHandle(file: std.Io.File) enum { ok, synchronous, nonblocking_flag_wrong } {
    var mode: u32 = 0;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtQueryInformationFile(file.handle, &iosb, &mode, @sizeOf(u32), .Mode)) {
        .SUCCESS => {},
        else => |status| std.debug.panic("winio.Iocp.checkHandle: NtQueryInformationFile: {t}", .{status}),
    }
    // FILE_SYNCHRONOUS_IO_ALERT, FILE_SYNCHRONOUS_IO_NONALERT (measured, .amp/in/handlemode).
    if (mode & (0x10 | 0x20) != 0) return .synchronous;
    return if (file.flags.nonblocking) .ok else .nonblocking_flag_wrong;
}

/// The root fiber waits: it runs the tasks and waits on the port until its wait is over.
fn waitRoot(s: *tasks.Scheduler) void {
    const iocp: *Iocp = @fieldParentPtr("scheduler", s);
    while (true) {
        s.runReady();
        const now_ms = win32.GetTickCount64();
        if (s.root.isReady(now_ms)) return;
        const timeout: u32 = if (s.nearestDeadline()) |d|
            @intCast(@min(d -| now_ms, win32.INFINITE - 1))
        else if (iocp.pending > 0 or !builtin.single_threaded)
            // Another thread may end it (a futex wake, a task, a cancelation).
            win32.INFINITE
        else
            std.debug.panic("winio.Iocp: a wait nothing could end: no task can go on, no I/O is pending and no deadline is set: a deadlock", .{});
        iocp.poll(timeout);
    }
}

/// Nudges the Iocp's thread (from another thread): an empty packet, which `poll` takes for that.
fn notifyPort(s: *tasks.Scheduler) void {
    const iocp: *Iocp = @fieldParentPtr("scheduler", s);
    if (0 == win32.PostQueuedCompletionStatus(iocp.port, 0, 0, null)) win32.panicWin32("PostQueuedCompletionStatus", win32.GetLastError());
}

/// Waits up to `timeout_ms` for completions, and marks each one's operation done (or, for a
/// batch's, completes it in its batch).
fn poll(iocp: *Iocp, timeout_ms: u32) void {
    var entries: [64]win32.OVERLAPPED_ENTRY = undefined;
    var n: u32 = 0;
    if (0 == win32.GetQueuedCompletionStatusEx(iocp.port, &entries, entries.len, &n, timeout_ms, 0)) {
        switch (win32.GetLastError()) {
            .WAIT_TIMEOUT => return,
            else => |err| win32.panicWin32("GetQueuedCompletionStatusEx", err),
        }
    }
    for (entries[0..n]) |entry| {
        // No context: a nudge from another thread (`notifyPort`). The loop looks at the tasks next.
        const overlapped = entry.lpOverlapped orelse {
            iocp.scheduler.clearNotified();
            continue;
        };
        // The packet's context is the operation's IO_STATUS_BLOCK (`read`, `write`,
        // `waitSignaled`, `startBatchOp`).
        const iosb: *windows.IO_STATUS_BLOCK = @ptrCast(@alignCast(overlapped));
        const op: *Op = @fieldParentPtr("iosb", iosb);
        iocp.pending -= 1;
        if (op.batch) |b| iocp.batchOpCompleted(b, @fieldParentPtr("op", op)) else op.done = true;
    }
}

/// An overlapped operation in progress: its completion packet marks it done.
const Op = struct {
    iosb: windows.IO_STATUS_BLOCK = undefined,
    done: bool = false,
    /// Whether winio asked for it to be canceled (a task's cancel, `batchCancel`): a CANCELLED
    /// status without this came from elsewhere (`unexplainedCancel`).
    canceled: bool = false,
    /// A batch's operation (a `BatchOp`): its packet completes it in the batch instead.
    batch: ?*std.Io.Batch = null,
};

/// An operation that ended CANCELLED though winio didn't cancel it: CancelIoEx from outside
/// winio, or its handle closed while it was pending (a disk file's; a pipe's pending read ends at
/// end of stream instead). Invalid use: as an error.Canceled to a task nothing canceled, or a
/// batch's stream quietly gone, it would hide that.
fn unexplainedCancel() noreturn {
    std.debug.panic("winio.Iocp: an operation was canceled, but not by winio: CancelIoEx outside winio, or its handle closed while it was pending", .{});
}

/// Waits, on the port, until `handle` (a process) is signaled: a wait completion packet brings
/// it there like I/O. The packet is queued at once if it's signaled already (measured,
/// .amp/in/waitpacket). `.cancelable`: a cancelation point.
fn waitSignaled(iocp: *Iocp, handle: windows.HANDLE, how: enum { cancelable, uncancelable }) (std.Io.Cancelable || std.Io.UnexpectedError)!void {
    var packet: windows.HANDLE = undefined;
    switch (NtCreateWaitCompletionPacket(&packet, .{ .GENERIC = .{ .ALL = true } }, null)) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    defer windows.CloseHandle(packet);
    var op: Op = .{};
    switch (NtAssociateWaitCompletionPacket(packet, iocp.port, handle, null, &op.iosb, .SUCCESS, 0, null)) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    iocp.pending += 1;
    switch (how) {
        .uncancelable => tasks.block(.{ .flag = .{ .ptr = &op.done } }),
        .cancelable => tasks.blockCancelable(.{ .flag = .{ .ptr = &op.done } }) catch |err| {
            // Removing a packet already queued too, so none comes (measured: SUCCESS whether
            // queued or not, and no packet after).
            switch (NtCancelWaitCompletionPacket(packet, .TRUE)) {
                .SUCCESS => {
                    iocp.pending -= 1;
                    return err;
                },
                // The packet stays queued: it signaled in time, and the request stands.
                .PENDING => {
                    tasks.block(.{ .flag = .{ .ptr = &op.done } });
                    tasks.currentCancel().?.rearm();
                },
                else => |status| std.debug.panic("winio.Iocp: NtCancelWaitCompletionPacket: {t}", .{status}),
            }
        },
    }
    // As in `finish`: only the packet sets `done`.
    if (!op.done) unreachable;
}

extern "ntdll" fn NtCancelWaitCompletionPacket(packet: windows.HANDLE, remove_signaled_packet: windows.BOOLEAN) callconv(.winapi) windows.NTSTATUS;

extern "ntdll" fn NtCreateWaitCompletionPacket(handle: *windows.HANDLE, access: windows.ACCESS_MASK, attributes: ?*const windows.OBJECT.ATTRIBUTES) callconv(.winapi) windows.NTSTATUS;
extern "ntdll" fn NtAssociateWaitCompletionPacket(
    packet: windows.HANDLE,
    port: windows.HANDLE,
    target: windows.HANDLE,
    key: ?*anyopaque,
    apc_context: ?*anyopaque,
    status: windows.NTSTATUS,
    information: usize,
    already_signaled: ?*windows.BOOLEAN,
) callconv(.winapi) windows.NTSTATUS;

/// Terminates the process `handle` (exit code 1, as std) and waits on the port until it's gone.
/// ACCESS_DENIED: usually it had exited already (std), or the handle can't terminate it.
fn terminate(iocp: *Iocp, handle: windows.HANDLE) (std.Io.UnexpectedError || error{AccessDenied})!void {
    const exit_code: windows.NTSTATUS = @fromBackingInt(1);
    // As std does: for tools that watch for processes exiting silently.
    _ = windows.ntdll.RtlReportSilentProcessExit(handle, exit_code);
    switch (windows.ntdll.NtTerminateProcess(handle, exit_code)) {
        .SUCCESS, .PROCESS_IS_TERMINATING => iocp.waitSignaled(handle, .uncancelable) catch |err| switch (err) {
            error.Canceled => unreachable, // uncancelable
            error.Unexpected => |e| return e,
        },
        .ACCESS_DENIED => return error.AccessDenied,
        else => |status| return windows.unexpectedStatus(status),
    }
}

/// Unbinds `file` and closes it.
fn close(iocp: *Iocp, file: std.Io.File) void {
    _ = iocp.bound.remove(file.handle);
    windows.CloseHandle(file.handle);
}

/// Closes what a waited or killed child still holds: its handles and pipes (unbound, so a later
/// handle with the same value is bound afresh).
fn cleanup(iocp: *Iocp, child: *std.process.Child) void {
    const handle = child.id.?;
    if (child.request_resource_usage_statistics) {
        var counters: windows.PROCESS.VM_COUNTERS = undefined;
        switch (windows.ntdll.NtQueryInformationProcess(handle, .VmCounters, &counters, @sizeOf(windows.PROCESS.VM_COUNTERS), null)) {
            .SUCCESS => child.resource_usage_statistics.rusage = counters,
            // As std: none.
            else => child.resource_usage_statistics.rusage = null,
        }
    }
    windows.CloseHandle(handle);
    child.id = null;
    windows.CloseHandle(child.thread_handle);
    child.thread_handle = undefined;
    inline for (.{ "stdin", "stdout", "stderr" }) |name| if (@field(child, name)) |file| {
        iocp.close(file);
        @field(child, name) = null;
    };
}

/// `status` is what NtReadFile/NtWriteFile returned for `op` on `handle`; returns the
/// operation's own status once it has completed. A started one (anything but an error status)
/// completes as a packet on the port, even when it finished at once.
///
/// A cancelation point: canceled, it cancels the I/O (CancelIoEx) but still waits for its
/// packet, as the kernel owns `op` until then; CANCELLED is then the status. If the I/O finished
/// anyway, the request stands for the next cancelation point.
fn finish(iocp: *Iocp, op: *Op, handle: windows.HANDLE, status: windows.NTSTATUS) windows.NTSTATUS {
    // The severity bits: 3 is an error, and an operation that failed to start queues nothing.
    if (@backingInt(status) >> 30 == 3) return status;
    iocp.pending += 1;
    tasks.blockCancelable(.{ .flag = .{ .ptr = &op.done } }) catch {
        op.canceled = true;
        // As std, whatever it says (NOT_FOUND: it finished already): the packet comes either way.
        var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
        _ = windows.ntdll.NtCancelIoFileEx(handle, &op.iosb, &cancel_iosb);
        tasks.block(.{ .flag = .{ .ptr = &op.done } });
        if (op.iosb.u.Status != .CANCELLED) tasks.currentCancel().?.rearm();
    };
    // Only `poll` sets `done`, when the operation's packet arrives, and the task stays parked
    // until then. So a bug in winio got here: the kernel would write `op` (on the caller's
    // stack) into a dead frame, and a loop of these would pile up pending I/O in kernel memory.
    if (!op.done) unreachable;
    if (op.iosb.u.Status == .CANCELLED and !op.canceled) unexplainedCancel();
    return op.iosb.u.Status;
}

/// Binds an overlapped `file` to the port, once; a disk file's streaming position starts at 0.
/// Every operation on a file goes through here: in safe builds, it checks the handle first.
fn bind(iocp: *Iocp, file: std.Io.File) void {
    if (std.debug.runtime_safety) switch (checkHandle(file)) {
        .ok => {},
        .synchronous => std.debug.panic("winio.Iocp: a synchronous handle: the Iocp does I/O only on overlapped ones (FILE_FLAG_OVERLAPPED)", .{}),
        .nonblocking_flag_wrong => std.debug.panic("winio.Iocp: an overlapped handle whose File.flags.nonblocking is false", .{}),
    };
    const gop = iocp.bound.getOrPut(iocp.scheduler.gpa, file.handle) catch @panic("out of memory");
    if (gop.found_existing) return;
    gop.value_ptr.* = if (files.isDisk(file)) 0 else null;
    if (win32.CreateIoCompletionPort(file.handle, iocp.port, 0, 0) == null) {
        _ = iocp.bound.remove(file.handle);
        switch (win32.GetLastError()) {
            .ERROR_INVALID_PARAMETER => std.debug.panic("winio.Iocp: a file bound to another completion port, or synchronous", .{}),
            else => |err| win32.panicWin32("CreateIoCompletionPort", err),
        }
    }
}

/// Reads into `buffer` at `position` (null for a pipe, which has none): the status, and the
/// bytes read.
fn read(iocp: *Iocp, file: std.Io.File, buffer: []u8, position: ?*const windows.LARGE_INTEGER) struct { windows.NTSTATUS, usize } {
    var op: Op = .{};
    const len: u32 = @intCast(buffer.len);
    iocp.bind(file);
    const status = iocp.finish(&op, file.handle, windows.ntdll.NtReadFile(file.handle, null, null, &op.iosb, &op.iosb, buffer.ptr, len, position, null));
    return .{ status, if (status == .SUCCESS) op.iosb.Information else 0 };
}

/// Writes `buffer` at `position` (null for a pipe): the status, and the bytes written.
fn write(iocp: *Iocp, file: std.Io.File, buffer: []const u8, position: ?*const windows.LARGE_INTEGER) struct { windows.NTSTATUS, usize } {
    var op: Op = .{};
    const len: u32 = @intCast(buffer.len);
    iocp.bind(file);
    const status = iocp.finish(&op, file.handle, windows.ntdll.NtWriteFile(file.handle, null, null, &op.iosb, &op.iosb, buffer.ptr, len, position, null));
    return .{ status, if (status == .SUCCESS) op.iosb.Information else 0 };
}

/// The Iocp, for an operation on its own state (the port, `bound`, `pending`): only on its thread.
fn fromUserdata(userdata: ?*anyopaque) *Iocp {
    const iocp = anyThread(userdata);
    iocp.scheduler.checkThread();
    return iocp;
}

/// The Iocp, for an operation that doesn't touch its own state (`threaded`, which locks its own,
/// and the options): from any thread.
fn anyThread(userdata: ?*anyopaque) *Iocp {
    const s: *tasks.Scheduler = @ptrCast(@alignCast(userdata));
    return @fieldParentPtr("scheduler", s);
}

/// std.Io.Threaded's `atomicFileInit`, on `iocp_io` (the Iocp's): it creates the file, overlapped.
fn atomicFile(iocp_io: std.Io, dir: std.Io.Dir, dest_basename: []const u8, permissions: std.Io.File.Permissions, close_dir_on_deinit: bool) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
    while (true) {
        var random_integer: u64 = undefined;
        iocp_io.random(@ptrCast(&random_integer));
        const tmp_sub_path = std.fmt.hex(random_integer);
        const file = dir.createFile(iocp_io, &tmp_sub_path, .{ .permissions = permissions, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists, error.DeviceBusy, error.FileBusy => continue,
            error.IsDir => return error.Unexpected, // No path components.
            error.FileTooBig => return error.Unexpected, // Creating, not opening.
            error.FileLocksUnsupported => return error.Unexpected, // Not asking for locks.
            error.PipeBusy => return error.Unexpected, // Not opening a pipe.
            else => |e| return e,
        };
        return .{
            .file = file,
            .file_basename_hex = random_integer,
            .dest_sub_path = dest_basename,
            .file_open = true,
            .file_exists = true,
            .close_dir_on_deinit = close_dir_on_deinit,
            .dir = dir,
        };
    }
}

/// Where a streaming read or write of `file` goes: the position the Iocp keeps for a disk file;
/// null for a pipe, which needs none.
fn streamPosition(iocp: *Iocp, file: std.Io.File) ?u64 {
    iocp.bind(file);
    return iocp.bound.get(file.handle).?;
}

/// The position the Iocp keeps for `file` (`streamPosition`), to seek; a pipe has none.
fn seekPosition(iocp: *Iocp, file: std.Io.File) error{Unseekable}!*u64 {
    iocp.bind(file);
    const position = iocp.bound.getPtr(file.handle).?;
    if (position.* == null) return error.Unseekable;
    return &position.*.?;
}

/// Moves the position the Iocp keeps for `file` (`streamPosition`) on by `n`. Looked up again, as
/// the map may have grown while the operation was pending.
fn advance(iocp: *Iocp, file: std.Io.File, n: usize) void {
    const position = iocp.bound.getPtr(file.handle) orelse std.debug.panic("winio.Iocp: a file closed during a streaming read or write of it", .{});
    position.* = position.*.? + n;
}

/// The Iocp's own operations (the rest it shares with every winio Io: `tasks.operations`).
const operations = struct {
    /// Opened overlapped. Blocks the thread while NtCreateFile runs.
    pub fn dirCreateFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
        return files.createFile(.{ .userdata = userdata, .vtable = &vtable }, dir, sub_path, options);
    }

    /// Opened overlapped. Blocks the thread while NtCreateFile runs.
    pub fn dirOpenFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        return files.openFile(.{ .userdata = userdata, .vtable = &vtable }, dir, sub_path, options);
    }

    /// As std.Io.Threaded's (a temporary file with a random name, beside `dest_path`), the file
    /// opened overlapped. Blocks the thread while the directory and the file are opened.
    pub fn dirCreateFileAtomic(userdata: ?*anyopaque, dir: std.Io.Dir, dest_path: []const u8, options: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
        const iocp_io: std.Io = .{ .userdata = userdata, .vtable = &vtable };
        const dirname = std.Io.Dir.path.dirname(dest_path) orelse return atomicFile(iocp_io, dir, dest_path, options.permissions, false);
        const new_dir = if (options.make_path)
            dir.createDirPathOpen(iocp_io, dirname, .{}) catch |err| switch (err) {
                // None of these make sense in this context (as std).
                error.IsDir,
                error.Streaming,
                error.DiskQuota,
                error.PathAlreadyExists,
                error.LinkQuotaExceeded,
                error.PipeBusy,
                error.FileTooBig,
                error.FileLocksUnsupported,
                error.DeviceBusy,
                => return error.Unexpected,
                else => |e| return e,
            }
        else
            try dir.openDir(iocp_io, dirname, .{});
        return atomicFile(iocp_io, new_dir, std.Io.Dir.path.basename(dest_path), options.permissions, true);
    }

    /// Opened overlapped. Blocks the thread while NtCreateFile runs.
    pub fn processExecutableOpen(userdata: ?*anyopaque, options: std.Io.Dir.OpenFileOptions) std.process.OpenExecutableError!std.Io.File {
        const iocp_io: std.Io = .{ .userdata = userdata, .vtable = &vtable };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = buf[0..try std.process.executablePath(iocp_io, &buf)];
        return files.openFile(iocp_io, std.Io.Dir.cwd(), path, options);
    }

    pub fn fileClose(userdata: ?*anyopaque, to_close: []const std.Io.File) void {
        const iocp = fromUserdata(userdata);
        for (to_close) |file| iocp.close(file);
    }

    /// Each pipe overlapped on this end; a `.file` the child writes as `spawn_file_writes` says.
    /// Blocks the thread while CreateProcessW runs.
    pub fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const iocp = anyThread(userdata);
        return spawn.spawn(iocp.scheduler.gpa, options, iocp.spawn_file_writes, iocp.spawn_inheritance);
    }

    /// Moves the streaming position the Iocp keeps for a disk file; a pipe can't seek.
    pub fn fileSeekBy(userdata: ?*anyopaque, file: std.Io.File, relative_offset: i64) std.Io.File.SeekError!void {
        const position = try fromUserdata(userdata).seekPosition(file);
        // As std: before the start, or past the largest offset, is Unseekable.
        position.* = (if (relative_offset >= 0)
            std.math.add(u64, position.*, @intCast(relative_offset))
        else
            std.math.sub(u64, position.*, @abs(relative_offset))) catch return error.Unseekable;
    }

    pub fn fileSeekTo(userdata: ?*anyopaque, file: std.Io.File, absolute_offset: u64) std.Io.File.SeekError!void {
        (try fromUserdata(userdata).seekPosition(file)).* = absolute_offset;
    }

    /// std falls back to reading and writing (std.Io.Threaded has no Windows fast path either).
    pub fn fileWriteFileStreaming(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: *std.Io.File.Reader, _: std.Io.Limit) std.Io.File.Writer.WriteFileError!usize {
        return error.Unimplemented;
    }

    pub fn fileWriteFilePositional(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: *std.Io.File.Reader, _: std.Io.Limit, _: u64) std.Io.File.WriteFilePositionalError!usize {
        return error.Unimplemented;
    }

    /// Waits on the port for the child to exit (other tasks run meanwhile), then cleans up.
    pub fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const iocp = fromUserdata(userdata);
        const handle = child.id.?;
        try iocp.waitSignaled(handle, .cancelable);
        var info: windows.PROCESS.BASIC_INFORMATION = undefined;
        const term: std.process.Child.Term = switch (windows.ntdll.NtQueryInformationProcess(handle, .BasicInformation, &info, @sizeOf(windows.PROCESS.BASIC_INFORMATION), null)) {
            // As std: the exit code's low byte.
            .SUCCESS => .{ .exited = @truncate(@backingInt(info.ExitStatus)) },
            // As std.
            else => .{ .unknown = 0 },
        };
        iocp.cleanup(child);
        return term;
    }

    /// Terminates the child (exit code 1, as std), waits on the port for it to be gone, then
    /// cleans up. As std, it cleans up whatever happens (a child that can't be terminated, or
    /// had exited: ACCESS_DENIED).
    pub fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
        const iocp = fromUserdata(userdata);
        iocp.terminate(child.id.?) catch {};
        iocp.cleanup(child);
    }

    pub fn batchAwaitAsync(userdata: ?*anyopaque, b: *std.Io.Batch) std.Io.Cancelable!void {
        fromUserdata(userdata).awaitBatch(b, .none) catch |err| switch (err) {
            error.Timeout => unreachable, // no timeout
            error.Canceled => |e| return e,
        };
    }

    pub fn batchAwaitConcurrent(userdata: ?*anyopaque, b: *std.Io.Batch, timeout: std.Io.Timeout) std.Io.Batch.AwaitConcurrentError!void {
        return fromUserdata(userdata).awaitBatch(b, timeout);
    }

    /// Cancels every pending operation (CancelIoEx), and waits for their packets: canceled ones
    /// go back to unused, the rest (finished before the cancel) to completed.
    pub fn batchCancel(userdata: ?*anyopaque, b: *std.Io.Batch) void {
        const iocp = fromUserdata(userdata);
        var index = b.pending.head;
        while (index != .none) {
            const pending = &b.storage[index.toIndex()].pending;
            const op = batchOp(pending);
            op.op.canceled = true;
            // As std, whatever it says (NOT_FOUND: it finished already): the packet comes either way.
            var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtCancelIoFileEx(op.file.handle, &op.op.iosb, &cancel_iosb);
            index = pending.node.next;
        }
        while (b.pending.head != .none) iocp.waitBatch(b, null, .uncancelable) catch unreachable; // no deadline, uncancelable
    }

    pub fn fileReadPositional(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const buffer = files.readBuffer(data) orelse return 0;
        const position: windows.LARGE_INTEGER = @intCast(offset);
        const status, const n = fromUserdata(userdata).read(file, buffer, &position);
        if (status == .CANCELLED) return error.Canceled;
        // As std: the end is 0 bytes.
        return files.readResult(status, n) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| e,
        };
    }

    pub fn fileWritePositional(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
        const buffer = files.writeBuffer(header, data, splat);
        if (buffer.len == 0) return 0;
        const position: windows.LARGE_INTEGER = @intCast(offset);
        const status, const n = fromUserdata(userdata).write(file, buffer, &position);
        if (status == .CANCELLED) return error.Canceled;
        return files.writeResult(status, n);
    }

    /// Streaming reads and writes (pipes, and disk files from their position). The other kinds
    /// panic, naming themselves.
    pub fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const iocp = fromUserdata(userdata);
        switch (operation) {
            .file_read_streaming => |o| return .{ .file_read_streaming = try readStreaming(iocp, o.file, o.data) },
            .file_write_streaming => |o| return .{ .file_write_streaming = try writeStreaming(iocp, o.file, o.header, o.data, o.splat) },
            else => std.debug.panic("winio.Iocp: std.Io's operate {t} isn't implemented", .{std.meta.activeTag(operation)}),
        }
    }
};

/// A cancelation point (its result has no error.Canceled: `operate` returns that).
fn readStreaming(iocp: *Iocp, file: std.Io.File, data: []const []u8) std.Io.Cancelable!std.Io.Operation.FileReadStreaming.Result {
    const buffer = files.readBuffer(data) orelse return 0;
    const position = iocp.streamPosition(file);
    const offset: windows.LARGE_INTEGER = if (position) |p| @intCast(p) else undefined;
    const status, const n = iocp.read(file, buffer, if (position != null) &offset else null);
    if (status == .CANCELLED) return error.Canceled;
    if (status == .SUCCESS and position != null) iocp.advance(file, n);
    return files.readResult(status, n);
}

/// A cancelation point (its result has no error.Canceled: `operate` returns that).
fn writeStreaming(iocp: *Iocp, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize) std.Io.Cancelable!std.Io.Operation.FileWriteStreaming.Result {
    const buffer = files.writeBuffer(header, data, splat);
    if (buffer.len == 0) return 0;
    const position = iocp.streamPosition(file);
    const offset: windows.LARGE_INTEGER = if (position) |p| @intCast(p) else undefined;
    const status, const n = iocp.write(file, buffer, if (position != null) &offset else null);
    if (status == .CANCELLED) return error.Canceled;
    if (status == .SUCCESS and position != null) iocp.advance(file, n);
    return files.writeResult(status, n);
}

// ---------------------------------------------------------------------------------------------
// Batches: each operation is started overlapped when awaited, and its packet moves it from the
// batch's pending list to completed.

/// A pending batch operation's state, in its `Operation.Storage.Pending.userdata`.
const BatchOp = struct {
    op: Op,
    file: std.Io.File,

    comptime {
        std.debug.assert(@sizeOf(BatchOp) <= @sizeOf(std.Io.Operation.Storage.Pending.Userdata));
        std.debug.assert(@alignOf(BatchOp) <= @alignOf(std.Io.Operation.Storage.Pending.Userdata));
    }
};

fn batchOp(pending: *std.Io.Operation.Storage.Pending) *BatchOp {
    return @ptrCast(&pending.userdata);
}

/// The file a batch operation reads or writes; other kinds panic.
fn batchFile(operation: std.Io.Operation) std.Io.File {
    return switch (operation) {
        .file_read_streaming => |o| o.file,
        .file_write_streaming => |o| o.file,
        else => std.debug.panic("winio.Iocp: a batch with operation {t} isn't implemented", .{std.meta.activeTag(operation)}),
    };
}

/// Starts the batch's submitted operations, then waits until one has completed (or none is
/// pending, or the timeout passes).
fn awaitBatch(iocp: *Iocp, b: *std.Io.Batch, timeout: std.Io.Timeout) (std.Io.Cancelable || error{Timeout})!void {
    var index = b.submitted.head;
    while (index != .none) {
        const submission = b.storage[index.toIndex()].submission;
        iocp.startBatchOp(b, index, submission.operation);
        index = submission.node.next;
    }
    b.submitted = .empty;
    const deadline = tasks.deadlineMs(timeout);
    while (b.completed.head == .none and b.pending.head != .none) try iocp.waitBatch(b, deadline, .cancelable);
}

/// Waits until one of the batch's pending operations completes (or is canceled), or `deadline`.
/// `.cancelable`: a cancelation point (the operations stay pending; `batchCancel` ends them).
fn waitBatch(_: *Iocp, b: *std.Io.Batch, deadline: ?u64, how: enum { cancelable, uncancelable }) (std.Io.Cancelable || error{Timeout})!void {
    var woken = false;
    b.userdata = &woken;
    defer b.userdata = null;
    const wait: tasks.Wait = .{ .flag = .{ .ptr = &woken, .deadline = deadline } };
    switch (how) {
        .cancelable => try tasks.blockCancelable(wait),
        .uncancelable => tasks.block(wait),
    }
    if (!woken) return error.Timeout;
}

fn startBatchOp(iocp: *Iocp, b: *std.Io.Batch, index: std.Io.Operation.OptionalIndex, operation: std.Io.Operation) void {
    const file = batchFile(operation);
    // Nothing to wait for: done now, and not canceled (only a wait for a packet is: `finish`).
    const done: ?std.Io.Operation.Result = switch (operation) {
        .file_read_streaming => |o| if (files.readBuffer(o.data) == null) .{ .file_read_streaming = 0 } else null,
        .file_write_streaming => |o| if (files.writeBuffer(o.header, o.data, o.splat).len == 0) .{ .file_write_streaming = 0 } else null,
        else => unreachable, // `batchFile`
    };
    if (done) |result| return appendCompleted(b, index, result);

    const storage = &b.storage[index.toIndex()];
    storage.* = .{ .pending = .{ .node = .{ .prev = b.pending.tail, .next = .none }, .tag = std.meta.activeTag(operation), .userdata = undefined } };
    switch (b.pending.tail) {
        .none => b.pending.head = index,
        else => |tail| b.storage[tail.toIndex()].pending.node.next = index,
    }
    b.pending.tail = index;
    const op = batchOp(&storage.pending);
    op.* = .{ .op = .{ .batch = b }, .file = file };

    const position = iocp.streamPosition(file);
    const offset: windows.LARGE_INTEGER = if (position) |p| @intCast(p) else undefined;
    const offset_ptr = if (position != null) &offset else null;
    const status = switch (operation) {
        .file_read_streaming => |o| s: {
            const buffer = files.readBuffer(o.data).?;
            break :s windows.ntdll.NtReadFile(file.handle, null, null, &op.op.iosb, &op.op.iosb, buffer.ptr, @intCast(buffer.len), offset_ptr, null);
        },
        .file_write_streaming => |o| s: {
            const buffer = files.writeBuffer(o.header, o.data, o.splat);
            break :s windows.ntdll.NtWriteFile(file.handle, null, null, &op.op.iosb, &op.op.iosb, buffer.ptr, @intCast(buffer.len), offset_ptr, null);
        },
        else => unreachable,
    };
    // An error status queues nothing (`finish`): it completes now, with that status.
    if (@backingInt(status) >> 30 == 3) {
        op.op.iosb = .{ .u = .{ .Status = status }, .Information = 0 };
        return iocp.batchOpCompleted(b, op);
    }
    iocp.pending += 1;
}

/// A pending batch operation finished (its packet arrived): from pending to completed, or to
/// unused if it was canceled. Wakes a waiter (`waitBatch`).
fn batchOpCompleted(iocp: *Iocp, b: *std.Io.Batch, op: *BatchOp) void {
    const pending: *std.Io.Operation.Storage.Pending = @fieldParentPtr("userdata", @as(*std.Io.Operation.Storage.Pending.Userdata, @ptrCast(op)));
    const storage: *std.Io.Operation.Storage = @fieldParentPtr("pending", pending);
    const index: std.Io.Operation.OptionalIndex = .fromIndex((@intFromPtr(storage) - @intFromPtr(b.storage.ptr)) / @sizeOf(std.Io.Operation.Storage));
    const tag = pending.tag;
    const file = op.file;
    const status = op.op.iosb.u.Status;
    const n = op.op.iosb.Information;
    switch (pending.node.prev) {
        .none => b.pending.head = pending.node.next,
        else => |prev| b.storage[prev.toIndex()].pending.node.next = pending.node.next,
    }
    switch (pending.node.next) {
        .none => b.pending.tail = pending.node.prev,
        else => |next| b.storage[next.toIndex()].pending.node.prev = pending.node.prev,
    }
    if (b.userdata) |woken| @as(*bool, @ptrCast(woken)).* = true;
    if (status == .CANCELLED) {
        if (!op.op.canceled) unexplainedCancel();
        const tail = b.unused.tail;
        switch (tail) {
            .none => b.unused.head = index,
            else => b.storage[tail.toIndex()].unused.next = index,
        }
        storage.* = .{ .unused = .{ .prev = tail, .next = .none } };
        b.unused.tail = index;
        return;
    }
    if (status == .SUCCESS and iocp.bound.get(file.handle).? != null) iocp.advance(file, n);
    appendCompleted(b, index, switch (tag) {
        .file_read_streaming => .{ .file_read_streaming = files.readResult(status, n) },
        .file_write_streaming => .{ .file_write_streaming = files.writeResult(status, n) },
        else => unreachable, // `batchFile`
    });
}

fn appendCompleted(b: *std.Io.Batch, index: std.Io.Operation.OptionalIndex, result: std.Io.Operation.Result) void {
    switch (b.completed.tail) {
        .none => b.completed.head = index,
        else => |tail| b.storage[tail.toIndex()].completion.node.next = index,
    }
    b.completed.tail = index;
    b.storage[index.toIndex()] = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
}

const builtin = @import("builtin");
const files = @import("files.zig");
const spawn = @import("spawn.zig");
const std = @import("std");
const tasks = @import("tasks.zig");
const win32 = @import("win32").everything;
const windows = std.os.windows;
