//! A single-threaded win32 program on winio's Fibers, driven by their message loop: one thread
//! runs the window and a few tasks (fibers). gameplain (`gameplain.zig`) is this program without
//! tasks, for comparison; `common.zig` has what they share.
//!
//! Two Ios, each used for what it does: `fibers_io` (tasks, sleeps, Event, Queue: waiting without
//! blocking the thread) and `blocking_io`, std's single-threaded `std.Io.Threaded` (files, the exe
//! path, random: plain blocking calls, gameplain's Io too). `fibers_io` does nothing that blocks:
//! a file operation on it panics, naming itself. So every blocking call is visible where it's
//! made, as a `blocking_io` call. (A library taking one Io that both waits and reads files would
//! get a `winio.Fibers.Layer` over `blocking_io`; nothing here needs one.)
//!
//! - The reaction game (Space): one task, `reactionGame`, written as the sequence it is: count
//!   down, flash, wait for the click or time out. Escape cancels it wherever it is (its sleep or
//!   wait returns error.Canceled), and its `defer` resets the display. gameplain needs a state
//!   machine spread over three message handlers for the same game.
//! - A window procedure may not wait on a futex (no task could run meanwhile), and canceling a
//!   task waits for it. So Space and Escape go to a controller task, through a std.Io.Queue (a put
//!   with `min` 0 never waits); the click the game waits for is an Event (`set` never waits).
//! - A ticker task records the uptime and repaints every 100 ms; WM_PAINT only shows what the
//!   tasks recorded. Tasks don't run while Windows runs a modal loop (the window being resized
//!   or moved, even held still mid-resize): the game and the uptime stand still (the window
//!   still repaints), and go on when it ends (gameplain's timers keep going). To keep the uptime
//!   counting meanwhile, a program can update it from a window timer of its own instead of a
//!   task: `SetTimer(hwnd, id, 100, null)` once the window exists, and on its WM_TIMER (modal
//!   loops dispatch WM_TIMER) record the uptime and `common.repaint()`. The game, being a task,
//!   would still wait for the loop to end. Logic that must keep time during a modal loop belongs
//!   in timer messages, as in gameplain.
//! - Clicks, files and directories (F), the long file operation (W): right in the window
//!   procedure, the same code as gameplain's (`common.zig`), on `blocking_io`. Its file I/O is
//!   synchronous, so the long write freezes the window (tasks wouldn't help: a fiber can't switch
//!   away in the middle of a system call). Non-blocking file I/O
//!   needs its completion delivered somewhere the GUI thread looks, which on Windows means another
//!   thread (an I/O completion port) or APCs (which modal loops don't run); so for non-blocking
//!   I/O, do it on another, non-GUI thread (winio.Iocp).
//! - Cleanup: closing the window ends `runMessageLoop`; `main` then cancels the tasks, and the
//!   root fiber's waits (outside the message loop) run them until they return.
//!
//! Logging is std.log, to stderr; crash handling (`crash.zig`) makes stderr `gamefibers.log`
//! next to the exe when the program starts without one (from Explorer).

pub const panic = crash.panic;
pub const std_options: std.Options = .{
    // std's segfault handler logs and aborts with no way to handle it; with it disabled, every
    // exception reaches crash.zig's filter.
    .enable_segfault_handler = false,
    .logFn = common.logFn,
};

/// The Fibers' allocator (their tasks). Like them, it lives until the process exits, so it is
/// never deinited: no leak check (the task list is still allocated then).
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// std.Io without concurrency: every call a plain blocking call on this thread.
var threaded: std.Io.Threaded = .init_single_threaded;
/// For what blocks: files, the exe path, random, and std.debug and std.log (stderr).
const blocking_io = threaded.io();
pub const std_options_debug_io = blocking_io;

/// The tasks, futexes and time. The first thread that starts a task with them becomes theirs (a
/// fiber): here the main thread. Never deinited: the process's exit cleans them up.
var fibers: winio.Fibers = .init(debug_allocator.allocator());
/// For waiting without blocking: tasks, sleeps, Event, Queue. Nothing on it blocks.
const fibers_io = fibers.io();

// What the window procedure and the tasks share. One thread, so no locking: a fiber only
// switches to another where it waits.
var start: std.Io.Timestamp = undefined;
/// Recorded by the ticker task.
var uptime_ms: i64 = 0;
var clicks: u32 = 0;
var game: common.Game = .idle;
/// Set by the window procedure on a click while the game waits for one.
var clicked: std.Io.Event = .unset;
/// From the window procedure (and the game, as it ends) to the controller.
var commands: std.Io.Queue(Command) = undefined;

const Command = enum { start_game, cancel_game, game_finished };

