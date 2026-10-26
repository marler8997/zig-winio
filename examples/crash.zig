//! Crash handling for the examples, from https://github.com/marler8997/zig-win32-crash-handling
//! (its main.zig, for Zig 0.17 only). Every crash (panic, safety check, access violation, stack
//! overflow, ...) is logged to stderr with a stack trace, then shown in a message box. A GUI
//! program usually starts without a stderr (from Explorer, or from cmd without redirection);
//! then stderr becomes `<exe name>.log` next to the exe, so std.log and crash reports go there.
//!
//! The root file uses it with:
//!     pub const panic = crash.panic;
//!     pub const std_options: std.Options = .{ .enable_segfault_handler = false, ... };
//! and calls `crash.init()` first thing in `main`.
//!
//! Left out from the original: the SIGABRT handler (for C code calling abort(); the examples
//! don't link libc) and its stack-guarantee test.

/// The root file's `panic`: like std's, plus a message box after the report.
pub const panic = std.debug.FullPanic(onPanic);

const global = struct {
    /// The filter installed before ours (the mingw CRT's, in a program that links libc), which
    /// ours calls first. A filter gets no context argument, so this has to be a global.
    var previous_exception_filter: ?win32.LPTOP_LEVEL_EXCEPTION_FILTER = null;
    /// How far the panic handler got. A panic while logging or showing the message box re-enters
    /// the handler, which skips the step that panicked instead of recursing forever.
    var panic_state: enum { none, log, msgbox } = .none;
    /// Set while the filter writes its report. A fault while reporting re-enters the filter,
    /// which then skips the report and only shows the box, with the nested exception's code,
    /// so a fault that repeats every time doesn't recurse until the stack runs out.
    var reporting_exception = false;
};

/// The stack left after an overflow, for the filter to write the report and show the box.
/// Without it the filter overflows again and Windows ends the process with no report. Found by
/// trial for Zig 0.17.0 (1.6 MiB Debug, 0.7 MiB ReleaseSafe); see the original repository's test.
const stack_guarantee = 2 * 1024 * 1024;

/// Installs the handlers and makes sure there is a stderr. Call first thing in `main`, on the
/// main thread; another thread that should report a stack overflow calls `setStackGuarantee`.
pub fn init() void {
    global.previous_exception_filter = win32.SetUnhandledExceptionFilter(unhandledExceptionFilter);
    const params = std.os.windows.peb().ProcessParameters;
    if (!isUsableHandle(params.hStdError)) params.hStdError = createLogFile(params.ImagePathName);
    setStackGuarantee();
}

pub fn setStackGuarantee() void {
    var size: u32 = stack_guarantee;
    if (0 == win32.SetThreadStackGuarantee(&size)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
}

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    if (global.panic_state == .none) {
        global.panic_state = .log;
        // Before the message box, which may never be dismissed.
        std.debug.print("panic: {s}\n", .{msg});
        std.debug.dumpCurrentStackTrace(.{ .first_address = ret_addr orelse @returnAddress() });
    }
    if (global.panic_state == .log) {
        global.panic_state = .msgbox;
        msgbox("{s}", .{msg});
    }
    // Not std.debug.defaultPanic, which would print the message and trace again.
    std.process.abort();
}

