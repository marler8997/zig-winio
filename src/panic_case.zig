//! For the tests: `panic_case <case>` does one thing on a winio Io that must panic, and the
//! test checks the message. A case is a Fibers', or with `iocp.` before it an Iocp's:
//! - a std.Io.VTable field the Io doesn't implement: it's called directly, with undefined
//!   arguments (the stub never reads them). With `layer.` before it, on a Fibers.Layer, which
//!   forwards most of them to the Io under it, here `inner_io`, whose every operation panics
//!   naming itself;
//! - `operate.<tag>`: an Iocp's `io.operate` with that kind of operation;
//! - a `Misuse` (Fibers) or `IocpMisuse`: a mistake the Io must catch.

/// Prints the message alone and exits with code 3: quick, so many cases can run, and easy to
/// check.
pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, _: ?usize) noreturn {
        const stderr = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
        var written: u32 = undefined;
        _ = win32.WriteFile(stderr, msg.ptr, @intCast(msg.len), &written, null);
        win32.ExitProcess(3);
    }
}.panic);

pub const Misuse = enum {
    second_init,
    io_after_deinit,
    deinit_with_unfinished_task,
    /// The root fiber (outside the message loop) awaits a task that waits forever.
    await_deadlock,
    /// The root fiber (outside the message loop) waits on a futex, with no task to wake it.
    futex_wait_deadlock,
    now_cpu_process,
    now_cpu_thread,
    /// A window procedure, dispatched by `runMessageLoop`, blocks on a Mutex (held by the root fiber).
    futex_wait_in_window_procedure,
    /// A task started with a fibers's io on a second thread, after the first bound it (in any
    /// build mode).
    concurrent_from_another_thread,
    /// `runMessageLoop` on a second thread, after the first bound the Fibers (in any build mode).
    run_from_another_thread,
};

pub const IocpMisuse = enum {
    second_init,
    io_after_deinit,
    deinit_with_unfinished_task,
    /// The root fiber awaits a task that waits forever.
    await_deadlock,
    /// The root fiber waits on a futex, with no task to wake it.
    futex_wait_deadlock,
    recancel_without_canceled,
    /// A read from a synchronous pipe (CreatePipe).
    synchronous_handle,
    /// A read from an overlapped pipe whose `File.flags.nonblocking` is false.
    nonblocking_flag_wrong,
    /// A task's pending read canceled outside winio (CancelIoEx).
    canceled_outside,
};

pub fn main(init: std.process.Init.Minimal) void {
    // In main, not at the top: the tests import this file (its cases) and may lack runtime safety.
    if (!std.debug.runtime_safety) @compileError("panic_case needs runtime safety to test for unreachable");
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const args = init.args.toSlice(arena_state.allocator()) catch @panic("out of memory");
    if (args.len != 2) @panic("usage: panic_case <case>");
    const case = args[1];
    if (std.mem.startsWith(u8, case, "iocp.")) iocpCase(case["iocp.".len..]) else if (std.mem.startsWith(u8, case, "layer.")) layerCase(case["layer.".len..]) else fibersCase(case);
    @panic("panic_case: the case returned without panicking");
}

/// Calls the operation `case` names, if `Io` doesn't implement it, or `operate.<tag>`.
fn callUnimplemented(comptime Io: type, io: std.Io, case: []const u8) void {
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| {
        if (comptime Io.support(name) != .implemented) {
            if (std.mem.eql(u8, case, name)) {
                const f = @field(io.vtable, name);
                var call_args: std.meta.ArgsTuple(@typeInfo(@TypeOf(f)).pointer.child) = undefined;
                call_args[0] = io.userdata;
                std.mem.doNotOptimizeAway(@call(.auto, f, call_args));
                @panic("panic_case: " ++ name ++ " returned without panicking");
            }
        }
    }
    inline for (@typeInfo(std.Io.Operation).@"union".field_names) |tag| {
        if (std.mem.eql(u8, case, "operate." ++ tag)) {
            _ = io.operate(@unionInit(std.Io.Operation, tag, undefined)) catch {};
            @panic("panic_case: operate." ++ tag ++ " returned without panicking");
        }
    }
}

