//! The Iocp's file calls: opening files overlapped, buffers for one NtReadFile/NtWriteFile, and
//! std's mapping of their statuses to errors. Paths are WTF-8, relative to a `Dir` handle or
//! absolute, converted as std does (`std.Io.Threaded.sliceToPrefixedFileW`).

/// Creates `sub_path`, opened overlapped, as std.Io.Threaded's dirCreateFile does otherwise.
/// Blocks the thread while NtCreateFile runs; `io` sleeps between retries (`open`).
pub fn createFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    if (options.lock != .none) std.debug.panic("winio.Iocp: file locks aren't implemented", .{});
    if (options.permissions != .default_file) std.debug.panic("winio.Iocp: file permissions aren't implemented", .{});
    return open(io, dir, sub_path, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .WRITE = true, .READ = options.read },
    }, if (options.exclusive) .CREATE else if (options.truncate) .OVERWRITE_IF else .OPEN_IF, .{ .NON_DIRECTORY_FILE = true, .IO = .ASYNCHRONOUS });
}

/// Opens `sub_path` overlapped, as std.Io.Threaded's dirOpenFile does otherwise (`allow_directory`,
/// `follow_symlinks`; std on Windows ignores the rest). Blocks the thread while NtCreateFile
/// runs; `io` sleeps between retries (`open`).
pub fn openFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    if (options.lock != .none) std.debug.panic("winio.Iocp: file locks aren't implemented", .{});
    const allow_directory = options.allow_directory and !options.isWrite();
    if (!allow_directory and (std.mem.eql(u8, sub_path, ".") or std.mem.eql(u8, sub_path, ".."))) return error.IsDir;
    return open(io, dir, sub_path, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .READ = options.isRead(), .WRITE = options.isWrite() },
    }, .OPEN, .{ .NON_DIRECTORY_FILE = !allow_directory, .OPEN_REPARSE_POINT = !options.follow_symlinks, .IO = .ASYNCHRONOUS });
}

/// NtCreateFile with std's statuses, and std's retries of SHARING_VIOLATION (a kernel bug: given
/// for a while after a running executable is closed) and DELETE_PENDING (a file deleted, the
/// deletion not finished): 13 tries, 0 ms, 1 ms, 2 ms ... apart (as std; about 4 s in all),
/// sleeping through `io` so other tasks run meanwhile.
fn open(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, access: windows.ACCESS_MASK, disposition: windows.FILE.CREATE_DISPOSITION, file_options: windows.FILE.MODE) std.Io.File.OpenError!std.Io.File {
    const path = try std.Io.Threaded.sliceToPrefixedFileW(dir.handle, sub_path, .{});
    var name: windows.UNICODE_STRING = .init(path.span());
    var attempt: u5 = 0;
    while (true) {
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        var handle: windows.HANDLE = undefined;
        switch (windows.ntdll.NtCreateFile(
            &handle,
            access,
            &.{ .RootDirectory = if (std.Io.Dir.path.isAbsoluteWindowsWtf16(path.span())) null else dir.handle, .ObjectName = &name },
            &iosb,
            null,
            .{ .NORMAL = true },
            .VALID_FLAGS,
            disposition,
            file_options,
            null,
            0,
        )) {
            .SUCCESS => return .{ .handle = handle, .flags = .{ .nonblocking = true } },
            .SHARING_VIOLATION, .DELETE_PENDING => {
                if (attempt == max_kernel_bug_retries) return error.FileBusy;
                try io.sleep(.fromMilliseconds((@as(u32, 1) << attempt) >> 1), .awake);
                attempt += 1;
            },
            // As std: what ended it was a cancelation; if it isn't this task's, it tries again.
            .CANCELLED => try io.checkCancel(),
            .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
            .ACCESS_DENIED, .USER_MAPPED_FILE => return error.AccessDenied,
            .FILE_IS_A_DIRECTORY => return error.IsDir,
            .NOT_A_DIRECTORY => return error.NotDir,
            .PIPE_BUSY => return error.PipeBusy,
            .NO_MEDIA_IN_DEVICE, .PIPE_NOT_AVAILABLE => return error.NoDevice,
            .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
            .DISK_FULL => return error.NoSpaceLeft,
            // \\server not found, or \\server\share not found.
            .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
            else => |status| return windows.unexpectedStatus(status),
        }
    }
}

/// As std.Io.Threaded's `max_windows_kernel_bug_retries`.
const max_kernel_bug_retries = 13;

/// Whether `file` is a file on a disk (not a pipe, console or other device).
pub fn isDisk(file: std.Io.File) bool {
    return switch (win32.GetFileType(file.handle)) {
        .DISK => true,
        .UNKNOWN => switch (win32.GetLastError()) {
            .NO_ERROR => false,
            else => |err| win32.panicWin32("GetFileType", err),
        },
        else => false,
    };
}

/// The first buffer of a read with room in it, cut to what one call can read; null if none has.
pub fn readBuffer(data: []const []u8) ?[]u8 {
    for (data) |d| if (d.len > 0) return d[0..std.math.lossyCast(u32, d.len)];
    return null;
}

/// The first part of a write that has bytes in it, cut to what one call can write.
pub fn writeBuffer(header: []const u8, data: []const []const u8, splat: usize) []const u8 {
    const buffer = b: {
        if (header.len != 0) break :b header;
        for (data[0 .. data.len - 1]) |d| if (d.len != 0) break :b d;
        if (splat == 0) return &.{};
        break :b data[data.len - 1];
    };
    return buffer[0..std.math.lossyCast(u32, buffer.len)];
}

/// A read's result from its status, and the bytes read: std's mapping (Threaded's
/// ntReadFileResult). CANCELLED is the caller's (error.Canceled, or a batch's unused operation).
pub fn readResult(status: windows.NTSTATUS, n: usize) error{ EndOfStream, NotOpenForReading, IsDir, LockViolation, AccessDenied, Unexpected }!usize {
    return switch (status) {
        .SUCCESS => n,
        // The end, or the other end closed.
        .END_OF_FILE, .PIPE_BROKEN, .PIPE_CLOSING => error.EndOfStream,
        .INVALID_HANDLE => error.NotOpenForReading,
        .INVALID_DEVICE_REQUEST => error.IsDir,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        else => windows.unexpectedStatus(status),
    };
}

/// A write's result from its status, and the bytes written: std's mapping (Threaded's
/// ntWriteFileResult). CANCELLED is the caller's.
pub fn writeResult(status: windows.NTSTATUS, n: usize) error{ SystemResources, BrokenPipe, NotOpenForWriting, LockViolation, AccessDenied, NoSpaceLeft, Unexpected }!usize {
    return switch (status) {
        .SUCCESS => n,
        .INVALID_USER_BUFFER, .NO_MEMORY, .QUOTA_EXCEEDED, .WORKING_SET_QUOTA => error.SystemResources,
        // The other end closed.
        .PIPE_BROKEN, .PIPE_CLOSING => error.BrokenPipe,
        .INVALID_HANDLE => error.NotOpenForWriting,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        .DISK_FULL => error.NoSpaceLeft,
        else => windows.unexpectedStatus(status),
    };
}

const std = @import("std");
const win32 = @import("win32").everything;
const windows = std.os.windows;
