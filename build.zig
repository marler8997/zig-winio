pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows } });
    const optimize = b.standardOptimizeOption(.{});
    const winio = b.addModule("winio", .{ .root_source_file = b.path("src/winio.zig") });
    // zigwin32 is lazy: a program with its own sets `external_win32` and adds it, so only one
    // is fetched and compiled.
    const external_win32 = b.option(
        bool,
        "external_win32",
        "Don't fetch zigwin32: the dependent gives winio its own (`module(\"winio\").addImport(\"win32\", ...)`)",
    ) orelse false;
    if (!external_win32) if (b.lazyDependency("win32", .{})) |dep| winio.addImport("win32", dep.module("win32"));

    // The tests need the zig repository (std's own std.Io tests), a lazy dependency fetched only
    // with -Dtest, so packages that depend on winio never fetch it.
    const test_step = b.step("test", "Run the tests (needs -Dtest)");
    const enable_tests = b.option(bool, "test", "Enable the test step (fetches the zig repository, for std's own std.Io tests)") orelse false;
    if (!enable_tests) {
        test_step.dependOn(&b.addFail("the test step needs -Dtest: it fetches the zig repository, for std's own std.Io tests").step);
        return;
    }
    const win32 = (b.lazyDependency("win32", .{}) orelse return).module("win32");

    // Runs one thing that must panic; the tests check what it printed. Single-threaded: some
    // cases are deadlocks winio can only tell when no other thread could end the wait.
    const panic_case = b.addExecutable(.{
        .name = "panic_case",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/panic_case.zig"),
            .target = target,
            // Collapse fast/small to safe: it tests for unreachables, so runtime safety is required.
            .optimize = switch (optimize) {
                .debug => .debug,
                .safe, .fast, .small => .safe,
            },
            .single_threaded = true,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        }),
    });
    // A child process for the tests to spawn.
    const child = b.addExecutable(.{
        .name = "child",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/child.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("panic_case", panic_case.getEmittedBin());
    test_options.addOptionPath("child", child.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32 },
                .{ .name = "test_options", .module = test_options.createModule() },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // std's own std.Io tests, rewritten (tools/std_io_test.zig) to run on a winio Io: once on an
    // Iocp, once on Fibers layered over a single-threaded std.Io.Threaded.
    const zig = b.lazyDependency("zig", .{ .@"version-string" = "0.17.0" }) orelse return;
    const rewriter = b.addExecutable(.{
        .name = "std_io_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/std_io_test.zig"),
            .target = b.graph.host,
        }),
    });
    for ([_]StdIoTestRun{
        .{ .name = "std_io_test_iocp", .io = "src/std_io_test_io.zig", .skips = &std_io_test_iocp_skips },
        .{ .name = "std_io_test_fibers", .io = "src/std_io_test_fibers_io.zig", .skips = &std_io_test_fibers_skips },
    }) |run| {
        const rewrite = b.addRunArtifact(rewriter);
        rewrite.addFileArg(zig.path("lib/std/Io/test.zig"));
        const std_io_test = rewrite.addOutputFileArg(b.fmt("{s}.zig", .{run.name}));
        for (run.skips) |skip| rewrite.addArgs(&skip);
        const std_tests = b.addTest(.{
            .name = run.name,
            .root_module = b.createModule(.{
                .root_source_file = std_io_test,
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "winio_test_io", .module = b.createModule(.{
                    .root_source_file = b.path(run.io),
                    .imports = &.{.{ .name = "win32", .module = win32 }},
                }) }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(std_tests).step);
    }
}

/// One run of std's std.Io tests on a winio Io: `io` is the file providing it (`winio_test_io`).
const StdIoTestRun = struct { name: []const u8, io: []const u8, skips: []const [2][]const u8 };

/// std's std.Io tests that need what winio doesn't implement yet: each is skipped, saying why.
/// Remove a test from here once winio implements what it needs. A name std no longer has fails
/// the build (`tools/std_io_test.zig`).
const std_io_test_iocp_skips = [_][2][]const u8{
    .{ "Group", "Group isn't implemented" },
    .{ "Group.cancel", "Group isn't implemented" },
    .{ "Group.concurrent", "Group isn't implemented" },
    .{ "Group materializes error.Cancel", "Group isn't implemented" },
    .{ "Group task receives cancelation unknowingly", "Group isn't implemented" },
    .{ "tasks spawned in group after Group.cancel are canceled", "Group isn't implemented" },
    .{ "Select", "Select needs Group, which isn't implemented" },
    .{ "Select with empty buffer, no deadlock", "Select needs Group, which isn't implemented" },
};

/// The same for the Fibers run: only their own operations can be missing (files and the
/// rest are forwarded to std.Io.Threaded).
const std_io_test_fibers_skips = [_][2][]const u8{
    .{ "Group", "Group isn't implemented" },
    .{ "Group.cancel", "Group isn't implemented" },
    .{ "Group.concurrent", "Group isn't implemented" },
    .{ "Group materializes error.Cancel", "Group isn't implemented" },
    .{ "Group task receives cancelation unknowingly", "Group isn't implemented" },
    .{ "tasks spawned in group after Group.cancel are canceled", "Group isn't implemented" },
    .{ "Select", "Select needs Group, which isn't implemented" },
    .{ "Select with empty buffer, no deadlock", "Select needs Group, which isn't implemented" },
};

const std = @import("std");
