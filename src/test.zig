//! winio's tests. Each runs tasks on the message loop until one posts WM_QUIT.

test "a task sleeps while the loop waits" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    const start = std.Io.Timestamp.now(io, .awake);
    var task = try io.concurrent(sleepThenQuit, .{ io, 50 });
    // WM_QUIT's wParam: what the task gave PostQuitMessage.
    try std.testing.expectEqual(@as(win32.WPARAM, 7), fibers.runMessageLoop());
    task.await(io);
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed.toMilliseconds() >= 50);
}

fn sleepThenQuit(io: std.Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch unreachable; // never canceled
    win32.PostQuitMessage(7);
}

test "a task awaits another's result" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var outer = try io.concurrent(awaitDouble, .{io});
    _ = fibers.runMessageLoop();
    try std.testing.expectEqual(@as(u32, 42), outer.await(io));
}

fn awaitDouble(io: std.Io) u32 {
    var inner = io.concurrent(double, .{ io, 21 }) catch unreachable; // never fails
    const result = inner.await(io);
    win32.PostQuitMessage(0);
    return result;
}

fn double(io: std.Io, n: u32) u32 {
    // Parks, so the awaiting task really waits on it.
    io.sleep(.fromMilliseconds(10), .awake) catch unreachable; // never canceled
    return n * 2;
}

test "a Layer forwards files to the Io under it: a task writes a file and reads it back" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    var layer: Fibers.Layer = .{ .base = &fibers, .inner = std.testing.io };
    const io = layer.io();
    var task = try io.concurrent(writeReadDelete, .{io});
    _ = fibers.runMessageLoop();
    try task.await(io);
}

const test_file = "winio-test.txt";

fn writeReadDelete(io: std.Io) !void {
    defer win32.PostQuitMessage(0);
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, test_file, .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, "hello from a task", 0);
        try std.testing.expectEqual(@as(u64, 17), try file.length(io));
    }
    {
        const file = try cwd.openFile(io, test_file, .{});
        defer file.close(io);
        var buf: [64]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("hello from a task", buf[0..n]);
        // Past the end.
        try std.testing.expectEqual(@as(usize, 0), try file.readPositional(io, &.{&buf}, 100));
    }
    try cwd.deleteFile(io, test_file);
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, test_file, .{}));
}

test "a Layer forwards files from the root fiber too" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    var layer: Fibers.Layer = .{ .base = &fibers, .inner = std.testing.io };
    const io = layer.io();
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, test_file, .{ .read = true });
    try file.writePositionalAll(io, "from the loop", 0);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    file.close(io);
    try cwd.deleteFile(io, test_file);
    try std.testing.expectEqualStrings("from the loop", buf[0..n]);
}

test "a canceled task gets error.Canceled from a forwarded operation, which doesn't start" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    var layer: Fibers.Layer = .{ .base = &fibers, .inner = std.testing.io };
    const io = layer.io();
    var task = try io.concurrent(openAfterProtectedSleep, .{io});
    try std.testing.expectError(error.Canceled, task.cancel(io));
}

/// Sleeps with cancelation blocked, so the cancel arrives during the sleep and stays pending;
/// the next cancelation point is the forwarded openFile, which would succeed if it ran.
fn openAfterProtectedSleep(io: std.Io) !void {
    const previous = io.swapCancelProtection(.blocked);
    io.sleep(.fromMilliseconds(20), .awake) catch unreachable; // protected
    _ = io.swapCancelProtection(previous);
    const file = try std.Io.Dir.cwd().openFile(io, "build.zig", .{});
    file.close(io);
}

test "an event set by one task wakes another; a timed wait times out" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var event: std.Io.Event = .unset;
    var order: [3]u8 = undefined;
    var n: usize = 0;
    var waiter = try io.concurrent(waitEventThenQuit, .{ io, &event, &order, &n });
    var setter = try io.concurrent(setEventLater, .{ io, &event, &order, &n });
    _ = fibers.runMessageLoop();
    try waiter.await(io);
    setter.await(io);
    // The waiter timed out once (`t`), then the setter set it (`s`) and the waiter woke (`w`).
    try std.testing.expectEqualStrings("tsw", order[0..n]);
}

fn waitEventThenQuit(io: std.Io, event: *std.Io.Event, order: *[3]u8, n: *usize) !void {
    defer win32.PostQuitMessage(0);
    try std.testing.expectError(error.Timeout, event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }));
    order[n.*] = 't';
    n.* += 1;
    event.waitUncancelable(io);
    order[n.*] = 'w';
    n.* += 1;
}

fn setEventLater(io: std.Io, event: *std.Io.Event, order: *[3]u8, n: *usize) void {
    io.sleep(.fromMilliseconds(40), .awake) catch unreachable; // never canceled
    order[n.*] = 's';
    n.* += 1;
    event.set(io);
}

test "a futex wake wakes at most max_waiters" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    // The word never changes, so only a wake ends a wait.
    const word: u32 = 0;
    var woken: u32 = 0;
    var a = try io.concurrent(waitOnWord, .{ io, &word, &woken });
    var b = try io.concurrent(waitOnWord, .{ io, &word, &woken });
    var waker = try io.concurrent(wakeOneThenOne, .{ io, &word, &woken });
    _ = fibers.runMessageLoop();
    try waker.await(io);
    a.await(io);
    b.await(io);
}

fn waitOnWord(io: std.Io, word: *const u32, woken: *u32) void {
    io.futexWait(u32, word, 0) catch unreachable; // never canceled
    woken.* += 1;
}

fn wakeOneThenOne(io: std.Io, word: *const u32, woken: *u32) !void {
    defer win32.PostQuitMessage(0);
    // Let both park.
    try io.sleep(.fromMilliseconds(10), .awake);
    io.futexWake(u32, word, 1);
    try io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expectEqual(@as(u32, 1), woken.*);
    io.futexWake(u32, word, 1);
    try io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expectEqual(@as(u32, 2), woken.*);
}

test "async and cancel: a canceled sleep returns error.Canceled; cancel waits for the result" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var task = try io.concurrent(asyncThenCancel, .{io});
    _ = fibers.runMessageLoop();
    try task.await(io);
}

fn asyncThenCancel(io: std.Io) !void {
    defer win32.PostQuitMessage(0);
    const start = std.Io.Timestamp.now(io, .awake);
    var sleeping = io.async(sleepThenDouble, .{ io, 4 });
    try std.testing.expectError(error.Canceled, sleeping.cancel(io));
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 1000);
    // No cancelation point in it: the request goes unseen, and the result comes back.
    var plain = io.async(plainDouble, .{4});
    try std.testing.expectEqual(@as(u32, 8), plain.cancel(io));
}

/// Doubles `n` after a long sleep, unless canceled.
fn sleepThenDouble(io: std.Io, n: u32) error{Canceled}!u32 {
    try io.sleep(.fromSeconds(10), .awake);
    return n * 2;
}

fn plainDouble(n: u32) u32 {
    return n * 2;
}

test "after the message loop, the root fiber cancels and awaits tasks, running them meanwhile" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var sleeping = try io.concurrent(sleepThenDouble, .{ io, 4 });
    var quitter = try io.concurrent(sleepThenQuit, .{ io, 10 });
    _ = fibers.runMessageLoop();
    quitter.await(io);
    // Still sleeping: the cancel runs it until its sleep returns error.Canceled.
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, sleeping.cancel(io));
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 1000);
    // Started after the message loop: the await runs it, sleep and all.
    var later = try io.concurrent(awaitDoubleOf, .{ io, 21 });
    try std.testing.expectEqual(@as(u32, 42), later.await(io));
}

test "the root fiber sleeps, and waits out a futex's timeout" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    const start = std.Io.Timestamp.now(io, .awake);
    try io.sleep(.fromMilliseconds(20), .awake);
    const word: u32 = 0;
    try io.futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } });
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() >= 40);
}

test "now: the real clock is the system's; awake and boot only go forward" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var ft: win32.FILETIME = undefined;
    win32.GetSystemTimePreciseAsFileTime(&ft);
    // 100 ns units since 1601.
    const system_100ns: i96 = (@as(i96, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const system_ns = (system_100ns - 116444736000000000) * 100;
    const real = std.Io.Timestamp.now(io, .real).nanoseconds;
    try std.testing.expect(@abs(real - system_ns) < std.time.ns_per_s);
    for ([_]std.Io.Clock{ .awake, .boot }) |clock| {
        const a = std.Io.Timestamp.now(io, clock).nanoseconds;
        try io.sleep(.fromMilliseconds(5), .awake);
        const b = std.Io.Timestamp.now(io, clock).nanoseconds;
        try std.testing.expect(b - a >= 5 * std.time.ns_per_ms);
    }
}

test "crashHandler does nothing (std calls it mid-panic)" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    io.vtable.crashHandler(io.userdata);
}

test "window messages are dispatched while a task waits" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    const class = std.unicode.utf8ToUtf16LeStringLiteral("winio-test");
    const instance = win32.GetModuleHandleW(null);
    _ = win32.RegisterClassExW(&.{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = &recordingWndProc,
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
    defer _ = win32.DestroyWindow(hwnd);
    dispatched_while = null;
    sleeper_finished = false;
    var sleeper = try io.concurrent(sleepThenFinish, .{io});
    var poster = try io.concurrent(postTo, .{hwnd});
    _ = fibers.runMessageLoop();
    sleeper.await(io);
    poster.await(io);
    // The window procedure ran, and the sleeping task hadn't finished yet.
    try std.testing.expectEqual(@as(?bool, false), dispatched_while);
}

/// What `sleeper_finished` was when the window procedure ran.
var dispatched_while: ?bool = null;
var sleeper_finished = false;

fn sleepThenFinish(io: std.Io) void {
    io.sleep(.fromMilliseconds(40), .awake) catch unreachable; // never canceled
    sleeper_finished = true;
    win32.PostQuitMessage(0);
}

fn postTo(hwnd: win32.HWND) void {
    if (0 == win32.PostMessageW(hwnd, win32.WM_APP, 0, 0)) win32.panicWin32("PostMessageW", win32.GetLastError());
}

fn recordingWndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_APP) {
        dispatched_while = sleeper_finished;
        return 0;
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// std's `File.writer` writes positionally until the file says it can't seek. On Windows a pipe
// never does: NtWriteFile ignores the offset there (measured, .amp/in/seekpipe).
test "Iocp: std's positional-first File.Writer on an overlapped pipe" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-positional"));
    defer read_end.close(io);
    {
        defer write_end.close(io);
        var buf: [4]u8 = undefined;
        var writer = write_end.writer(io, &buf);
        try writer.interface.writeAll("one, ");
        try writer.interface.writeAll("two");
        try writer.interface.flush();
    }
    var out: [32]u8 = undefined;
    var buf: [8]u8 = undefined;
    var reader = read_end.readerStreaming(io, &buf);
    var out_writer: std.Io.Writer = .fixed(&out);
    try std.testing.expectEqualStrings("one, two", out[0..try reader.interface.streamRemaining(&out_writer)]);
}

// ---------------------------------------------------------------------------------------------
// The whole std.Io interface: each operation the Fibers implement is tested above; each other one
// is unreachable on their io, and reaches the Io under a Layer.