fn iocpCase(case: []const u8) void {
    var iocp: Iocp = undefined;
    iocp.init(std.heap.page_allocator, .{});
    const io = iocp.io();
    callUnimplemented(Iocp, io, case);
    const misuse = std.meta.stringToEnum(IocpMisuse, case) orelse std.debug.panic("panic_case: unknown case 'iocp.{s}'", .{case});
    const word: u32 = 0;
    switch (misuse) {
        .second_init => {
            var second: Iocp = undefined;
            second.init(std.heap.page_allocator, .{});
        },
        .io_after_deinit => {
            iocp.deinit();
            var task = io.concurrent(noop, .{}) catch unreachable;
            task.await(io);
        },
        .deinit_with_unfinished_task => {
            _ = io.concurrent(noop, .{}) catch unreachable;
            iocp.deinit();
        },
        .await_deadlock => {
            var task = io.concurrent(waitForever, .{ io, &word }) catch unreachable;
            task.await(io);
        },
        .futex_wait_deadlock => io.futexWaitUncancelable(u32, &word, 0),
        .recancel_without_canceled => io.recancel(),
        .synchronous_handle => {
            var r: ?win32.HANDLE = undefined;
            var w: ?win32.HANDLE = undefined;
            if (0 == win32.CreatePipe(&r, &w, null, 0)) win32.panicWin32("CreatePipe", win32.GetLastError());
            readOne(io, .{ .handle = r.?, .flags = .{ .nonblocking = true } });
        },
        .nonblocking_flag_wrong => {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-panic-case");
            const server = win32.CreateNamedPipeW(name, .{ .FILE_ATTRIBUTE_READONLY = 1, .FILE_FLAG_OVERLAPPED = 1 }, .{}, 1, 0, 4096, 0, null);
            if (server == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateNamedPipeW", win32.GetLastError());
            readOne(io, .{ .handle = server, .flags = .{ .nonblocking = false } });
        },
        .canceled_outside => {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-panic-case-closed");
            const server = win32.CreateNamedPipeW(name, .{ .FILE_ATTRIBUTE_READONLY = 1, .FILE_FLAG_OVERLAPPED = 1 }, .{}, 1, 0, 4096, 0, null);
            if (server == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateNamedPipeW", win32.GetLastError());
            // Connected (unconnected, a read fails at once), and never written: the read stays pending.
            const client = win32.CreateFileW(name, .{ .FILE_WRITE_DATA = 1, .SYNCHRONIZE = 1 }, .{}, null, .OPEN_EXISTING, .{ .FILE_FLAG_OVERLAPPED = 1 }, null);
            if (client == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFileW(client)", win32.GetLastError());
            const file: std.Io.File = .{ .handle = server, .flags = .{ .nonblocking = true } };
            var reader = io.concurrent(readOne, .{ io, file }) catch unreachable;
            io.sleep(.fromMilliseconds(20), .awake) catch unreachable;
            // Canceled behind the Iocp's back: the pending read ends CANCELLED.
            if (0 == win32.CancelIoEx(server, null)) win32.panicWin32("CancelIoEx", win32.GetLastError());
            reader.await(io);
        },
    }
}

fn readOne(io: std.Io, file: std.Io.File) void {
    var buf: [1]u8 = undefined;
    _ = file.readStreaming(io, &.{&buf}) catch {};
}

fn waitForever(io: std.Io, word: *const u32) void {
    io.futexWaitUncancelable(u32, word, 0);
}

/// An operation a Fibers.Layer doesn't implement: it panics, or the Io under it does.
fn layerCase(case: []const u8) void {
    var fibers: Fibers = .init(std.heap.page_allocator);
    var layer: Fibers.Layer = .{ .base = &fibers, .inner = inner_io };
    callUnimplemented(Fibers.Layer, layer.io(), case);
    std.debug.panic("panic_case: unknown case 'layer.{s}'", .{case});
}

fn fibersCase(case: []const u8) void {
    var fibers: Fibers = .init(std.heap.page_allocator);
    const io = fibers.io();
    // Bound to this thread by its first task.
    var first = io.concurrent(noop, .{}) catch unreachable;
    first.await(io);
    callUnimplemented(Fibers, io, case);
    const misuse = std.meta.stringToEnum(Misuse, case) orelse std.debug.panic("panic_case: unknown case '{s}'", .{case});
    switch (misuse) {
        .concurrent_from_another_thread, .run_from_another_thread => {
            // A raw thread: this exe is single-threaded (std.Thread isn't available); the second
            // thread only makes one call, which panics.
            other_fibers = &fibers;
            other_misuse = misuse;
            const thread = win32.CreateThread(null, 0, onAnotherThread, null, .{}, null) orelse
                win32.panicWin32("CreateThread", win32.GetLastError());
            _ = win32.WaitForSingleObject(thread, win32.INFINITE);
        },
        .second_init => {
            // Its first task would make this thread its, which is the first Fibers' already.
            var second: Fibers = .init(std.heap.page_allocator);
            _ = second.io().concurrent(noop, .{}) catch unreachable;
        },
        .io_after_deinit => {
            fibers.deinit();
            var task = io.concurrent(noop, .{}) catch unreachable;
            task.await(io);
        },
        .deinit_with_unfinished_task => {
            _ = io.concurrent(noop, .{}) catch unreachable;
            fibers.deinit();
        },
        .await_deadlock => {
            const word: u32 = 0;
            var task = io.concurrent(waitForever, .{ io, &word }) catch unreachable;
            task.await(io);
        },
        .futex_wait_deadlock => {
            const word: u32 = 0;
            io.futexWaitUncancelable(u32, &word, 0);
        },
        .now_cpu_process => _ = std.Io.Timestamp.now(io, .cpu_process),
        .now_cpu_thread => _ = std.Io.Timestamp.now(io, .cpu_thread),
        .futex_wait_in_window_procedure => {
            held_mutex.lockUncancelable(io);
            fibers_io = io;
            const class = std.unicode.utf8ToUtf16LeStringLiteral("winio-panic-case");
            const instance = win32.GetModuleHandleW(null);
            _ = win32.RegisterClassExW(&.{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = .{},
                .lpfnWndProc = &lockingWndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = instance,
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = class,
                .hIconSm = null,
            });
            const hwnd = win32.CreateWindowExW(.{}, class, class, .{}, 0, 0, 0, 0, win32.HWND_MESSAGE, null, instance, null) orelse
                win32.panicWin32("CreateWindowExW", win32.GetLastError());
            _ = win32.PostMessageW(hwnd, win32.WM_APP, 0, 0);
            _ = fibers.runMessageLoop();
        },
    }
}

var held_mutex: std.Io.Mutex = .init;
var fibers_io: std.Io = undefined;

fn lockingWndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_APP) held_mutex.lockUncancelable(fibers_io);
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn noop() void {}

var other_fibers: *Fibers = undefined;
var other_misuse: Misuse = undefined;

fn onAnotherThread(_: ?*anyopaque) callconv(.winapi) u32 {
    const io = other_fibers.io();
    switch (other_misuse) {
        .concurrent_from_another_thread => {
            var task = io.concurrent(noop, .{}) catch unreachable;
            task.await(io);
        },
        .run_from_another_thread => _ = other_fibers.runMessageLoop(),
        else => unreachable,
    }
    return 0;
}

const std = @import("std");
const win32 = @import("win32").everything;
const Iocp = @import("Iocp.zig");
const Fibers = @import("Fibers.zig");
const tasks = @import("tasks.zig");

/// The Io under the Layer: every operation panics, naming itself ("winio.inner: std.Io's <op>
/// isn't implemented"), so a forwarded call shows it reached the right one.
const inner_io: std.Io = .{ .userdata = null, .vtable = &tasks.makeOwnVtable(.{
    .name = "inner",
    .sources = &.{},
    .not_implemented = @typeInfo(std.Io.VTable).@"struct".field_names,
}) };
