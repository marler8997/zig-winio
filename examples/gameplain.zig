//! `gamefibers.zig` without winio, for comparison: plain Win32 for the window and the waiting,
//! and std's single-threaded `std.Io.Threaded` for the rest. Same window, same behavior, one
//! thread, no tasks.
//!
//! - The reaction game (Space): a state machine (`game`, plus `flashes` and `waiting_since`)
//!   driven by one timer. Each WM_TIMER finds where the game is and moves it to its next step,
//!   re-arming the timer for that step's length; a click ends it while it waits; Escape kills the
//!   timer and resets the state. gamefibers writes the same game as one function.
//! - A 100 ms timer repaints (the uptime). Windows dispatches WM_TIMER inside modal loops too, so
//!   the game and the uptime keep going while the window is resized or moved.
//! - Clicks, files and directories (F), the long file operation (W): right in the window
//!   procedure, the same code as gamefibers's (`common.zig`). std.Io.Threaded's file I/O is
//!   synchronous, so the long write freezes the window. Non-blocking file I/O needs its
//!   completion delivered somewhere the GUI thread looks, which on Windows means another thread
//!   (an I/O completion port) or APCs (which modal loops don't run); so for non-blocking I/O, do
//!   it on another, non-GUI thread.
//!
//! Logging is std.log, to stderr; crash handling (`crash.zig`) makes stderr `gameplain.log`
//! next to the exe when the program starts without one (from Explorer).

pub const panic = crash.panic;
pub const std_options: std.Options = .{
    // std's segfault handler logs and aborts with no way to handle it; with it disabled, every
    // exception reaches crash.zig's filter.
    .enable_segfault_handler = false,
    .logFn = common.logFn,
};

/// std.Io without concurrency: every call is a plain blocking call on this thread, `concurrent`
/// returns error.ConcurrencyUnavailable, and `async` runs the function right away.
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

var start: std.Io.Timestamp = undefined;
var clicks: u32 = 0;

// The game's state machine.
var game: common.Game = .idle;
/// The flashes done so far (while `game` is `.go` or `.blank`).
var flashes: u32 = 0;
/// When the game started waiting for the click (while `game` is `.waiting`).
var waiting_since: std.Io.Timestamp = undefined;

/// The window's timers.
const Timer = enum(usize) { tick = 1, game = 2 };

pub fn main() void {
    crash.init();
    start = .now(io, .awake);
    common.logStartup(io) catch |err| std.debug.panic("startup: {t}", .{err});
    common.createWindow(win32.L("game plain Win32"), &windowProc);
    setTimer(.tick, 100);

    // The default loop: a modal loop (a MessageBox, a window drag) dispatches messages without
    // it, so anything added here would be skipped meanwhile.
    var msg: win32.MSG = undefined;
    while (true) {
        switch (win32.GetMessageW(&msg, null, 0, 0)) {
            0 => break, // WM_QUIT
            -1 => win32.panicWin32("GetMessageW", win32.GetLastError()),
            else => {},
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    std.log.info("closing", .{});
    if (msg.wParam != 0) std.process.exit(@intCast(msg.wParam));
}

/// The game's next step, when its timer fires: each case is one step of the sequence.
fn gameStep() void {
    switch (game) {
        .idle => unreachable, // no timer then
        .count => |n| if (n > common.game_countdown[common.game_countdown.len - 1]) {
            setGame(.{ .count = n - 1 });
        } else {
            flashes = 0;
            setGame(.go);
            setTimer(.game, common.game_flash_ms);
        },
        .go => setGame(.blank),
        .blank => {
            flashes += 1;
            if (flashes < common.game_flashes) {
                setGame(.go);
            } else {
                waiting_since = .now(io, .awake);
                setGame(.waiting);
                setTimer(.game, common.game_click_timeout_ms);
            }
        },
        .waiting => {
            endGame();
            std.log.info("too slow", .{});
        },
    }
}

fn startGame() void {
    setGame(.{ .count = common.game_countdown[0] });
    setTimer(.game, 1000);
    std.log.info("game started", .{});
}

fn endGame() void {
    killTimer(.game);
    setGame(.idle);
}

fn setGame(g: common.Game) void {
    game = g;
    common.repaint();
}

fn setTimer(timer: Timer, ms: u32) void {
    if (0 == win32.SetTimer(common.hwnd, @backingInt(timer), ms, null)) win32.panicWin32("SetTimer", win32.GetLastError());
}

fn killTimer(timer: Timer) void {
    if (0 == win32.KillTimer(common.hwnd, @backingInt(timer))) win32.panicWin32("KillTimer", win32.GetLastError());
}

fn windowProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            clicks += 1;
            const point = win32.pointFromLparam(lparam);
            std.log.info("click at ({d}, {d})", .{ point.x, point.y });
            if (game == .waiting) {
                endGame();
                std.log.info("reaction time: {d} ms", .{waiting_since.untilNow(io, .awake).toMilliseconds()});
            }
        },
        win32.WM_KEYDOWN => switch (wparam) {
            @backingInt(win32.VK_SPACE) => if (game == .idle) startGame(),
            @backingInt(win32.VK_ESCAPE) => if (game != .idle) {
                endGame();
                std.log.info("game canceled", .{});
            },
            'F' => common.fileTour(io) catch |err| std.debug.panic("file tour: {t}", .{err}),
            'W' => common.longWrite(io) catch |err| std.debug.panic("long write: {t}", .{err}),
            else => {},
        },
        win32.WM_TIMER => switch (@as(Timer, @fromBackingInt(@intCast(wparam)))) {
            .tick => common.repaint(),
            .game => gameStep(),
        },
        win32.WM_DESTROY => {
            common.hwnd = null;
            win32.PostQuitMessage(0);
        },
        win32.WM_PAINT => {
            var bufs: [3][100]u8 = undefined;
            common.paint(hwnd, &(.{"One thread, no tasks: timers and the window procedure."} ++ common.statusLines(&bufs, start.untilNow(io, .awake).toMilliseconds(), clicks, game)));
        },
        // `common.paint` covers the whole window: erasing first would only flicker.
        win32.WM_ERASEBKGND => return 1,
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

const common = @import("common.zig");
const crash = @import("crash.zig");
const std = @import("std");
const win32 = @import("win32").everything;
