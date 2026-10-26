//! For the tests: a child process that does one thing, `child <what> [args]`:
//! - `exit N`: exits with code N;
//! - `echo`: copies stdin to stdout;
//! - `stderr TEXT`: writes TEXT to stderr;
//! - `args ...`: writes each argument after `args`, each followed by a NUL, to stdout;
//! - `cwd`: writes its cwd to stdout;
//! - `env NAME`: writes the variable's value to stdout, or `<unset>`;
//! - `big N`: writes N bytes to stdout and N to stderr, alternating in small pieces, so a
//!   parent must read both at once (each pipe holds a few KiB);
//! - `sleep MS`: sleeps.
//! Uses no std.Io, so it tests nothing of winio's itself.

pub fn main(init: std.process.Init.Minimal) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const args = init.args.toSlice(arena) catch @panic("out of memory");
    if (args.len < 2) @panic("usage: child <what> [args]");
    const what = args[1];
    const stdout = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
    const stderr = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
    if (std.mem.eql(u8, what, "exit")) {
        win32.ExitProcess(std.fmt.parseInt(u32, args[2], 10) catch @panic("exit N"));
    } else if (std.mem.eql(u8, what, "echo")) {
        const stdin = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
        var buf: [4096]u8 = undefined;
        while (true) {
            var n: u32 = 0;
            if (0 == win32.ReadFile(stdin, &buf, buf.len, &n, null)) switch (win32.GetLastError()) {
                .ERROR_BROKEN_PIPE => break,
                else => |err| win32.panicWin32("ReadFile", err),
            };
            if (n == 0) break;
            write(stdout, buf[0..n]);
        }
    } else if (std.mem.eql(u8, what, "stderr")) {
        write(stderr, args[2]);
    } else if (std.mem.eql(u8, what, "args")) {
        for (args[2..]) |arg| {
            write(stdout, arg);
            write(stdout, "\x00");
        }
    } else if (std.mem.eql(u8, what, "cwd")) {
        var buf: [1024]u16 = undefined;
        const len = win32.GetCurrentDirectoryW(buf.len, @ptrCast(&buf));
        var out: [3 * 1024]u8 = undefined;
        write(stdout, out[0..std.unicode.wtf16LeToWtf8(&out, buf[0..len])]);
    } else if (std.mem.eql(u8, what, "env")) {
        var name: [256:0]u16 = undefined;
        name[std.unicode.wtf8ToWtf16Le(&name, args[2]) catch @panic("env NAME")] = 0;
        var buf: [1024]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(&name, @ptrCast(&buf), buf.len);
        if (len == 0) return write(stdout, "<unset>");
        var out: [3 * 1024]u8 = undefined;
        write(stdout, out[0..std.unicode.wtf16LeToWtf8(&out, buf[0..len])]);
    } else if (std.mem.eql(u8, what, "big")) {
        var left = std.fmt.parseInt(usize, args[2], 10) catch @panic("big N");
        var piece: [1000]u8 = undefined;
        for (&piece, 0..) |*c, i| c.* = @intCast('a' + i % 26);
        while (left > 0) {
            const n = @min(left, piece.len);
            write(stdout, piece[0..n]);
            write(stderr, piece[0..n]);
            left -= n;
        }
    } else if (std.mem.eql(u8, what, "sleep")) {
        win32.Sleep(std.fmt.parseInt(u32, args[2], 10) catch @panic("sleep MS"));
    } else std.debug.panic("child: unknown '{s}'", .{what});
}

fn write(handle: ?win32.HANDLE, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        var n: u32 = 0;
        if (0 == win32.WriteFile(handle, rest.ptr, @intCast(rest.len), &n, null)) win32.panicWin32("WriteFile", win32.GetLastError());
        rest = rest[n..];
    }
}

const std = @import("std");
const win32 = @import("win32").everything;
