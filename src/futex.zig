//! std.Io's futex for every thread in the process: a wait on any winio thread (or a plain one) is
//! ended by a wake from any other. A parking lot: waiters (`tasks.Waiter`, which live where their
//! fiber is parked) queue in a bucket hashed from the address, under the bucket's lock.
//!
//! A waiter enqueues only if the word still holds the expected value, checked under the lock; a
//! waker changes the word first and then takes the lock, so a wake can't fall between the check
//! and the enqueue. A wake marks the waiter woken and nudges its thread (`tasks.Notify`), all
//! under the lock: a waiter leaves (`leave`) under the lock too, so it's never touched after.

const bucket_count = 256;

const Bucket = struct {
    lock: win32.RTL_SRWLOCK = .{ .Ptr = null },
    head: ?*tasks.Waiter = null,
    tail: ?*tasks.Waiter = null,
};

var buckets: [bucket_count]Bucket = @splat(.{});

fn bucketOf(ptr: *const u32) *Bucket {
    // Fibonacci hashing of the word's address (4-byte aligned).
    const hash = (@intFromPtr(ptr) >> 2) *% 0x9E3779B97F4A7C15;
    return &buckets[hash >> (64 - @ctz(@as(usize, bucket_count)))];
}

/// Queues `w` (waiting on a futex) unless its word no longer holds the expected value: whether it
/// was queued. A queued waiter must `leave` once its wait is over, however it ended.
pub fn enqueue(w: *tasks.Waiter) bool {
    const f = w.wait.futex;
    const b = bucketOf(f.ptr);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    if (@atomicLoad(u32, f.ptr, .monotonic) != f.expected) return false;
    w.prev = b.tail;
    w.next = null;
    if (b.tail) |t| t.next = w else b.head = w;
    b.tail = w;
    w.queued = true;
    return true;
}

/// Takes `w` out of its queue, if a wake hasn't already.
pub fn leave(w: *tasks.Waiter) void {
    const b = bucketOf(w.wait.futex.ptr);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    if (w.queued) unlink(b, w);
}

fn unlink(b: *Bucket, w: *tasks.Waiter) void {
    if (w.prev) |p| p.next = w.next else b.head = w.next;
    if (w.next) |n| n.prev = w.prev else b.tail = w.prev;
    w.queued = false;
}

/// Wakes up to `max` waiters on `ptr`, oldest first.
pub fn wake(ptr: *const u32, max: u32) void {
    if (max == 0) return;
    const b = bucketOf(ptr);
    win32.AcquireSRWLockExclusive(&b.lock);
    defer win32.ReleaseSRWLockExclusive(&b.lock);
    var left = max;
    var next = b.head;
    while (next) |w| {
        if (left == 0) break;
        next = w.next;
        if (w.wait.futex.ptr != ptr) continue;
        unlink(b, w);
        @atomicStore(u32, &w.woken, 1, .release);
        w.notify.nudge(&w.woken);
        left -= 1;
    }
}

const std = @import("std");
const tasks = @import("tasks.zig");
const win32 = @import("win32").everything;