/// The Fibers' own operations, which the tests above exercise. Implementing another fails "every
/// operation is the Fibers' own and tested, ..." until its test is added and it's listed here.
const tested = [_][]const u8{
    "concurrent",  "async",                 "await",     "cancel",
    "futexWait",   "futexWaitUncancelable", "futexWake", "sleep",
    "now",         "crashHandler",          "recancel",  "swapCancelProtection",
    "checkCancel",
};

/// The Fibers' own operations it doesn't implement yet (they panic saying so).
const expected_not_implemented = [_][]const u8{ "groupAsync", "groupConcurrent", "groupAwait", "groupCancel" };

test "every operation is the Fibers' own and tested, their own and not implemented, or what a Layer forwards" {
    @setEvalBranchQuota(100_000);
    var mismatches: std.ArrayList(u8) = .empty;
    defer mismatches.deinit(std.testing.allocator);
    var forwarded: usize = 0;
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| {
        const is_tested = comptime for (tested) |t| {
            if (std.mem.eql(u8, t, name)) break true;
        } else false;
        const is_not_implemented = comptime for (expected_not_implemented) |u| {
            if (std.mem.eql(u8, u, name)) break true;
        } else false;
        const support = comptime Fibers.support(name);
        const layer_support = comptime Fibers.Layer.support(name);
        if ((support == .implemented) != is_tested or (support == .unimplemented) != is_not_implemented or
            (support == .@"unreachable") != (layer_support == .forwarded) or
            (support != .@"unreachable" and support != layer_support))
            try mismatches.print(std.testing.allocator, "  {s}: {t}, Layer: {t}, tested={}, expected not implemented={}\n", .{ name, support, layer_support, is_tested, is_not_implemented });
        if (layer_support == .forwarded) forwarded += 1;
    }
    if (mismatches.items.len > 0) {
        std.debug.print("operations whose support doesn't match the tests:\n{s}", .{mismatches.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(forwarded > 80);
}

test "every operation the Fibers don't implement panics, is unreachable, or reaches the Io under a Layer" {
    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(std.testing.allocator);
    var cases: usize = 0;
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| {
        switch (comptime Fibers.support(name)) {
            .implemented => {},
            .unimplemented => {
                try expectPanic(&failures, name, "winio.Fibers: std.Io's " ++ name ++ " isn't implemented");
                try expectPanic(&failures, "layer." ++ name, "winio.Fibers: std.Io's " ++ name ++ " isn't implemented");
            },
            .@"unreachable" => {
                try expectPanic(&failures, name, "reached unreachable code");
                // panic_case's Io under the Layer panics, naming the operation it got.
                try expectPanic(&failures, "layer." ++ name, "winio.inner: std.Io's " ++ name ++ " isn't implemented");
            },
            .forwarded => unreachable,
        }
        cases += 1;
    }
    if (failures.items.len > 0) {
        std.debug.print("{s}", .{failures.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(cases > 80);
}

test "misuse panics, saying what went wrong" {
    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(std.testing.allocator);
    inline for (@typeInfo(panic_case.Misuse).@"enum".field_names) |name| {
        const expected = switch (@field(panic_case.Misuse, name)) {
            .second_init => "this thread is a fiber already",
            .io_after_deinit, .concurrent_from_another_thread => "used on a thread it doesn't belong to, or after deinit",
            .run_from_another_thread => "winio.Fibers.runMessageLoop: the Fibers belong to another thread, or were deinited",
            .deinit_with_unfinished_task => "deinit with 1 tasks not finished",
            .await_deadlock, .futex_wait_deadlock => "winio.Fibers: a wait nothing could end",
            .now_cpu_process => "the cpu_process clock isn't implemented",
            .now_cpu_thread => "the cpu_thread clock isn't implemented",
            .futex_wait_in_window_procedure => "winio.Fibers: a window procedure (the root fiber, inside runMessageLoop) waits on a futex",
        };
        try expectPanic(&failures, name, expected);
    }
    if (failures.items.len > 0) {
        std.debug.print("{s}", .{failures.items});
        return error.TestUnexpectedResult;
    }
}

/// Runs `panic_case <case>`; adds a line to `failures` unless it panicked with `expected` in its
/// message.
fn expectPanic(failures: *std.ArrayList(u8), case: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_options.panic_case, case } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const exited_3 = switch (result.term) {
        .exited => |code| code == 3,
        else => false,
    };
    if (!exited_3 or std.mem.indexOf(u8, result.stderr, expected) == null)
        try failures.print(gpa, "{s}: expected a panic with \"{s}\", got {any}: {s}\n", .{ case, expected, result.term, result.stderr });
}

// ---------------------------------------------------------------------------------------------
// winio.Iocp: the root fiber runs the loop whenever it waits, so the tests just await.

/// A blocking Io besides the Iocp's: for what must not go through it (a synchronous file).
const blocking = std.testing.io;

test "Iocp: the root fiber runs a sleeping task while it awaits it" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const start = std.Io.Timestamp.now(io, .awake);
    var task = try io.concurrent(sleepMs, .{ io, 50 });
    task.await(io);
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() >= 50);
}

fn sleepMs(io: std.Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch unreachable; // never canceled
}

test "Iocp: a task awaits another; async and cancel" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var outer = try io.concurrent(awaitDoubleOf, .{ io, 21 });
    try std.testing.expectEqual(@as(u32, 42), outer.await(io));
    var sleeping = io.async(sleepThenDouble, .{ io, 4 });
    try std.testing.expectError(error.Canceled, sleeping.cancel(io));
    var plain = io.async(plainDouble, .{4});
    try std.testing.expectEqual(@as(u32, 8), plain.cancel(io));
    // Twice: idempotent.
    try std.testing.expectEqual(@as(u32, 8), plain.cancel(io));
}

fn awaitDoubleOf(io: std.Io, n: u32) u32 {
    var inner = io.concurrent(double, .{ io, n }) catch unreachable; // never fails
    return inner.await(io);
}

test "Iocp: the root fiber waits on an event a task sets; a timed wait times out" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var event: std.Io.Event = .unset;
    try std.testing.expectError(error.Timeout, event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }));
    var setter = try io.concurrent(setAfter, .{ io, &event, 20 });
    // Unlike the root fiber inside runMessageLoop, this wait runs the setter meanwhile.
    event.waitUncancelable(io);
    setter.await(io);
    try std.testing.expect(event.isSet());
}

fn setAfter(io: std.Io, event: *std.Io.Event, ms: i64) void {
    sleepMs(io, ms);
    event.set(io);
}

test "Iocp: files, from a task and from the root fiber" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var task = try io.concurrent(writeReadBack, .{ io, "winio-iocp-task.txt", "written by a task" });
    try writeReadBack(io, "winio-iocp-own.txt", "written by the root fiber");
    try task.await(io);
}

fn writeReadBack(io: std.Io, name: []const u8, text: []const u8) !void {
    {
        const file = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, text, 0);
        // Forwarded to the Iocp's std.Io.Threaded: it works on an overlapped file.
        try std.testing.expectEqual(@as(u64, text.len), try file.length(io));
        // Overwrites the start.
        try file.writePositionalAll(io, "W", 0);
    }
    {
        const file = try std.Io.Dir.cwd().openFile(io, name, .{});
        defer file.close(io);
        var buf: [64]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings(text[1..], buf[1..n]);
        try std.testing.expectEqual(@as(u8, 'W'), buf[0]);
        // From an offset, and past the end.
        try std.testing.expectEqual(@as(usize, n - 1), try file.readPositional(io, &.{&buf}, 1));
        try std.testing.expectEqual(@as(usize, 0), try file.readPositional(io, &.{&buf}, 1000));
    }
    try std.Io.Dir.cwd().deleteFile(io, name);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, name, .{}));
}

test "Iocp: opening an absolute path" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const name = "winio-iocp-absolute.txt";
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, name, .{});
        defer file.close(io);
        try std.testing.expectEqual(.ok, Iocp.checkHandle(file));
        try file.writePositionalAll(io, "absolute", 0);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const again = try cwd.openFile(io, path_buf[0..try file.realPath(io, &path_buf)], .{});
        defer again.close(io);
        var buf: [64]u8 = undefined;
        const n = try again.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("absolute", buf[0..n]);
    }
    try cwd.deleteFile(io, name);
}

test "Iocp: opening as std: a directory by default, not with allow_directory = false" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const dir = try std.Io.Dir.cwd().openFile(io, "src", .{});
    dir.close(io);
    try std.testing.expectError(error.IsDir, std.Io.Dir.cwd().openFile(io, "src", .{ .allow_directory = false }));
    try std.testing.expectError(error.IsDir, std.Io.Dir.cwd().openFile(io, ".", .{ .allow_directory = false }));
    // Writing rules a directory out (as std).
    try std.testing.expectError(error.IsDir, std.Io.Dir.cwd().openFile(io, "src", .{ .mode = .read_write }));
}

test "Iocp: a file another holds unshared is retried (as std), other tasks running meanwhile" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const name = "winio-iocp-unshared.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = "held" });
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    // Held with no sharing: an open meanwhile gets SHARING_VIOLATION.
    const held = win32.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral(name), win32.FILE_GENERIC_READ, .{}, null, .OPEN_EXISTING, .{}, null);
    if (held == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFileW", win32.GetLastError());
    var releaser = try io.concurrent(closeAfter, .{ io, held, 100 });
    var stop = false;
    var ticks: usize = 0;
    var ticker = try io.concurrent(tick, .{ io, &stop, &ticks });
    const file = try std.Io.Dir.cwd().openFile(io, name, .{});
    defer file.close(io);
    stop = true;
    ticker.await(io);
    releaser.await(io);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("held", buf[0..try file.readPositionalAll(io, &buf, 0)]);
    // The retries slept through the Iocp: the ticker ran (5 ms each) while the holder held it.
    try std.testing.expect(ticks >= 5);
}

fn closeAfter(io: std.Io, handle: win32.HANDLE, ms: i64) void {
    sleepMs(io, ms);
    _ = win32.CloseHandle(handle);
}

test "Iocp: a canceled task gets error.Canceled from a forwarded operation, which doesn't start" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const name = "winio-iocp-not-deleted.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    var task = try io.concurrent(deleteAfterProtectedSleep, .{ io, name });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.Io.Dir.cwd().access(io, name, .{});
}

/// As `openAfterProtectedSleep`, the cancelation point a forwarded deleteFile (which would delete
/// `name`).
fn deleteAfterProtectedSleep(io: std.Io, name: []const u8) !void {
    const previous = io.swapCancelProtection(.blocked);
    io.sleep(.fromMilliseconds(20), .awake) catch unreachable; // protected
    _ = io.swapCancelProtection(previous);
    try std.Io.Dir.cwd().deleteFile(io, name);
}

