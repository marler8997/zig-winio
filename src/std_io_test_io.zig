//! The Io std's own tests (`std_io_test.zig`) run on: one winio Iocp for the test thread, made by
//! the first test (`init`, called first in each) and kept for the process (a thread has at most
//! one winio Io). `io` is a constant, as `std.testing.io` is: the tests use it from nested
//! functions.

var iocp: Iocp = undefined;
var initialized = false;

pub const io: std.Io = .{ .userdata = &iocp.scheduler, .vtable = &Iocp.vtable };

pub fn init() void {
    if (initialized) return;
    iocp.init(std.heap.page_allocator, .{});
    initialized = true;
}

const std = @import("std");
const Iocp = @import("Iocp.zig");