/// Creates `<exe name>.log` next to the exe (the exe's path with `.log` for `.exe`).
fn createLogFile(exe_path: std.os.windows.UNICODE_STRING) std.os.windows.HANDLE {
    const exe = exe_path.Buffer.?[0 .. exe_path.Length / 2];
    const ext = win32.L(".exe");
    const stem = if (std.ascii.endsWithIgnoreCase(std.mem.sliceAsBytes(exe), std.mem.sliceAsBytes(ext))) exe[0 .. exe.len - ext.len] else exe;
    const log_ext = win32.L(".log");
    var path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    if (stem.len + log_ext.len > path_buf.len) @panic("exe path too long for the log path");
    @memcpy(path_buf[0..stem.len], stem);
    @memcpy(path_buf[stem.len..][0..log_ext.len], log_ext);
    path_buf[stem.len + log_ext.len] = 0;
    const handle = win32.CreateFileW(
        path_buf[0 .. stem.len + log_ext.len :0],
        win32.FILE_GENERIC_WRITE,
        .{ .READ = 1 },
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(log)", win32.GetLastError());
    return handle;
}

fn isUsableHandle(handle: std.os.windows.HANDLE) bool {
    if (@intFromPtr(handle) == 0) return false;
    // A parent that launches with handle inheritance can pass the value of a stderr handle it
    // didn't make inheritable, which isn't a handle in this process.
    win32.SetLastError(.NO_ERROR);
    return !(win32.GetFileType(handle) == .UNKNOWN and win32.GetLastError() == .ERROR_INVALID_HANDLE);
}

fn unhandledExceptionFilter(maybe_info: ?*win32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
    const continue_search: i32 = 0;
    const execute_handler: i32 = 1;
    if (global.previous_exception_filter) |previous| chain: {
        // mingw's filter (crt_handler.c) returns EXCEPTION_CONTINUE_EXECUTION for these, which
        // re-executes the faulting instruction forever.
        if (maybe_info) |i| switch (i.ExceptionRecord.?.ExceptionCode) {
            win32.EXCEPTION_DATATYPE_MISALIGNMENT,
            win32.EXCEPTION_ARRAY_BOUNDS_EXCEEDED,
            win32.EXCEPTION_FLT_STACK_CHECK,
            win32.EXCEPTION_INT_OVERFLOW,
            win32.EXCEPTION_INVALID_HANDLE,
            => break :chain,
            else => {},
        };
        const action = previous(maybe_info);
        if (action != continue_search) return action;
    }
    const info = maybe_info orelse return continue_search;
    const record = info.ExceptionRecord.?;
    // A Debug build's std.process.abort raises a breakpoint after a panic was already reported.
    if (record.ExceptionCode == win32.EXCEPTION_BREAKPOINT) return continue_search;

    if (!global.reporting_exception) {
        global.reporting_exception = true;
        var buf: [256]u8 = undefined;
        // The lock is recursive, so a panic in the code below can still take it.
        const stderr = std.debug.lockStderr(&buf).terminal();
        defer std.debug.unlockStderr();
        writeReport(stderr, info) catch {};
    }
    msgbox("unhandled exception 0x{X:0>8} at 0x{x}", .{ @backingInt(record.ExceptionCode), @intFromPtr(record.ExceptionAddress) });
    return execute_handler;
}

/// Writes the exception's code, address and module, then the stack trace from where it happened.
fn writeReport(t: std.Io.Terminal, info: *win32.EXCEPTION_POINTERS) error{WriteFailed}!void {
    const w = t.writer;
    const record = info.ExceptionRecord.?;
    const address = @intFromPtr(record.ExceptionAddress);
    try w.print("unhandled exception 0x{X:0>8} at 0x{x}", .{ @backingInt(record.ExceptionCode), address });
    // Flushed before anything that could fault again, so the code and address get out.
    try w.flush();
    try writeModule(w, address);
    try w.writeAll("\n");
    try w.flush();
    const context: *std.os.windows.CONTEXT = @ptrCast(@alignCast(info.ContextRecord.?));
    const native = std.debug.cpu_context.fromWindowsContext(context);
    try std.debug.writeCurrentStackTrace(.{ .context = &native }, t);
    try w.flush();
}

fn writeModule(w: *std.Io.Writer, address: usize) error{WriteFailed}!void {
    var module: ?win32.HINSTANCE = null;
    // With FROM_ADDRESS, lpModuleName is any address in the module.
    if (0 == win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(address),
        &module,
    )) return w.print(" (GetModuleHandleExW failed, error={f})", .{win32.GetLastError()});
    const offset = address - @intFromPtr(module.?);
    // MAX_PATH, not PATH_MAX_WIDE (64 KiB): this runs on the faulting thread's stack.
    var path_buf: [win32.MAX_PATH:0]u16 = undefined;
    const len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len + 1);
    if (len == 0 or len == path_buf.len + 1) return w.print(" (+0x{x})", .{offset});
    const path = path_buf[0..len];
    const name = path[if (std.mem.lastIndexOfScalar(u16, path, '\\')) |i| i + 1 else 0..];
    try w.print(" ({f}+0x{x})", .{ std.unicode.fmtUtf16Le(name), offset });
}

fn msgbox(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const len = if (std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args)) |text| text.len else |_| blk: {
        buf[buf.len - 4 ..][0..3].* = "...".*;
        break :blk buf.len - 1;
    };
    buf[len] = 0;
    _ = win32.MessageBoxA(null, buf[0..len :0], "crash", .{ .ICONHAND = 1 });
}

const std = @import("std");
const win32 = @import("win32").everything;