test "Iocp: an abandoned atomic file leaves nothing; link refuses an existing file" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const cwd = std.Io.Dir.cwd();
    const dir_name = "winio-iocp-abandoned";
    try cwd.createDirPath(io, dir_name);
    defer cwd.deleteTree(io, dir_name) catch {};
    var dir = try cwd.openDir(io, dir_name, .{ .iterate = true });
    defer dir.close(io);
    {
        var atomic = try dir.createFileAtomic(io, "never.txt", .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writePositionalAll(io, "abandoned", 0);
    }
    var it = dir.iterate();
    try std.testing.expect(try it.next(io) == null);
    for ([_]?anyerror{ null, error.PathAlreadyExists }) |expected| {
        var atomic = try dir.createFileAtomic(io, "linked.txt", .{});
        defer atomic.deinit(io);
        try atomic.file.writePositionalAll(io, "linked", 0);
        if (expected) |e| try std.testing.expectError(e, atomic.link(io)) else try atomic.link(io);
    }
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("linked", try dir.readFile(io, "linked.txt", &buf));
}

test "Iocp: every operation that gives a File opens it overlapped: atomic files, the executable" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const cwd = std.Io.Dir.cwd();
    const dir_name = "winio-iocp-atomic";
    defer cwd.deleteTree(io, dir_name) catch {};
    {
        // In a directory it makes, as owai's writeFileAtomic does.
        var atomic = try cwd.createFileAtomic(io, dir_name ++ "/sub/atomic.txt", .{ .replace = true, .make_path = true });
        defer atomic.deinit(io);
        try std.testing.expectEqual(.ok, Iocp.checkHandle(atomic.file));
        var buf: [16]u8 = undefined;
        var writer = atomic.file.writer(io, &buf);
        try writer.interface.writeAll("atomically written");
        try writer.interface.flush();
        try atomic.replace(io);
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("atomically written", try cwd.readFile(io, dir_name ++ "/sub/atomic.txt", &buf));
    const exe = try std.process.openExecutable(io, .{});
    defer exe.close(io);
    try std.testing.expectEqual(.ok, Iocp.checkHandle(exe));
    try std.testing.expectEqual(@as(usize, 2), try exe.readPositionalAll(io, buf[0..2], 0));
    try std.testing.expectEqualStrings("MZ", buf[0..2]);
}

test "Iocp: streaming a disk file from the position it keeps; seeking moves it; a pipe can't seek" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const name = "winio-iocp-stream.txt";
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    const file = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true });
    defer file.close(io);
    // Each continues where the last ended.
    try file.writeStreamingAll(io, "one,");
    try file.writeStreamingAll(io, "two,three");
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, file.readStreaming(io, &.{&buf}));
    try io.vtable.fileSeekTo(io.userdata, file, 4);
    try std.testing.expectEqualStrings("two,three", buf[0..try file.readStreaming(io, &.{&buf})]);
    try io.vtable.fileSeekBy(io.userdata, file, -5);
    try std.testing.expectEqualStrings("three", buf[0..try file.readStreaming(io, &.{&buf})]);
    // Before the start: Unseekable, and the position stays.
    try std.testing.expectError(error.Unseekable, io.vtable.fileSeekBy(io.userdata, file, -100));
    try std.testing.expectError(error.EndOfStream, file.readStreaming(io, &.{&buf}));
    try io.vtable.fileSeekTo(io.userdata, file, 0);
    try io.vtable.fileSeekBy(io.userdata, file, 4);
    try file.writeStreamingAll(io, "TWO");
    try std.testing.expectEqualStrings("one,TWO,three", buf[0..try file.readPositionalAll(io, &buf, 0)]);
    // Through std's File.Reader, which seeks with them (from where the file is when it starts).
    try io.vtable.fileSeekTo(io.userdata, file, 0);
    var read_buf: [4]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    try reader.seekTo(8);
    var out: [16]u8 = undefined;
    var out_writer: std.Io.Writer = .fixed(&out);
    try std.testing.expectEqualStrings("three", out[0..try reader.interface.streamRemaining(&out_writer)]);

    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-seek"));
    defer read_end.close(io);
    defer write_end.close(io);
    try std.testing.expectError(error.Unseekable, io.vtable.fileSeekTo(io.userdata, read_end, 0));
    try std.testing.expectError(error.Unseekable, io.vtable.fileSeekBy(io.userdata, write_end, 1));
}

test "Iocp: copying a file falls back to reads and writes (its own copy is error.Unimplemented)" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const name = "winio-iocp-copy.txt";
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    const file = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "copied through the fallback", 0);
    var reader = file.readerStreaming(io, &.{});
    try std.testing.expectError(error.Unimplemented, io.vtable.fileWriteFileStreaming(io.userdata, file, "", &reader, .unlimited));
    try std.testing.expectError(error.Unimplemented, io.vtable.fileWriteFilePositional(io.userdata, file, "", &reader, .unlimited, 0));
    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-copy"));
    defer read_end.close(io);
    var copier = try io.concurrent(copyAndClose, .{ io, file, write_end });
    var buf: [64]u8 = undefined;
    var pipe_reader = read_end.readerStreaming(io, &buf);
    var out: [64]u8 = undefined;
    var out_writer: std.Io.Writer = .fixed(&out);
    try std.testing.expectEqualStrings("copied through the fallback", out[0..try pipe_reader.interface.streamRemaining(&out_writer)]);
    try copier.await(io);
}

fn copyAndClose(io: std.Io, from: std.Io.File, to: std.Io.File) !void {
    defer to.close(io);
    var read_buf: [8]u8 = undefined;
    var reader = from.readerStreaming(io, &read_buf);
    var write_buf: [8]u8 = undefined;
    var writer = to.writerStreaming(io, &write_buf);
    _ = try writer.interface.sendFileAll(&reader, .unlimited);
    try writer.interface.flush();
}

test "Iocp: checkHandle tells overlapped handles from synchronous ones" {
    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-check"));
    defer windows.CloseHandle(read_end.handle);
    defer windows.CloseHandle(write_end.handle);
    try std.testing.expectEqual(.ok, Iocp.checkHandle(read_end));
    try std.testing.expectEqual(.nonblocking_flag_wrong, Iocp.checkHandle(.{ .handle = write_end.handle, .flags = .{ .nonblocking = false } }));
    var r: ?win32.HANDLE = undefined;
    var w: ?win32.HANDLE = undefined;
    if (0 == win32.CreatePipe(&r, &w, null, 0)) win32.panicWin32("CreatePipe", win32.GetLastError());
    defer windows.CloseHandle(r.?);
    defer windows.CloseHandle(w.?);
    // Synchronous whatever its flag says.
    try std.testing.expectEqual(.synchronous, Iocp.checkHandle(.{ .handle = r.?, .flags = .{ .nonblocking = true } }));
    const name = "winio-iocp-check.txt";
    defer std.Io.Dir.cwd().deleteFile(blocking, name) catch {};
    {
        // std.Io.Threaded opens disk files synchronously.
        const file = try std.Io.Dir.cwd().createFile(blocking, name, .{});
        defer file.close(blocking);
        try std.testing.expectEqual(.synchronous, Iocp.checkHandle(file));
    }
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const file = try std.Io.Dir.cwd().openFile(io, name, .{});
    defer file.close(io);
    try std.testing.expectEqual(.ok, Iocp.checkHandle(file));
}

test "Iocp: tasks stream from pipes; a pending read doesn't hold up another" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const a_read, const a_write = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-a"));
    const b_read, const b_write = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-b"));
    defer a_read.close(io);
    defer b_read.close(io);
    var order: [2]u8 = undefined;
    var finished: usize = 0;
    var a_out: [64]u8 = undefined;
    var b_out: [64]u8 = undefined;
    var a = try io.concurrent(readAll, .{ io, a_read, &a_out, 'a', &order, &finished });
    var b = try io.concurrent(readAll, .{ io, b_read, &b_out, 'b', &order, &finished });
    // Pipe b is written and closed first; a's reader is parked on its read meanwhile.
    var writer = try io.concurrent(writeBThenA, .{ io, a_write, b_write });
    try writer.await(io);
    try std.testing.expectEqualStrings("one, two", a_out[0..try a.await(io)]);
    try std.testing.expectEqualStrings("bee", b_out[0..try b.await(io)]);
    try std.testing.expectEqualStrings("ba", &order);
}

/// Reads `file` to its end into `out`, then records `name` in `order`.
fn readAll(io: std.Io, file: std.Io.File, out: []u8, name: u8, order: *[2]u8, finished: *usize) !usize {
    var read_buf: [16]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var writer: std.Io.Writer = .fixed(out);
    const n = try reader.interface.streamRemaining(&writer);
    order[finished.*] = name;
    finished.* += 1;
    return n;
}

fn writeBThenA(io: std.Io, a: std.Io.File, b: std.Io.File) !void {
    try writeAndClose(io, b, &.{"bee"});
    sleepMs(io, 20);
    try writeAndClose(io, a, &.{ "one, ", "two" });
}

fn writeAndClose(io: std.Io, file: std.Io.File, parts: []const []const u8) !void {
    defer file.close(io);
    var buf: [16]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    for (parts) |part| {
        try writer.interface.writeAll(part);
        try writer.interface.flush();
        sleepMs(io, 5);
    }
}

/// A pipe's read and write ends, both overlapped.
fn overlappedPipe(name: [*:0]const u16) [2]std.Io.File {
    const read_end = win32.CreateNamedPipeW(name, .{ .FILE_ATTRIBUTE_READONLY = 1, .FILE_FLAG_OVERLAPPED = 1 }, .{}, 1, 0, 4096, 0, null);
    if (read_end == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateNamedPipeW", win32.GetLastError());
    const write_end = win32.CreateFileW(name, .{ .FILE_WRITE_DATA = 1, .FILE_WRITE_ATTRIBUTES = 1, .SYNCHRONIZE = 1 }, .{}, null, .OPEN_EXISTING, .{ .FILE_FLAG_OVERLAPPED = 1 }, null);
    if (write_end == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFileW", win32.GetLastError());
    return .{
        .{ .handle = read_end, .flags = .{ .nonblocking = true } },
        .{ .handle = write_end, .flags = .{ .nonblocking = true } },
    };
}

test "Iocp: now, and crashHandler does nothing" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const a = std.Io.Timestamp.now(io, .awake).nanoseconds;
    sleepMs(io, 5);
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).nanoseconds - a >= 5 * std.time.ns_per_ms);
    io.vtable.crashHandler(io.userdata);
}

// ---------------------------------------------------------------------------------------------
// Iocp: children (`child.zig` is the program they run), and batches.

const RunResult = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

/// std.process.run's steps (it has no timeout): spawn, read stdout and stderr together, wait. The
/// caller frees `stdout` and `stderr` (std.testing.allocator).
fn run(io: std.Io, argv: []const []const u8, timeout: std.Io.Timeout) !RunResult {
    const gpa = std.testing.allocator;
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    while (multi.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    return .{ .term = term, .stdout = stdout, .stderr = try multi.toOwnedSlice(1) };
}

/// Checks the Iocp holds nothing more than at `init`: no pending I/O, no handles bound, and the
/// process holds `handles` handles.
fn expectNothingLeft(iocp: *const Iocp, handles: u32) !void {
    try std.testing.expectEqual(@as(usize, 0), iocp.pending);
    try std.testing.expectEqual(@as(u32, 0), iocp.bound.count());
    try std.testing.expectEqual(handles, handleCount());
}

/// The process's handle count, after a first spawn with pipes and an ignored stdin, in case those
/// create handles once.
fn warmHandleCount(io: std.Io) !u32 {
    const result = try run(io, &.{ test_options.child, "exit", "0" }, .none);
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return handleCount();
}

fn handleCount() u32 {
    var n: u32 = undefined;
    if (0 == win32.GetProcessHandleCount(win32.GetCurrentProcess(), &n)) win32.panicWin32("GetProcessHandleCount", win32.GetLastError());
    return n;
}

test "Iocp: a child's stdout and stderr read together; nothing is left after" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const gpa = std.testing.allocator;
    const handles = try warmHandleCount(io);
    // Far more than a pipe holds: a child writing both would block unless both are read at once.
    for (0..3) |_| {
        const result = try run(io, &.{ test_options.child, "big", "100000" }, .none);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        for ([_][]const u8{ result.stdout, result.stderr }) |out| {
            try std.testing.expectEqual(@as(usize, 100000), out.len);
            for (out, 0..) |c, i| if (c != 'a' + (i % 1000) % 26) return error.TestUnexpectedResult;
        }
    }
    try expectNothingLeft(&iocp, handles);
}

