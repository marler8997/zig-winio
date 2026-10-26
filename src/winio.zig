//! std.Io implementations for Windows.

/// Tasks (fibers), futexes and time on one thread, nothing that blocks; a `Fibers.Layer` adds the
/// rest by forwarding it to a blocking Io (such as a std.Io.Threaded). The thread's own waits run
/// the tasks; on a thread with windows, `Fibers.runMessageLoop` runs them between window messages.
pub const Fibers = @import("Fibers.zig");

/// For a thread without a message loop: tasks are fibers on the thread, and one wait on an I/O
/// completion port covers everything they wait for.
pub const Iocp = @import("Iocp.zig");
