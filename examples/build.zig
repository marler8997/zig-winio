//! winio's examples, a package of their own that depends on winio as any program would. From
//! this directory: `zig build run-gamefibers`, or `zig build run-gameplain` for the same program
//! without winio, for comparison.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows } });
    const optimize = b.standardOptimizeOption(.{});
    // winio uses this program's zigwin32 rather than fetching its own.
    const win32 = b.dependency("win32", .{}).module("win32");
    const winio = b.dependency("winio", .{ .external_win32 = true }).module("winio");
    winio.addImport("win32", win32);

    for ([_][]const u8{ "gamefibers", "gameplain" }) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            // One thread: the window procedures (and gamefibers's tasks) share it.
            .single_threaded = true,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        });
        if (std.mem.eql(u8, name, "gamefibers")) module.addImport("winio", winio);
        const exe = b.addExecutable(.{ .name = name, .root_module = module });
        // A GUI program: no console. crash.zig makes stderr a log file when it starts without one.
        exe.subsystem = .windows;
        b.installArtifact(exe);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&b.addRunArtifact(exe).step);
    }
}

const std = @import("std");