test "Iocp: a child's stdin, arguments and exit code" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const gpa = std.testing.allocator;
    const handles = try warmHandleCount(io);
    {
        var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "echo" }, .stdin = .pipe, .stdout = .pipe });
        defer if (child.id != null) child.kill(io);
        // Its stdin is overlapped on this end: written through the Iocp.
        var buf: [8]u8 = undefined;
        var writer = child.stdin.?.writerStreaming(io, &buf);
        try writer.interface.writeAll("through stdin and back");
        try writer.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
        var read_buf: [8]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &read_buf);
        var out: [64]u8 = undefined;
        var out_writer: std.Io.Writer = .fixed(&out);
        try std.testing.expectEqualStrings("through stdin and back", out[0..try reader.interface.streamRemaining(&out_writer)]);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }
    {
        var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "exit", "7" } });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try child.wait(io));
    }
    {
        // Each comes back as given: CommandLineToArgvW's quoting.
        const args = [_][]const u8{ "a b", "", "q\"uote", "back\\\\", "\\\"", "trailing\\", "\u{E9}\u{20AC}", "tab\there" };
        const result = try run(io, &([_][]const u8{ test_options.child, "args" } ++ args), .none);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        var it = std.mem.splitScalar(u8, result.stdout, 0);
        for (args) |arg| try std.testing.expectEqualStrings(arg, it.next().?);
        try std.testing.expectEqualStrings("", it.next().?);
        try std.testing.expect(it.next() == null);
    }
    try expectNothingLeft(&iocp, handles);
}

test "Iocp: a child's cwd, environment, and stderr to a file" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const gpa = std.testing.allocator;
    // Absolute: a relative executable is looked for in the child's cwd (as std, and POSIX).
    var child_buf: [1024]u8 = undefined;
    const child_exe = child_buf[0..try std.Io.Dir.cwd().realPathFile(io, test_options.child, &child_buf)];
    try std.testing.expectError(error.FileNotFound, std.process.spawn(io, .{ .argv = &.{ test_options.child, "cwd" }, .cwd = .{ .path = "src" } }));
    {
        const result = try std.process.run(gpa, io, .{ .argv = &.{ child_exe, "cwd" }, .cwd = .{ .path = "src" } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(std.mem.endsWith(u8, result.stdout, "\\src"));
    }
    {
        var src = try std.Io.Dir.cwd().openDir(io, "src", .{});
        defer src.close(io);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ child_exe, "cwd" }, .cwd = .{ .dir = src } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(std.mem.endsWith(u8, result.stdout, "\\src"));
    }
    {
        var map: std.process.Environ.Map = .init(gpa);
        defer map.deinit();
        try map.put("WINIO_TEST", "from the map");
        const result = try std.process.run(gpa, io, .{ .argv = &.{ test_options.child, "env", "WINIO_TEST" }, .environ_map = &map });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqualStrings("from the map", result.stdout);
    }
    {
        // Without a map, this process's environment, minus ZIG_PROGRESS (as std).
        setEnv("WINIO_TEST_PARENT", "inherited");
        setEnv("ZIG_PROGRESS", "12345");
        defer setEnv("WINIO_TEST_PARENT", null);
        defer setEnv("ZIG_PROGRESS", null);
        for ([_][2][]const u8{ .{ "WINIO_TEST_PARENT", "inherited" }, .{ "ZIG_PROGRESS", "<unset>" } }) |case| {
            const result = try std.process.run(gpa, io, .{ .argv = &.{ test_options.child, "env", case[0] } });
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            try std.testing.expectEqualStrings(case[1], result.stdout);
        }
    }
    {
        // stderr to a file of ours (overlapped: reopened synchronous for the child), stdin
        // ignored, stdout closed.
        const name = "winio-test-child-stderr.txt";
        const file = try std.Io.Dir.cwd().createFile(io, name, .{});
        defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
        {
            defer file.close(io);
            var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "stderr", "to the file" }, .stdin = .ignore, .stdout = .close, .stderr = .{ .file = file } });
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
        }
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("to the file", try std.Io.Dir.cwd().readFile(io, name, &buf));
    }
    {
        // A pipe can't be reopened for the child (as std.Io.Threaded).
        var piped = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "100" }, .stdout = .pipe });
        defer piped.kill(io);
        try std.testing.expectError(error.NoDevice, std.process.spawn(io, .{ .argv = &.{ test_options.child, "stderr", "x" }, .stderr = .{ .file = piped.stdout.? } }));
    }
}

test "Iocp: children writing one .file at once: append adds to its end, from_start overwrites" {
    for ([_]Iocp.SpawnFileWrites{ .append, .from_start }) |mode| {
        var iocp: Iocp = undefined;
        iocp.init(std.testing.allocator, .{ .spawn_file_writes = mode });
        defer iocp.deinit();
        const io = iocp.io();
        const name = "winio-test-shared.txt";
        defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
        const file = try std.Io.Dir.cwd().createFile(io, name, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "earlier\n", 0);
        // Both write at once: "big" writes in 1000-byte pieces.
        var children: [2]std.process.Child = undefined;
        for (&children) |*child| child.* = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "big", "50000" }, .stdout = .{ .file = file }, .stderr = .ignore });
        for (&children) |*child| try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
        try std.testing.expectEqual(@as(u64, switch (mode) {
            .append => "earlier\n".len + 2 * 50000,
            .from_start => 50000,
        }), try file.length(io));
    }
}

fn setEnv(comptime name: []const u8, comptime value: ?[]const u8) void {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    if (0 == win32.SetEnvironmentVariableW(w(name), if (value) |v| w(v) else null)) win32.panicWin32("SetEnvironmentVariableW", win32.GetLastError());
}

test "Iocp: PATH and PATHEXT find a program; a .bat script's arguments aren't expanded" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const gpa = std.testing.allocator;
    {
        // `cmd`: on PATH, as cmd.exe.
        var child = try std.process.spawn(io, .{ .argv = &.{ "cmd", "/c", "exit 3" }, .stdout = .ignore });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try child.wait(io));
    }
    {
        const name = "winio-test-script.bat";
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = "@echo off\r\necho [%1]\r\n" });
        defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
        // In the cwd, found without its extension. Unescaped, %PATH% would expand and & would
        // end the command.
        const result = try std.process.run(gpa, io, .{ .argv = &.{ "winio-test-script", "a&b %PATH%" } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqualStrings("[\"a&b %PATH%\"]\r\n", result.stdout);
    }
    try std.testing.expectError(error.FileNotFound, std.process.spawn(io, .{ .argv = &.{"winio-no-such-program"} }));
    {
        // A relative path with forward slashes, and with ./ in front: both name the child.
        var buf: [1024]u8 = undefined;
        const forward = buf[0..test_options.child.len];
        @memcpy(forward, test_options.child);
        std.mem.replaceScalar(u8, forward, '\\', '/');
        try std.testing.expect(!std.Io.Dir.path.isAbsolute(forward));
        var dot_buf: [1026]u8 = undefined;
        const dotted = try std.fmt.bufPrint(&dot_buf, "./{s}", .{forward});
        for ([_][]const u8{ forward, dotted }) |exe| {
            var child = try std.process.spawn(io, .{ .argv = &.{ exe, "exit", "4" } });
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 4 }, try child.wait(io));
        }
    }
}

test "Iocp: a large stdin write and the stdout read run together (neither blocks the thread)" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "echo" }, .stdin = .pipe, .stdout = .pipe });
    defer if (child.id != null) child.kill(io);
    // Far more than a pipe holds: the child stops reading stdin while its stdout is full, so a
    // write blocking the thread would deadlock it.
    const total = 1 << 20;
    var writer = try io.concurrent(writeCounting, .{ io, child.stdin.?, total });
    child.stdin = null; // closed by writeCounting
    var buf: [64 * 1024]u8 = undefined;
    var got: usize = 0;
    while (child.stdout.?.readStreaming(io, &.{&buf})) |n| {
        for (buf[0..n], got..) |c, i| if (c != @as(u8, @truncate(i))) return error.TestUnexpectedResult;
        got += n;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try writer.await(io);
    try std.testing.expectEqual(@as(usize, total), got);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

fn writeCounting(io: std.Io, file: std.Io.File, total: usize) !void {
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var sent: usize = 0;
    while (sent < total) {
        const n = @min(total - sent, buf.len);
        for (buf[0..n], sent..) |*c, i| c.* = @truncate(i);
        try file.writeStreamingAll(io, buf[0..n]);
        sent += n;
    }
}

test "Iocp: killing a child, running or exited" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const handles = try warmHandleCount(io);
    {
        var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "10000" }, .stdout = .pipe });
        const start = std.Io.Timestamp.now(io, .awake);
        child.kill(io);
        try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 2000);
        try std.testing.expect(child.id == null and child.stdout == null);
    }
    {
        var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "exit", "0" } });
        sleepMs(io, 200);
        child.kill(io);
        try std.testing.expect(child.id == null);
    }
    try expectNothingLeft(&iocp, handles);
}

test "Iocp: other tasks run while a child is waited for" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var stop = false;
    var ticks: usize = 0;
    var ticker = try io.concurrent(tick, .{ io, &stop, &ticks });
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "200" } });
    _ = try child.wait(io);
    stop = true;
    ticker.await(io);
    // 5 ms each over 200 ms; far fewer if the wait held up the thread.
    try std.testing.expect(ticks >= 10);
}

fn tick(io: std.Io, stop: *const bool, ticks: *usize) void {
    while (!stop.*) {
        sleepMs(io, 5);
        ticks.* += 1;
    }
}

test "Iocp: reading a child's output times out; its pending reads are canceled" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const handles = try warmHandleCount(io);
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, run(io, &.{ test_options.child, "sleep", "10000" }, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }));
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 2000);
    try expectNothingLeft(&iocp, handles);
}