pub fn main() void {
    crash.init();
    start = .now(fibers_io, .awake);
    var command_buffer: [16]Command = undefined;
    commands = .init(&command_buffer);
    common.logStartup(blocking_io) catch |err| std.debug.panic("startup: {t}", .{err});
    common.createWindow(win32.L("game fibers"), &windowProc);

    // Tasks run once the message loop does: it dispatches window messages and resumes tasks
    // whose waits ended, until WM_QUIT.
    var ticker = fibers_io.concurrent(tick, .{}) catch |err| std.debug.panic("starting the ticker: {t}", .{err});
    defer ticker.cancel(fibers_io);
    var controller = fibers_io.concurrent(control, .{}) catch |err| std.debug.panic("starting the controller: {t}", .{err});
    // Outside the message loop, the root fiber's waits run the tasks: the cancels run each until it
    // returns.
    defer controller.cancel(fibers_io) catch |err| std.debug.panic("the controller failed: {t}", .{err});
    const exit_code = fibers.runMessageLoop();
    if (exit_code != 0) std.process.exit(@intCast(exit_code));
}

/// The reaction game, start to finish. A cancel ends whichever sleep or wait it is in with
/// error.Canceled.
fn reactionGame() error{Canceled}!void {
    defer {
        setGame(.idle);
        // For the controller, which awaits it (a put with `min` 0 never waits).
        send(.game_finished);
    }
    for (common.game_countdown) |n| {
        setGame(.{ .count = n });
        try fibers_io.sleep(.fromSeconds(1), .awake);
    }
    for (0..common.game_flashes) |_| {
        setGame(.go);
        try fibers_io.sleep(.fromMilliseconds(common.game_flash_ms), .awake);
        setGame(.blank);
        try fibers_io.sleep(.fromMilliseconds(common.game_flash_ms), .awake);
    }
    clicked.reset();
    setGame(.waiting);
    const waiting_since = std.Io.Timestamp.now(fibers_io, .awake);
    clicked.waitTimeout(fibers_io, .{ .duration = .{ .raw = .fromMilliseconds(common.game_click_timeout_ms), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return std.log.info("too slow", .{}),
        error.Canceled => |e| return e,
    };
    std.log.info("reaction time: {d} ms", .{waiting_since.untilNow(fibers_io, .awake).toMilliseconds()});
}

/// Starts and cancels the game for the window procedure (canceling waits, which a window
/// procedure may not). Runs until canceled.
fn control() !void {
    var game_task: ?std.Io.Future(error{Canceled}!void) = null;
    defer if (game_task) |*t| t.cancel(fibers_io) catch {};
    while (true) {
        const command = commands.getOne(fibers_io) catch |err| switch (err) {
            error.Canceled => break,
            error.Closed => unreachable, // never closed
        };
        switch (command) {
            .start_game => if (game_task == null) {
                game_task = try fibers_io.concurrent(reactionGame, .{});
                std.log.info("game started", .{});
            },
            .cancel_game => if (game_task) |*t| {
                const result = t.cancel(fibers_io);
                game_task = null;
                if (result) |_| {} else |err| std.log.info("game canceled: error.{t}", .{err});
            },
            // It has returned, or is returning (its `defer` sent this), so this barely waits.
            .game_finished => if (game_task) |*t| {
                t.await(fibers_io) catch {};
                game_task = null;
            },
        }
    }
    std.log.info("closing", .{});
}

/// Records the uptime and repaints every 100 ms, until canceled.
fn tick() void {
    while (true) {
        fibers_io.sleep(.fromMilliseconds(100), .awake) catch |err| switch (err) {
            error.Canceled => return,
        };
        uptime_ms = start.untilNow(fibers_io, .awake).toMilliseconds();
        common.repaint();
    }
}

fn setGame(g: common.Game) void {
    game = g;
    common.repaint();
}

/// Puts a command for the controller. With `min` 0 a put never waits, as a window procedure
/// mustn't: it puts what fits, here nothing when the queue is full.
fn send(command: Command) void {
    const n = commands.putUncancelable(fibers_io, &.{command}, 0) catch unreachable; // never closed
    if (n == 0) std.debug.panic("the command queue is full (the controller stopped taking commands?)", .{});
}

fn windowProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            clicks += 1;
            const point = win32.pointFromLparam(lparam);
            std.log.info("click at ({d}, {d})", .{ point.x, point.y });
            if (game == .waiting) clicked.set(fibers_io);
        },
        win32.WM_KEYDOWN => switch (wparam) {
            @backingInt(win32.VK_SPACE) => send(.start_game),
            @backingInt(win32.VK_ESCAPE) => send(.cancel_game),
            'F' => common.fileTour(blocking_io) catch |err| std.debug.panic("file tour: {t}", .{err}),
            'W' => common.longWrite(blocking_io) catch |err| std.debug.panic("long write: {t}", .{err}),
            else => {},
        },
        win32.WM_DESTROY => {
            common.hwnd = null;
            win32.PostQuitMessage(0);
        },
        // Shows what the tasks recorded: in a modal loop, where no task runs, it all stands still.
        win32.WM_PAINT => {
            var bufs: [3][100]u8 = undefined;
            common.paint(hwnd, &(.{"One thread: this window's procedure and every task (fibers) share it."} ++ common.statusLines(&bufs, uptime_ms, clicks, game)));
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
const winio = @import("winio");
