//! What `gamefibers.zig` and `gameplain.zig` share: the window, painting, logging, the std.Io
//! work both do the same way (the startup log, the file tour, the long write), and the reaction
//! game's rules and display. They differ in how they run the game: gameplain with Win32 timers
//! and a state machine, gamefibers with a task.

/// Null before the window is created and once it's destroyed.
pub var hwnd: ?win32.HWND = null;

var last_log_buf: [128]u8 = undefined;
var last_log_len: usize = 0;

/// The reaction game (Space): a countdown, "Go!" flashing, then a click as fast as you can.
pub const game_countdown = [_]u8{ 3, 2, 1 };
pub const game_flashes = 5;
pub const game_flash_ms = 200;
pub const game_click_timeout_ms = 5000;

/// Where the game is, for the window to show.
pub const Game = union(enum) {
    idle,
    count: u8,
    go,
    blank,
    waiting,
};
/// The directory the file operations (F) work in, in the current directory.
pub const demo_dir = "winio-example";
/// The long file operation (W): how long it writes, and the size of the file it cycles through.
/// Time-bound, not size-bound: a fast disk writes hundreds of MiB per second.
pub const long_write_ms = 3000;
pub const long_write_file_mb = 64;
pub const long_write_path = "winio-example-long.bin";
pub const long_write_chunk: [1024 * 1024]u8 = @splat(0xAB);

/// The help lines, which both examples show.
pub const help = [_][]const u8{
    "Space: reaction game (3, 2, 1, Go! flashes, then click as fast as you can); Escape cancels it",
    "F: every file and directory operation, in " ++ demo_dir,
    std.fmt.comptimePrint("W: write and sync a file for {d} s (file I/O blocks this thread: the window freezes)", .{long_write_ms / 1000}),
};

/// Logs the exe's path and some random bytes.
pub fn logStartup(io: std.Io) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);
    std.log.info("exe: {s}", .{path_buf[0..len]});
    var random: [8]u8 = undefined;
    io.random(&random);
    std.log.info("random bytes: {x}", .{&random});
    try io.randomSecure(&random);
    std.log.info("secure random bytes: {x}", .{&random});
}

/// Every file and directory operation, in `demo_dir`, logged as it goes; removes what it made.
/// Each call is synchronous: the window waits for it.
pub fn fileTour(io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    const text = "hello from the example\r\n";
    try cwd.createDir(io, demo_dir, .default_dir);
    std.log.info("created directory {s}", .{demo_dir});
    {
        const dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
        defer dir.close(io);
        {
            const file = try dir.createFile(io, "hello.txt", .{});
            defer file.close(io);
            try file.writePositionalAll(io, text, 0);
            try file.sync(io);
            std.log.info("created hello.txt, wrote and synced {d} bytes", .{try file.length(io)});
        }
        const stat = try dir.statFile(io, "hello.txt", .{});
        std.log.info("stat hello.txt: {d} bytes, a {t}", .{ stat.size, stat.kind });
        try dir.access(io, "hello.txt", .{ .write = true });
        std.log.info("hello.txt is writable", .{});
        {
            const file = try dir.openFile(io, "hello.txt", .{});
            defer file.close(io);
            var buf: [64]u8 = undefined;
            const n = try file.readPositionalAll(io, &buf, 0);
            std.log.info("read back: {s}", .{std.mem.trimEnd(u8, buf[0..n], "\r\n")});
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try dir.realPathFile(io, "hello.txt", &path_buf);
        std.log.info("real path: {s}", .{path_buf[0..len]});
        try dir.rename("hello.txt", dir, "renamed.txt", io);
        std.log.info("renamed hello.txt to renamed.txt", .{});
        var it = dir.iterate();
        while (try it.next(io)) |entry| std.log.info("listing {s}: {s} (a {t})", .{ demo_dir, entry.name, entry.kind });
        try dir.deleteFile(io, "renamed.txt");
    }
    try cwd.deleteDir(io, demo_dir);
    std.log.info("deleted renamed.txt and {s}", .{demo_dir});
}

/// The long file operation: for `long_write_ms`, writes 1 MiB at a time, each synced, cycling
/// through a `long_write_file_mb` MiB file, which it then deletes. Blocks the thread
/// throughout, even in a task: the window freezes.
pub fn longWrite(io: std.Io) !void {
    std.log.info("writing for {d} s; the window freezes until it's done", .{long_write_ms / 1000});
    paintNow();
    const cwd = std.Io.Dir.cwd();
    const start = std.Io.Timestamp.now(io, .awake);
    var mb: u64 = 0;
    {
        const file = try cwd.createFile(io, long_write_path, .{});
        defer file.close(io);
        while (start.untilNow(io, .awake).toMilliseconds() < long_write_ms) : (mb += 1) {
            try file.writePositionalAll(io, &long_write_chunk, mb % long_write_file_mb * long_write_chunk.len);
            try file.sync(io);
        }
    }
    try cwd.deleteFile(io, long_write_path);
    std.log.info("wrote and synced {d} MiB in {d} ms (the window was frozen meanwhile)", .{ mb, start.untilNow(io, .awake).toMilliseconds() });
}

/// The lines both examples show, after their first one.
pub fn statusLines(bufs: *[3][100]u8, uptime_ms: i64, clicks: u32, game: Game) [11][]const u8 {
    return .{
        std.fmt.bufPrint(&bufs[0], "Uptime: {d}.{d} s (repainted every 100 ms)", .{
            @divTrunc(uptime_ms, 1000), @divTrunc(@mod(uptime_ms, 1000), 100),
        }) catch unreachable,
        "",
        std.fmt.bufPrint(&bufs[1], "Clicks: {d} (click anywhere)", .{clicks}) catch unreachable,
        switch (game) {
            .idle => "Game: not running",
            .count => |n| std.fmt.bufPrint(&bufs[2], "Game: {d}...", .{n}) catch unreachable,
            .go => "Game: GO!",
            .blank => "Game:",
            .waiting => "Game: click now!",
        },
        "",
        help[0],
        help[1],
        help[2],
        "",
        "Last log line:",
        lastLog(),
    };
}

/// The root file's `std_options.logFn`: std.log's output (stderr), also kept for the window to
/// show the last line.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);
    const shown = std.fmt.bufPrint(&last_log_buf, level.asText() ++ ": " ++ format, args) catch &last_log_buf;
    last_log_len = shown.len;
    repaint();
}