test "Iocp: a batch awaited with awaitAsync; a read that fails as it starts" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "big", "20000" }, .stdout = .pipe, .stderr = .pipe });
    defer if (child.id != null) child.kill(io);
    var storage: [2]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    var bufs: [2][512]u8 = undefined;
    var totals: [2]usize = .{ 0, 0 };
    const pipes = [2]std.Io.File{ child.stdout.?, child.stderr.? };
    var open: usize = 2;
    for (0..2) |i| batch.addAt(@intCast(i), .{ .file_read_streaming = .{ .file = pipes[i], .data = &.{&bufs[i]} } });
    while (open > 0) {
        try batch.awaitAsync(io);
        while (batch.next()) |completion| {
            const i = completion.index;
            if (completion.result.file_read_streaming) |n| {
                totals[i] += n;
                batch.addAt(i, .{ .file_read_streaming = .{ .file = pipes[i], .data = &.{&bufs[i]} } });
            } else |err| {
                try std.testing.expectEqual(error.EndOfStream, err);
                open -= 1;
            }
        }
    }
    try std.testing.expectEqual([2]usize{ 20000, 20000 }, totals);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));

    {
        // A read that fails as it starts (the writer is gone): no packet comes, so it completes
        // at once.
        const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-batch"));
        defer read_end.close(io);
        write_end.close(io);
        batch.addAt(0, .{ .file_read_streaming = .{ .file = read_end, .data = &.{&bufs[0]} } });
        try batch.awaitConcurrent(io, .none);
        try std.testing.expectError(error.EndOfStream, batch.next().?.result.file_read_streaming);
        try std.testing.expect(batch.next() == null);
    }
}

// ---------------------------------------------------------------------------------------------
// Cancelation.

test "Iocp: cancel wakes a parked sleep or futex wait; only the next point is canceled; recancel re-arms" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    {
        var task = try io.concurrent(cancelPoints, .{io});
        // Parked in its 10 s sleep by now.
        sleepMs(io, 20);
        const start = std.Io.Timestamp.now(io, .awake);
        try task.cancel(io);
        try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 1000);
    }
    {
        const word: u32 = 0;
        var task = try io.concurrent(futexCanceled, .{ io, &word });
        sleepMs(io, 20);
        try task.cancel(io);
    }
}

fn cancelPoints(io: std.Io) !void {
    try std.testing.expectError(error.Canceled, io.sleep(.fromSeconds(10), .awake));
    // That was the request: this sleep runs out.
    try io.sleep(.fromMilliseconds(5), .awake);
    try io.checkCancel();
    io.recancel();
    try std.testing.expectError(error.Canceled, io.checkCancel());
    try io.checkCancel();
}

fn futexCanceled(io: std.Io, word: *const u32) !void {
    try std.testing.expectError(error.Canceled, io.futexWait(u32, word, 0));
}

test "Iocp: protection holds a cancelation back; then any Io call that can be canceled is a cancelation point" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    var task = try io.concurrent(protectedSleep, .{io});
    sleepMs(io, 10);
    const start = std.Io.Timestamp.now(io, .awake);
    try task.cancel(io);
    // It waited for the protected sleep.
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() >= 30);
}

fn protectedSleep(io: std.Io) !void {
    const old = io.swapCancelProtection(.blocked);
    try std.testing.expectEqual(std.Io.CancelProtection.unblocked, old);
    // Canceled during this sleep, which still runs out.
    try io.sleep(.fromMilliseconds(50), .awake);
    try io.checkCancel();
    try std.testing.expectEqual(std.Io.CancelProtection.blocked, io.swapCancelProtection(old));
    // Any call that can return error.Canceled is a cancelation point (`tasks.cancelationPoint`):
    // this seek would fail Unseekable if it ran.
    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-protect"));
    defer read_end.close(io);
    defer write_end.close(io);
    try std.testing.expectError(error.Canceled, io.vtable.fileSeekTo(io.userdata, read_end, 0));
    try std.testing.expectError(error.Unseekable, io.vtable.fileSeekTo(io.userdata, read_end, 0));
}

test "Iocp: canceling a pipe read, a child's wait, and reading a child's output" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    const handles = try warmHandleCount(io);
    const start = std.Io.Timestamp.now(io, .awake);
    {
        // Nothing is ever written: only the cancelation ends the read.
        const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-cancel"));
        defer write_end.close(io);
        defer read_end.close(io);
        var task = try io.concurrent(readOnce, .{ io, read_end });
        sleepMs(io, 20);
        try std.testing.expectError(error.Canceled, task.cancel(io));
        try std.testing.expectEqual(@as(usize, 0), iocp.pending);
    }
    {
        var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "10000" } });
        var task = try io.concurrent(waitChild, .{ io, &child });
        sleepMs(io, 20);
        try std.testing.expectError(error.Canceled, task.cancel(io));
        // Still there: the wait was canceled, not the child.
        try std.testing.expect(child.id != null);
        child.kill(io);
    }
    {
        var task = try io.concurrent(runSleeper, .{io});
        sleepMs(io, 50);
        try std.testing.expectError(error.Canceled, task.cancel(io));
    }
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 3000);
    try expectNothingLeft(&iocp, handles);
}

fn readOnce(io: std.Io, file: std.Io.File) !usize {
    var buf: [16]u8 = undefined;
    return file.readStreaming(io, &.{&buf});
}

fn waitChild(io: std.Io, child: *std.process.Child) !std.process.Child.Term {
    return child.wait(io);
}

fn runSleeper(io: std.Io) !void {
    const result = try run(io, &.{ test_options.child, "sleep", "10000" }, .none);
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "Iocp: the root fiber has a protection, and nothing cancels it" {
    var iocp: Iocp = undefined;
    iocp.init(std.testing.allocator, .{});
    defer iocp.deinit();
    const io = iocp.io();
    try io.checkCancel();
    try std.testing.expectEqual(std.Io.CancelProtection.unblocked, io.swapCancelProtection(.blocked));
    try std.testing.expectEqual(std.Io.CancelProtection.blocked, io.swapCancelProtection(.unblocked));
}

// ---------------------------------------------------------------------------------------------
// Two threads: Fibers with a message loop on the test's thread, an Iocp on an io thread (as owai would).

/// An io thread running an Iocp until `stop`: its root fiber waits on `shutdown`, running the
/// tasks meanwhile.
const IoThread = struct {
    options: Iocp.InitOptions = .{},
    iocp_io: std.Io = undefined,
    thread_id: u32 = undefined,
    started: std.Io.Event = .unset,
    shutdown: std.Io.Event = .unset,
    /// Set once the Iocp's deinit has returned.
    deinited: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn main(t: *IoThread) void {
        {
            var iocp: Iocp = undefined;
            iocp.init(std.testing.allocator, t.options);
            defer iocp.deinit();
            t.thread_id = win32.GetCurrentThreadId();
            t.iocp_io = iocp.io();
            t.started.set(t.iocp_io);
            t.shutdown.waitUncancelable(t.iocp_io);
        }
        t.deinited.store(true, .release);
    }

    /// Starts it; `io` (the caller's) waits until it's up.
    fn start(t: *IoThread, io: std.Io) !void {
        t.thread = try std.Thread.spawn(.{}, main, .{t});
        t.started.waitUncancelable(io);
    }

    fn stop(t: *IoThread, io: std.Io) void {
        t.shutdown.set(io);
        t.thread.join();
    }
};

fn currentThreadId() u32 {
    return win32.GetCurrentThreadId();
}

test "two threads: io-thread tasks run there; awaited from the root fiber and from a Fibers task" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    // The root fiber (outside the message loop) waits, running the tasks; the io thread's wake sets the `wake` Event.
    var job = try t.iocp_io.concurrent(currentThreadId, .{});
    try std.testing.expectEqual(t.thread_id, job.await(io));
    // A Fibers task parks in the message loop; the io thread's wake sets the `wake` Event too.
    var task = try io.concurrent(awaitIoThreadId, .{ io, &t });
    _ = fibers.runMessageLoop();
    try task.await(io);
}

fn awaitIoThreadId(io: std.Io, t: *IoThread) !void {
    defer win32.PostQuitMessage(0);
    var job = try t.iocp_io.concurrent(sleepThenThreadId, .{ t.iocp_io, 20 });
    try std.testing.expectEqual(t.thread_id, job.await(io));
    try std.testing.expect(t.thread_id != win32.GetCurrentThreadId());
}

fn sleepThenThreadId(io: std.Io, ms: i64) u32 {
    sleepMs(io, ms);
    return win32.GetCurrentThreadId();
}

test "two threads: another thread makes forwarded calls, opens and spawns; the port's I/O is the io thread's" {
    var t: IoThread = .{};
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    try t.start(plain);
    defer t.stop(plain);
    const io = t.iocp_io;
    // Forwarded, from this thread, while the io thread runs.
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, "build.zig", .{})).size > 0);
    var bytes: [16]u8 = @splat(0);
    io.random(&bytes);
    try std.testing.expect(!std.mem.allEqual(u8, &bytes, 0));
    // Spawned here; its wait, on the port, is the io thread's.
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "exit", "5" } });
    var waiter = try io.concurrent(waitChild, .{ io, &child });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 5 }, try waiter.await(plain));
}

test "two threads: a Mutex both take, from tasks and from the root fiber" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    var shared: Counted = .{};
    var a = try t.iocp_io.concurrent(countUnderLock, .{ t.iocp_io, &shared });
    var b = try t.iocp_io.concurrent(countUnderLock, .{ t.iocp_io, &shared });
    // The root fiber takes it too (outside the message loop), waiting while an io-thread task holds it.
    try countUnderLock(io, &shared);
    try a.await(io);
    try b.await(io);
    try std.testing.expectEqual(@as(u32, 3 * Counted.rounds), shared.count);
}

/// A count only ever changed under `mutex`, each change held across a sleep now and then, so the
/// other threads queue on it.
const Counted = struct {
    mutex: std.Io.Mutex = .init,
    count: u32 = 0,
    const rounds = 300;
};

fn countUnderLock(io: std.Io, c: *Counted) !void {
    for (0..Counted.rounds) |i| {
        try c.mutex.lock(io);
        defer c.mutex.unlock(io);
        const before = c.count;
        if (i % 30 == 0) sleepMs(io, 1);
        c.count = before + 1;
    }
}

test "two threads: a Queue from io-thread tasks to a Fibers task" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    var buf: [4]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&buf);
    var producer = try t.iocp_io.concurrent(produce, .{ t.iocp_io, &queue });
    var consumer = try io.concurrent(consume, .{ io, &queue });
    _ = fibers.runMessageLoop();
    try producer.await(io);
    try std.testing.expectEqual(@as(u64, 100 * 101 / 2), try consumer.await(io));
}

fn produce(io: std.Io, queue: *std.Io.Queue(u32)) !void {
    for (1..101) |i| {
        try queue.putOne(io, @intCast(i));
        if (i % 10 == 0) sleepMs(io, 1);
    }
}

fn consume(io: std.Io, queue: *std.Io.Queue(u32)) !u64 {
    defer win32.PostQuitMessage(0);
    var sum: u64 = 0;
    for (0..100) |_| sum += try queue.getOne(io);
    return sum;
}

test "two threads: a Fibers task cancels io-thread tasks parked in a sleep and a pipe read" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    var task = try io.concurrent(cancelOnIoThread, .{ io, &t });
    _ = fibers.runMessageLoop();
    try task.await(io);
}

