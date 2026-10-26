//! The Io std's own tests (`std_io_test.zig`, the Fibers run) run on: one winio.Fibers, through a
//! Layer over a single-threaded std.Io.Threaded (the tests use files too), kept for the process (a thread has at most one winio
//! Io). The test thread becomes its by starting the first task; every wait runs the tasks. `io`
//! is a constant, as `std.testing.io` is: the tests use it from nested functions.

var threaded: std.Io.Threaded = .init_single_threaded;
var fibers: Fibers = .init(std.heap.page_allocator);
var layer: Fibers.Layer = .{ .base = &fibers, .inner = threaded.io() };

pub const io = layer.io();

/// Called first in each test (the rewrite adds it); the Fibers need nothing.
pub fn init() void {}

const std = @import("std");
const Fibers = @import("Fibers.zig");