pub fn lastLog() []const u8 {
    return last_log_buf[0..last_log_len];
}

/// Registers the window class and creates and shows the window (`hwnd`).
pub fn createWindow(title: [*:0]const u16, window_proc: win32.WNDPROC) void {
    const class = win32.L("MainWindow");
    if (0 == win32.RegisterClassExW(&.{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = window_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = win32.GetSysColorBrush(win32.COLOR_WINDOW),
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    })) win32.panicWin32("RegisterClassExW", win32.GetLastError());
    hwnd = win32.CreateWindowExW(
        .{},
        class,
        title,
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        640,
        300,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindowExW", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
}

pub fn repaint() void {
    const h = hwnd orelse return;
    if (0 == win32.InvalidateRect(h, null, 0)) win32.panicWin32("InvalidateRect", win32.GetLastError());
}

/// Paints now (UpdateWindow), before something that keeps the thread from painting.
pub fn paintNow() void {
    const h = hwnd orelse return;
    if (0 == win32.UpdateWindow(h)) win32.panicWin32("UpdateWindow", win32.GetLastError());
}

/// WM_PAINT: draws `lines`, one per row.
///
/// Double-buffered, so it doesn't flicker: everything is drawn into a bitmap the window's size,
/// then copied to the window with one BitBlt. The window procedure returns 1 for WM_ERASEBKGND,
/// so nothing erases the window first.
pub fn paint(window: win32.HWND, lines: []const []const u8) void {
    const window_dc, const ps = win32.beginPaint(window);
    defer win32.endPaint(window, &ps);
    const size = win32.getClientSize(window);
    // (zigwin32 declares it non-null, so a failure can't be checked.)
    const hdc = win32.CreateCompatibleDC(window_dc);
    defer win32.deleteDc(hdc);
    const bitmap = win32.CreateCompatibleBitmap(window_dc, size.cx, size.cy) orelse
        win32.panicWin32("CreateCompatibleBitmap", win32.GetLastError());
    defer win32.deleteObject(bitmap);
    const old_bitmap = win32.SelectObject(hdc, bitmap) orelse win32.panicWin32("SelectObject", win32.GetLastError());
    // Deselected before the bitmap is deleted.
    defer _ = win32.SelectObject(hdc, old_bitmap);

    win32.fillRect(hdc, .{ .left = 0, .top = 0, .right = size.cx, .bottom = size.cy }, win32.GetSysColorBrush(win32.COLOR_WINDOW).?);
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    for (lines, 0..) |line, i| {
        if (line.len > 0) win32.textOutA(hdc, 10, 10 + 20 * @as(i32, @intCast(i)), line);
    }
    if (0 == win32.BitBlt(window_dc, 0, 0, size.cx, size.cy, hdc, 0, 0, win32.SRCCOPY)) win32.panicWin32("BitBlt", win32.GetLastError());
}

const std = @import("std");
const win32 = @import("win32").everything;