fn cancelOnIoThread(io: std.Io, t: *IoThread) !void {
    defer win32.PostQuitMessage(0);
    const start = std.Io.Timestamp.now(io, .awake);
    var sleeper = try t.iocp_io.concurrent(sleepThenDouble, .{ t.iocp_io, 4 });
    sleepMs(io, 20);
    try std.testing.expectError(error.Canceled, sleeper.cancel(io));
    // The pipe's ends: made and used on the io thread (its I/O is its own).
    var reader = try t.iocp_io.concurrent(readUnwrittenPipe, .{t.iocp_io});
    sleepMs(io, 20);
    try std.testing.expectError(error.Canceled, reader.cancel(io));
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 2000);
}

fn readUnwrittenPipe(io: std.Io) !usize {
    const read_end, const write_end = overlappedPipe(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\winio-test-cross-cancel"));
    defer write_end.close(io);
    defer read_end.close(io);
    return readOnce(io, read_end);
}

test "two threads: futex ping-pong, many rounds (a wake between a waiter's check and its enqueue mustn't be lost)" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    // Odd: the io thread's turn; even: this thread's. Each waits without a timeout, so a lost
    // wake hangs (the build's time limit catches it).
    var turn: u32 = 0;
    var other = try t.iocp_io.concurrent(pingPong, .{ t.iocp_io, &turn, 1 });
    pingPong(io, &turn, 0);
    other.await(io);
}

const ping_pong_rounds = 20_000;

fn pingPong(io: std.Io, turn: *u32, parity: u32) void {
    while (true) {
        const now = @atomicLoad(u32, turn, .acquire);
        if (now >= 2 * ping_pong_rounds) return;
        if (now % 2 != parity) {
            io.futexWaitUncancelable(u32, turn, now);
            continue;
        }
        @atomicStore(u32, turn, now + 1, .release);
        io.futexWake(u32, turn, 1);
    }
}

test "two threads: randomized tasks, locks, sleeps, cross-thread children awaited or canceled" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    const seed = stressSeed();
    errdefer std.debug.print("stress seed: {} (set WINIO_STRESS_SEED to repeat it)\n", .{seed});
    var shared: Stress = .{ .fibers_io = io, .iocp_io = t.iocp_io };
    var coordinator = try io.concurrent(stressAll, .{ &shared, seed });
    _ = fibers.runMessageLoop();
    try coordinator.await(io);
    try std.testing.expectEqual(@atomicLoad(u32, &shared.increments, .acquire), shared.counter);
    try std.testing.expect(shared.counter > 0);
}

test "four threads: randomized RwLock, Semaphore, Condition, and canceled lock waits" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var threads: [3]IoThread = @splat(.{});
    for (&threads) |*t| try t.start(io);
    defer for (&threads) |*t| t.stop(io);
    const seed = stressSeed();
    errdefer std.debug.print("stress seed: {} (set WINIO_STRESS_SEED to repeat it)\n", .{seed});
    var s: Sync = .{ .ios = .{ io, threads[0].iocp_io, threads[1].iocp_io, threads[2].iocp_io } };
    var coordinator = try io.concurrent(syncAll, .{ &s, seed });
    _ = fibers.runMessageLoop();
    try coordinator.await(io);
    try std.testing.expectEqual(@as(u32, 0), s.violations.load(.acquire));
    for (s.cells) |c| try std.testing.expectEqual(s.cells[0], c);
    try std.testing.expectEqual(@as(u32, 0), s.tokens);
    try std.testing.expect(s.cells[0] > 0);
}

const Sync = struct {
    /// The Fibers', then the io threads'.
    ios: [4]std.Io,
    rw: std.Io.RwLock = .init,
    /// Written together under `rw`; readers check they're equal.
    cells: [8]u32 = @splat(0),
    semaphore: std.Io.Semaphore = .{ .permits = 2 },
    /// Holders of `semaphore` (atomic): never more than 2.
    inside: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    /// Put then taken under `mutex`; every worker puts before it takes, so it never waits forever.
    tokens: u32 = 0,
    /// For canceled lock waits.
    held: std.Io.Mutex = .init,
    violations: std.atomic.Value(u32) = .init(0),
    const workers_per_thread = 3;
    const steps = 120;
};

fn syncAll(s: *Sync, seed: u64) !void {
    defer win32.PostQuitMessage(0);
    var workers: [4 * Sync.workers_per_thread]std.Io.Future(anyerror!void) = undefined;
    for (&workers, 0..) |*w, n| {
        const io = s.ios[n % 4];
        w.* = try io.concurrent(syncWorker, .{ s, io, seed +% n });
    }
    for (&workers) |*w| try w.await(s.ios[0]);
}

fn syncWorker(s: *Sync, io: std.Io, seed: u64) anyerror!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    for (0..Sync.steps) |_| switch (r.uintLessThan(u8, 5)) {
        0 => {
            try s.rw.lock(io);
            defer s.rw.unlock(io);
            for (&s.cells, 0..) |*c, i| {
                c.* += 1;
                if (i == 3 and r.uintLessThan(u8, 4) == 0) try io.sleep(.fromMicroseconds(300), .awake);
            }
        },
        1 => {
            try s.rw.lockShared(io);
            defer s.rw.unlockShared(io);
            for (s.cells) |c| if (c != s.cells[0]) {
                _ = s.violations.fetchAdd(1, .acq_rel);
            };
        },
        2 => {
            try s.semaphore.wait(io);
            defer s.semaphore.post(io);
            if (s.inside.fetchAdd(1, .acq_rel) >= 2) _ = s.violations.fetchAdd(1, .acq_rel);
            defer _ = s.inside.fetchSub(1, .acq_rel);
            try io.sleep(.fromMicroseconds(r.uintLessThan(u32, 500)), .awake);
        },
        3 => {
            {
                try s.mutex.lock(io);
                defer s.mutex.unlock(io);
                s.tokens += 1;
                s.condition.signal(io);
            }
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            while (s.tokens == 0) try s.condition.wait(io, &s.mutex);
            s.tokens -= 1;
        },
        4 => {
            // Hold `held`; a child on an io thread blocks taking it; cancel the child.
            try s.held.lock(io);
            defer s.held.unlock(io);
            const child_io = s.ios[1 + r.uintLessThan(usize, 3)];
            var child = try child_io.concurrent(lockHeld, .{ s, child_io });
            try io.sleep(.fromMicroseconds(r.uintLessThan(u32, 1000)), .awake);
            if (child.cancel(io)) |_| {
                _ = s.violations.fetchAdd(1, .acq_rel);
            } else |_| {}
        },
        else => unreachable,
    };
}

fn lockHeld(s: *Sync, io: std.Io) error{Canceled}!void {
    try s.held.lock(io);
    s.held.unlock(io);
}

test "two threads: a Mutex waiter canceled as the Mutex is unlocked doesn't strand the others" {
    // This thread and the waiters below have no winio Io: they block on their own wake words,
    // so nothing but a wake ends their waits (a task's loop would also notice the word change).
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    var t: IoThread = .{};
    try t.start(plain);
    defer t.stop(plain);
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(plain);
    // The victim (an io-thread task) queues first, so the unlock's one wake goes to it.
    var victim = try t.iocp_io.concurrent(lockHeld2, .{ t.iocp_io, &mutex });
    win32.Sleep(20);
    var done = std.atomic.Value(u32).init(0);
    var others: [3]std.Thread = undefined;
    for (&others) |*o| o.* = try std.Thread.spawn(.{}, lockUnlockCount, .{ plain, &mutex, &done });
    win32.Sleep(20);
    // The io thread stops where it has chosen to resume the victim for its cancelation but the
    // victim is still queued; the unlock lands there, its one wake going to the victim.
    cancel_window = .{};
    tasks.test_hooks.cancel_window = &stopInCancelWindow;
    defer tasks.test_hooks.cancel_window = null;
    const canceler = try std.Thread.spawn(.{}, cancelFromPlainThread, .{&victim});
    while (!cancel_window.inside.load(.acquire)) std.atomic.spinLoopHint();
    mutex.unlock(plain);
    cancel_window.unlocked.store(true, .release);
    canceler.join();
    // The others each get the mutex in turn; a wake the victim kept leaves them waiting.
    const start = win32.GetTickCount64();
    while (done.load(.acquire) < others.len and win32.GetTickCount64() - start < 2000) win32.Sleep(1);
    const stranded = done.load(.acquire) < others.len;
    // Wake them all, so the test can end.
    if (stranded) plain.futexWake(std.Io.Mutex.State, &mutex.state.raw, std.math.maxInt(u32));
    for (others) |o| o.join();
    try std.testing.expect(!stranded);
}

test "races: a word changed and woken just before its waiter queues still ends the wait" {
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    enqueue_race = .{};
    tasks.test_hooks.enqueue_window = &stopBeforeEnqueue;
    defer tasks.test_hooks.enqueue_window = null;
    const waiter = try std.Thread.spawn(.{}, waitOnRaceWord, .{plain});
    // The waiter checked the word (0) and is about to queue: change it and wake now.
    while (!enqueue_race.inside.load(.acquire)) std.atomic.spinLoopHint();
    @atomicStore(u32, &enqueue_race.word, 1, .release);
    plain.futexWake(u32, &enqueue_race.word, 1);
    enqueue_race.released.store(true, .release);
    const start = win32.GetTickCount64();
    while (!enqueue_race.done.load(.acquire) and win32.GetTickCount64() - start < 2000) win32.Sleep(1);
    const stranded = !enqueue_race.done.load(.acquire);
    // Wake it, so the test can end.
    if (stranded) plain.futexWake(u32, &enqueue_race.word, 1);
    waiter.join();
    try std.testing.expect(!stranded);
}

var enqueue_race: struct {
    word: u32 = 0,
    inside: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
} = .{};

fn stopBeforeEnqueue(word: *const u32) void {
    if (word != &enqueue_race.word) return;
    enqueue_race.inside.store(true, .release);
    while (!enqueue_race.released.load(.acquire)) std.atomic.spinLoopHint();
}

fn waitOnRaceWord(io: std.Io) void {
    io.futexWaitUncancelable(u32, &enqueue_race.word, 0);
    enqueue_race.done.store(true, .release);
}

test "races: a scheduler doesn't finish deinit while a cancel is about to nudge it" {
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    var t: IoThread = .{};
    try t.start(plain);
    var job = try t.iocp_io.concurrent(sleepMs, .{ t.iocp_io, 30 });
    nudge_race = .{};
    tasks.test_hooks.cancel_nudge_window = &stopBeforeNudge;
    defer tasks.test_hooks.cancel_nudge_window = null;
    const canceler = try std.Thread.spawn(.{}, cancelVoid, .{&job});
    // The cancel found the task not done and is about to nudge its scheduler. The task finishes
    // and the io thread shuts down meanwhile: its deinit must wait for the nudge.
    while (!nudge_race.inside.load(.acquire)) std.atomic.spinLoopHint();
    win32.Sleep(60);
    t.shutdown.set(plain);
    win32.Sleep(200);
    const deinited_during = t.deinited.load(.acquire);
    nudge_race.released.store(true, .release);
    canceler.join();
    t.thread.join();
    try std.testing.expect(!deinited_during);
    try std.testing.expect(t.deinited.load(.acquire));
}

var nudge_race: struct {
    inside: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
} = .{};

fn stopBeforeNudge() void {
    nudge_race.inside.store(true, .release);
    while (!nudge_race.released.load(.acquire)) std.atomic.spinLoopHint();
}

