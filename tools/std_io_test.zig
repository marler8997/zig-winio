//! Build tool: `std_io_test IN OUT [NAME REASON]...` rewrites std's own std.Io tests (IN, the
//! zig dependency's lib/std/Io/test.zig) to run on winio, into OUT:
//! - every `testing.io` / `std.testing.io` (std's Threaded) becomes `winio_test_io.io`;
//! - each test starts with `winio_test_io.init()`;
//! - each test NAME becomes a stub that skips, saying REASON (an operation winio doesn't
//!   implement yet). A NAME std doesn't have is an error, so the list can't go stale.

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 3) % 2 != 0) fatal("usage: std_io_test IN OUT [NAME REASON]...", .{});
    const skips = args[3..];
    const skip_found = try arena.alloc(bool, skips.len / 2);
    @memset(skip_found, false);

    const src = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .unlimited);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\//! GENERATED at build time by tools/std_io_test.zig from the zig dependency's
        \\//! lib/std/Io/test.zig: std's own tests of std.Io, run on a winio Io. Each `testing.io`
        \\//! (std's Threaded) is `winio_test_io.io`, each test starts with `winio_test_io.init()`,
        \\//! and the tests build.zig lists are skipped, saying why. Otherwise unchanged, so a failure
        \\//! here is winio differing from std.
        \\
        \\const winio_test_io = @import("winio_test_io");
        \\
        \\
    );
    var replaced: usize = 0;
    var skipping = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (skipping) {
            // std's tests end with a `}` alone at column 0.
            if (std.mem.eql(u8, line, "}")) skipping = false;
            continue;
        }
        if (!first) try w.writeByte('\n');
        first = false;
        if (testName(line)) |name| {
            if (skipReason(skips, skip_found, name)) |reason| {
                try w.print("test \"{s}\" {{\n    // winio: {s}\n    return error.SkipZigTest;\n}}", .{ name, reason });
                skipping = true;
                continue;
            }
            try w.print("{s}\n    winio_test_io.init();", .{line});
            continue;
        }
        replaced += try writeReplaced(w, line);
    }
    if (skipping) fatal("{s}: a skipped test has no closing '}}' at column 0", .{args[1]});
    if (replaced == 0) fatal("{s}: no testing.io to replace: has std's test file changed?", .{args[1]});
    for (skip_found, 0..) |found, i| if (!found) fatal("{s}: build.zig skips test \"{s}\", which it doesn't have", .{ args[1], skips[i * 2] });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = out.written() });
}

/// The name of the test `line` starts (`test "NAME" {`), if it starts one.
fn testName(line: []const u8) ?[]const u8 {
    const prefix = "test \"";
    const suffix = "\" {";
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, suffix)) return null;
    return line[prefix.len .. line.len - suffix.len];
}

fn skipReason(skips: []const [:0]const u8, found: []bool, name: []const u8) ?[]const u8 {
    for (found, 0..) |*f, i| if (std.mem.eql(u8, skips[i * 2], name)) {
        f.* = true;
        return skips[i * 2 + 1];
    };
    return null;
}

/// Writes `line` with each `testing.io` (or `std.testing.io`) that is the whole name replaced:
/// how many.
fn writeReplaced(w: *std.Io.Writer, line: []const u8) error{WriteFailed}!usize {
    const name = "testing.io";
    var n: usize = 0;
    var pos: usize = 0;
    var search: usize = 0;
    while (std.mem.findPos(u8, line, search, name)) |i| {
        const end = i + name.len;
        search = end;
        // Not `testing.io_instance` or `mytesting.io`.
        if (end < line.len and isIdentifier(line[end])) continue;
        const start = if (i >= 4 and std.mem.eql(u8, line[i - 4 .. i], "std.")) i - 4 else i;
        if (start > 0 and (isIdentifier(line[start - 1]) or line[start - 1] == '.')) continue;
        try w.writeAll(line[pos..start]);
        try w.writeAll("winio_test_io.io");
        pos = end;
        n += 1;
    }
    try w.writeAll(line[pos..]);
    return n;
}

fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("std_io_test: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const std = @import("std");