fn cancelVoid(f: *std.Io.Future(void)) void {
    f.cancel(.{ .userdata = undefined, .vtable = &Iocp.vtable });
}

var cancel_window: struct {
    inside: std.atomic.Value(bool) = .init(false),
    unlocked: std.atomic.Value(bool) = .init(false),
} = .{};

fn stopInCancelWindow() void {
    cancel_window.inside.store(true, .release);
    while (!cancel_window.unlocked.load(.acquire)) std.atomic.spinLoopHint();
}

fn cancelFromPlainThread(f: *std.Io.Future(error{Canceled}!void)) void {
    // This thread has no winio Io: its await is on the address.
    f.cancel(.{ .userdata = undefined, .vtable = &Iocp.vtable }) catch {};
}

fn sleepUs(io: std.Io, us: i64) void {
    io.sleep(.fromMicroseconds(us), .awake) catch unreachable; // never canceled
}

fn lockHeld2(io: std.Io, m: *std.Io.Mutex) error{Canceled}!void {
    try m.lock(io);
    m.unlock(io);
}

fn lockUnlockCount(io: std.Io, m: *std.Io.Mutex, done: *std.atomic.Value(u32)) void {
    m.lockUncancelable(io);
    m.unlock(io);
    _ = done.fetchAdd(1, .acq_rel);
}

/// WINIO_STRESS_SEED, or a fixed one (so a failing run can be repeated).
fn stressSeed() u64 {
    var buf: [32]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("WINIO_STRESS_SEED"), @ptrCast(&buf), buf.len);
    if (len == 0) return 0x5EED;
    var utf8: [64]u8 = undefined;
    return std.fmt.parseInt(u64, utf8[0..std.unicode.wtf16LeToWtf8(&utf8, buf[0..len])], 10) catch @panic("WINIO_STRESS_SEED: not a number");
}

const Stress = struct {
    fibers_io: std.Io,
    iocp_io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Changed only under `mutex`, the read and the write split across a sleep now and then.
    counter: u32 = 0,
    /// How many increments completed (atomic): `counter` must match.
    increments: u32 = 0,
    const workers_per_thread = 4;
    const steps = 150;
};

fn stressAll(s: *Stress, seed: u64) !void {
    defer win32.PostQuitMessage(0);
    var fibers_workers: [Stress.workers_per_thread]std.Io.Future(anyerror!void) = undefined;
    var io_workers: [Stress.workers_per_thread]std.Io.Future(anyerror!void) = undefined;
    for (&fibers_workers, &io_workers, 0..) |*p, *i, n| {
        p.* = try s.fibers_io.concurrent(stressWorker, .{ s, s.fibers_io, seed +% 2 * n });
        i.* = try s.iocp_io.concurrent(stressWorker, .{ s, s.iocp_io, seed +% 2 * n + 1 });
    }
    for (&fibers_workers, &io_workers) |*p, *i| {
        try p.await(s.fibers_io);
        try i.await(s.fibers_io);
    }
}

/// Random steps with `io` (its thread's): increments, sleeps, and children on either thread
/// (the Fibers takes them only from its own thread), awaited or canceled.
fn stressWorker(s: *Stress, io: std.Io, seed: u64) anyerror!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const on_fibers = io.userdata == s.fibers_io.userdata;
    for (0..Stress.steps) |_| switch (r.uintLessThan(u8, 4)) {
        0 => try stressIncrement(s, io, r.uintLessThan(u8, 8) == 0),
        1 => try io.sleep(.fromMicroseconds(r.uintLessThan(u32, 2000)), .awake),
        2, 3 => {
            const child_io = if (on_fibers and r.boolean()) s.fibers_io else s.iocp_io;
            var child = try child_io.concurrent(stressChild, .{ s, child_io, r.uintLessThan(u32, 3000) });
            if (r.boolean()) try child.await(io) else child.cancel(io) catch |err| switch (err) {
                error.Canceled => {},
                else => |e| return e,
            };
        },
        else => unreachable,
    };
}

fn stressChild(s: *Stress, io: std.Io, delay_us: u32) anyerror!void {
    try io.sleep(.fromMicroseconds(delay_us), .awake);
    try stressIncrement(s, io, delay_us % 5 == 0);
}

fn stressIncrement(s: *Stress, io: std.Io, slow: bool) !void {
    try s.mutex.lock(io);
    defer s.mutex.unlock(io);
    const before = s.counter;
    // Uncancelable: a canceled increment must not be half done.
    if (slow) io.sleep(.fromMicroseconds(500), .awake) catch {
        s.counter = before + 1;
        _ = @atomicRmw(u32, &s.increments, .Add, 1, .acq_rel);
        return error.Canceled;
    };
    s.counter = before + 1;
    _ = @atomicRmw(u32, &s.increments, .Add, 1, .acq_rel);
}

test "two threads: canceling cross-thread tasks before they've started (still in `incoming`)" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    // A long-running io-thread task keeps that thread busy (not looking at `incoming`): spin.
    var spinning = std.atomic.Value(bool).init(true);
    var busy = try t.iocp_io.concurrent(spinUntilCleared, .{&spinning});
    var queued: [50]std.Io.Future(error{Canceled}!u32) = undefined;
    for (&queued) |*q| q.* = try t.iocp_io.concurrent(sleepThenDouble, .{ t.iocp_io, 1 });
    // Their cancels land while they're still queued; then the io thread gets to them.
    var cancels: [50]std.Io.Future(void) = undefined;
    for (&cancels, &queued) |*c, *q| c.* = try io.concurrent(cancelAndExpect, .{ io, q });
    spinning.store(false, .release);
    busy.await(io);
    var waiter = try io.concurrent(awaitAllThenQuit, .{ io, &cancels });
    _ = fibers.runMessageLoop();
    waiter.await(io);
}

fn spinUntilCleared(flag: *std.atomic.Value(bool)) void {
    while (flag.load(.acquire)) std.atomic.spinLoopHint();
}

fn cancelAndExpect(io: std.Io, f: *std.Io.Future(error{Canceled}!u32)) void {
    if (f.cancel(io)) |_| @panic("a task canceled before it started finished anyway") else |_| {}
}

fn awaitAllThenQuit(io: std.Io, fs: []std.Io.Future(void)) void {
    defer win32.PostQuitMessage(0);
    for (fs) |*f| f.await(io);
}

test "two threads: children spawned at once from two Iocps don't inherit each other's pipes" {
    var a: IoThread = .{};
    var b: IoThread = .{};
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    try a.start(plain);
    defer a.stop(plain);
    try b.start(plain);
    defer b.stop(plain);
    for (0..3) |_| {
        var go = std.atomic.Value(bool).init(false);
        // a's child sleeps 3 s holding whatever it inherited; b's echoes and exits at once.
        var sleeper = try a.iocp_io.concurrent(spawnSleeper, .{ a.iocp_io, &go });
        var echoer = try b.iocp_io.concurrent(spawnEchoAndRead, .{ b.iocp_io, &go });
        win32.Sleep(5);
        go.store(true, .release);
        // b's read reaches end of file when its child exits, unless a's child holds its pipe.
        const elapsed_ms = try echoer.await(plain);
        try sleeper.await(plain);
        try std.testing.expect(elapsed_ms < 2000);
    }
}

test "two threads: with spawn_inheritance .listed, an Iocp's child never holds a std.Io.Threaded child's pipe" {
    var a: IoThread = .{ .options = .{ .spawn_inheritance = .listed } };
    const plain: std.Io = .{ .userdata = undefined, .vtable = &Iocp.vtable };
    try a.start(plain);
    defer a.stop(plain);
    for (0..5) |_| {
        var go = std.atomic.Value(bool).init(false);
        // The Iocp's child sleeps 3 s; the Threaded's (this thread's) echoes and exits at once.
        var sleeper = try a.iocp_io.concurrent(spawnSleeper, .{ a.iocp_io, &go });
        win32.Sleep(5);
        go.store(true, .release);
        // std.testing.io is a std.Io.Threaded: its read ends when its child exits, unless the
        // Iocp's child inherited the pipe's other end.
        const elapsed_ms = try spawnEchoAndRead(std.testing.io, &go);
        try sleeper.await(plain);
        try std.testing.expect(elapsed_ms < 2000);
    }
}

fn spawnSleeper(io: std.Io, go: *std.atomic.Value(bool)) !void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "3000" }, .stdout = .pipe });
    // Alive past the echoer's limit, holding whatever it inherited.
    try io.sleep(.fromMilliseconds(2500), .awake);
    child.kill(io);
}

fn spawnEchoAndRead(io: std.Io, go: *std.atomic.Value(bool)) !i64 {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    const start = std.Io.Timestamp.now(io, .awake);
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "stderr", "x" }, .stdout = .pipe, .stderr = .ignore });
    var buf: [16]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    var out: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    _ = try reader.interface.streamRemaining(&w);
    _ = try child.wait(io);
    return start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
}

test "two threads: a burst of cross-thread spawns from several threads at once" {
    var t: IoThread = .{};
    try t.start(.{ .userdata = undefined, .vtable = &Iocp.vtable });
    defer t.stop(t.iocp_io);
    var threads: [4]std.Thread = undefined;
    var sums: [4]u64 = @splat(0);
    for (&threads, &sums) |*th, *sum| th.* = try std.Thread.spawn(.{}, spawnBurst, .{ &t, sum });
    for (threads) |th| th.join();
    for (sums) |sum| try std.testing.expectEqual(@as(u64, 500 * 499), sum);
}

fn spawnBurst(t: *IoThread, sum: *u64) void {
    var futures: [500]std.Io.Future(u32) = undefined;
    for (&futures, 0..) |*f, i| f.* = t.iocp_io.concurrent(plainDouble, .{@as(u32, @intCast(i))}) catch unreachable;
    for (&futures) |*f| sum.* += f.await(t.iocp_io);
}

test "two threads: cancel racing a task that's finishing, many times" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    for (0..2000) |i| {
        var f = try t.iocp_io.concurrent(plainDouble, .{@as(u32, @intCast(i))});
        // No cancelation point in it: whatever the timing, the result comes back.
        try std.testing.expectEqual(@as(u32, @intCast(2 * i)), f.cancel(io));
    }
}

test "two threads: a thread without a winio Io awaits a Fibers task; two Fibers on two threads" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var event: std.Io.Event = .unset;
    var task = try io.concurrent(waitEventThenThreadId, .{ io, &event });
    // Another thread with its own Fibers sets the event and awaits our task.
    const other = try std.Thread.spawn(.{}, secondFibers, .{ &event, &task, io });
    _ = fibers.runMessageLoop();
    other.join();
}

fn waitEventThenThreadId(io: std.Io, event: *std.Io.Event) u32 {
    defer win32.PostQuitMessage(0);
    event.waitUncancelable(io);
    return win32.GetCurrentThreadId();
}

fn secondFibers(event: *std.Io.Event, task: *std.Io.Future(u32), first_io: std.Io) void {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    event.set(io);
    // Its root fiber awaits the first Fibers' task (its own tasks run meanwhile).
    const id = task.await(first_io);
    if (id == win32.GetCurrentThreadId()) @panic("the first Fibers' task ran on the second Fibers' thread");
}

test "two threads: Event timeouts racing a set from the other thread" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    for (0..300) |i| {
        var event: std.Io.Event = .unset;
        var setter = try t.iocp_io.concurrent(setAfterMicros, .{ t.iocp_io, &event, @as(u32, @intCast(i % 7)) * 100 });
        // Either result is fine; the wait must end, and a set event stays set.
        event.waitTimeout(io, .{ .duration = .{ .raw = .fromMicroseconds(@as(i64, @intCast(i % 5)) * 100), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => unreachable,
        };
        setter.await(io);
        try std.testing.expect(event.isSet());
    }
}

fn setAfterMicros(io: std.Io, event: *std.Io.Event, us: u32) void {
    io.sleep(.fromMicroseconds(us), .awake) catch unreachable; // never canceled
    event.set(io);
}

test "two threads: a future outlives the Iocp (and the thread) that ran its task" {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    var t: IoThread = .{};
    try t.start(io);
    var job = try t.iocp_io.concurrent(plainDouble, .{21});
    // Finished, then its Iocp deinited and the thread gone (its stack, where the Iocp was, freed).
    sleepMs(io, 20);
    t.stop(io);
    try std.testing.expectEqual(@as(u32, 42), job.await(io));
}

test "leaks: rounds of everything leave handles and USER objects exactly as they were" {
    // WINIO_LEAK_ROUNDS for a longer run (300 measured flat), printing each round.
    const long = envNumber("WINIO_LEAK_ROUNDS");
    const rounds = long orelse 10;
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    const io = fibers.io();
    // Warm-up: first uses allocate for good (DLLs, the window class, caches).
    for (0..3) |_| try leakRound(io);
    const first = Counters.now();
    for (0..rounds) |round| {
        try leakRound(io);
        if (long != null) {
            const c = Counters.now();
            std.debug.print("round {}: handles {} USER {} private {} KiB\n", .{ round, c.handles, c.user, c.private / 1024 });
        }
    }
    const last = Counters.now();
    try std.testing.expectEqual(first.handles, last.handles);
    try std.testing.expectEqual(first.user, last.user);
    // The heap's own churn moves this a little either way.
    try std.testing.expect(last.private < first.private + 1024 * 1024);
}

fn envNumber(comptime name: []const u8) ?u64 {
    var buf: [32]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), @ptrCast(&buf), buf.len);
    if (len == 0) return null;
    var utf8: [64]u8 = undefined;
    return std.fmt.parseInt(u64, utf8[0..std.unicode.wtf16LeToWtf8(&utf8, buf[0..len])], 10) catch @panic(name ++ ": not a number");
}

const Counters = struct {
    handles: u32,
    user: u32,
    private: usize,

    fn now() Counters {
        var mem: win32.PROCESS_MEMORY_COUNTERS_EX = undefined;
        mem.cb = @sizeOf(win32.PROCESS_MEMORY_COUNTERS_EX);
        if (0 == win32.K32GetProcessMemoryInfo(win32.GetCurrentProcess(), @ptrCast(&mem), mem.cb)) win32.panicWin32("K32GetProcessMemoryInfo", win32.GetLastError());
        return .{ .handles = handleCount(), .user = win32.GetGuiResources(win32.GetCurrentProcess(), win32.GR_USEROBJECTS), .private = mem.PrivateUsage };
    }
};

/// One round of what winio does across threads: an io thread started and stopped, a second Fibers on
/// its own thread, cross-thread tasks awaited and canceled (one in a pipe read), children, files.
fn leakRound(io: std.Io) !void {
    var t: IoThread = .{};
    try t.start(io);
    defer t.stop(io);
    // Tasks across threads.
    var jobs: [50]std.Io.Future(u32) = undefined;
    for (&jobs, 0..) |*j, i| j.* = try t.iocp_io.concurrent(plainDouble, .{@as(u32, @intCast(i))});
    for (&jobs) |*j| _ = j.await(io);
    var sleeper = try t.iocp_io.concurrent(sleepThenDouble, .{ t.iocp_io, 1 });
    sleepMs(io, 2);
    _ = sleeper.cancel(io) catch {};
    var reader = try t.iocp_io.concurrent(readUnwrittenPipe, .{t.iocp_io});
    sleepMs(io, 2);
    _ = reader.cancel(io) catch {};
    // Children and files, on the io thread.
    var io_work = try t.iocp_io.concurrent(leakIoWork, .{t.iocp_io});
    try io_work.await(io);
    // A second Fibers, on its own thread: its fiber and wake Event come and go.
    var event: std.Io.Event = .unset;
    const other = try std.Thread.spawn(.{}, loopThenSet, .{&event});
    event.waitUncancelable(io);
    other.join();
}

fn leakIoWork(io: std.Io) !void {
    const gpa = std.testing.allocator;
    const result = try run(io, &.{ test_options.child, "big", "5000" }, .none);
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    try std.testing.expectError(error.Timeout, run(io, &.{ test_options.child, "sleep", "10000" }, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }));
    var child = try std.process.spawn(io, .{ .argv = &.{ test_options.child, "sleep", "10000" }, .stdin = .pipe, .stdout = .pipe });
    child.kill(io);
    try writeReadBack(io, "winio-leak.txt", "leak round");
}

fn loopThenSet(event: *std.Io.Event) void {
    var fibers: Fibers = .init(std.testing.allocator);
    defer fibers.deinit();
    event.set(fibers.io());
}

test "two threads: a thread without a winio Io waits on an io-thread Event and awaits a task" {
    var iocp_thread: IoThread = .{};
    // This thread has no winio Io here: its futex waits are on the address, whichever winio Io
    // value it passes (they act for the calling thread). Before the io thread is up there is
    // none to pass but the vtable alone.
    try iocp_thread.start(.{ .userdata = undefined, .vtable = &Iocp.vtable });
    defer iocp_thread.stop(iocp_thread.iocp_io);
    var event: std.Io.Event = .unset;
    var setter = try iocp_thread.iocp_io.concurrent(setAfter, .{ iocp_thread.iocp_io, &event, 20 });
    event.waitUncancelable(iocp_thread.iocp_io);
    setter.await(iocp_thread.iocp_io);
    var job = try iocp_thread.iocp_io.concurrent(sleepThenThreadId, .{ iocp_thread.iocp_io, 10 });
    try std.testing.expectEqual(iocp_thread.thread_id, job.await(iocp_thread.iocp_io));
}

const iocp_tested = [_][]const u8{
    "concurrent",             "async",                   "await",                 "cancel",
    "futexWait",              "futexWaitUncancelable",   "futexWake",             "sleep",
    "now",                    "crashHandler",            "recancel",              "swapCancelProtection",
    "checkCancel",            "fileReadPositional",      "fileWritePositional",   "operate",
    "dirCreateFile",          "dirOpenFile",             "fileSeekBy",            "fileSeekTo",
    "fileWriteFileStreaming", "fileWriteFilePositional", "fileClose",             "childWait",
    "childKill",              "batchAwaitAsync",         "batchAwaitConcurrent",  "batchCancel",
    "processSpawn",           "dirCreateFileAtomic",     "processExecutableOpen",
};

/// The Iocp's own operations it doesn't implement yet (they panic saying so).
const iocp_expected_not_implemented = [_][]const u8{
    "groupAsync",    "groupConcurrent", "groupAwait",          "groupCancel",
    "fileLock",      "fileTryLock",     "fileUnlock",          "fileDowngradeLock",
    "netListenIp",   "netAccept",       "netBindIp",           "netConnectIp",
    "netListenUnix", "netConnectUnix",  "netSocketCreatePair", "netWriteFile",
    "netClose",      "netShutdown",
};

test "Iocp: every operation is implemented and tested, not implemented yet, or forwarded" {
    @setEvalBranchQuota(100_000);
    var mismatches: std.ArrayList(u8) = .empty;
    defer mismatches.deinit(std.testing.allocator);
    var forwarded: usize = 0;
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| {
        const is_tested = comptime for (iocp_tested) |t| {
            if (std.mem.eql(u8, t, name)) break true;
        } else false;
        const is_not_implemented = comptime for (iocp_expected_not_implemented) |u| {
            if (std.mem.eql(u8, u, name)) break true;
        } else false;
        const support = comptime Iocp.support(name);
        if ((support == .implemented) != is_tested or (support == .unimplemented) != is_not_implemented)
            try mismatches.print(std.testing.allocator, "  {s}: {t}, tested={}, expected not implemented={}\n", .{ name, support, is_tested, is_not_implemented });
        if (support == .forwarded) forwarded += 1;
    }
    if (mismatches.items.len > 0) {
        std.debug.print("operations whose support doesn't match the tests:\n{s}", .{mismatches.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(forwarded > 50);
}

test "Iocp: every operation it doesn't implement yet panics, naming itself" {
    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(std.testing.allocator);
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| {
        switch (comptime Iocp.support(name)) {
            // Forwarded: std's Io tests run them.
            .implemented, .forwarded => {},
            .unimplemented => try expectPanic(&failures, "iocp." ++ name, "winio.Iocp: std.Io's " ++ name ++ " isn't implemented"),
            .@"unreachable" => unreachable,
        }
    }
    // `operate` streams files; every other kind panics.
    inline for (@typeInfo(std.Io.Operation).@"union".field_names) |tag| {
        if (comptime std.mem.eql(u8, tag, "file_read_streaming") or std.mem.eql(u8, tag, "file_write_streaming")) continue;
        try expectPanic(&failures, "iocp.operate." ++ tag, "winio.Iocp: std.Io's operate " ++ tag ++ " isn't implemented");
    }
    if (failures.items.len > 0) {
        std.debug.print("{s}", .{failures.items});
        return error.TestUnexpectedResult;
    }
}

test "Iocp: misuse panics, saying what went wrong" {
    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(std.testing.allocator);
    inline for (@typeInfo(panic_case.IocpMisuse).@"enum".field_names) |name| {
        const expected = switch (@field(panic_case.IocpMisuse, name)) {
            .second_init => "this thread is a fiber already",
            .io_after_deinit => "winio.Iocp used on a thread it doesn't belong to, or after deinit",
            .deinit_with_unfinished_task => "deinit with 1 tasks not finished",
            .await_deadlock, .futex_wait_deadlock => "winio.Iocp: a wait nothing could end",
            .recancel_without_canceled => "winio: recancel without an error.Canceled to re-arm",
            .synchronous_handle => "winio.Iocp: a synchronous handle: the Iocp does I/O only on overlapped ones",
            .nonblocking_flag_wrong => "winio.Iocp: an overlapped handle whose File.flags.nonblocking is false",
            .canceled_outside => "winio.Iocp: an operation was canceled, but not by winio",
        };
        try expectPanic(&failures, "iocp." ++ name, expected);
    }
    if (failures.items.len > 0) {
        std.debug.print("{s}", .{failures.items});
        return error.TestUnexpectedResult;
    }
}

const std = @import("std");
const test_options = @import("test_options");
const win32 = @import("win32").everything;
const windows = std.os.windows;

const Iocp = @import("Iocp.zig");
const Fibers = @import("Fibers.zig");
const panic_case = @import("panic_case.zig");
const tasks = @import("tasks.zig");
