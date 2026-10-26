//! Starting a child process (std.Io's processSpawn), adapted from std's `processSpawnWindows`
//! (std/Io/Threaded.zig). The executable is found the same way (relative to the cwd, then along
//! PATH, trying PATHEXT's extensions) and argv is quoted the same way, with cmd.exe's own rules
//! for .bat and .cmd scripts (std's mitigation of BatBadBut). What differs: winio's end of each
//! pipe is overlapped (`flags.nonblocking`), for a completion port; a `.file` the child writes
//! may be reopened append-only (`FileWrites`); unexpected statuses panic; the options winio
//! doesn't implement panic.
//!
//! The child's environment, without `environ_map`, is this process's, without ZIG_PROGRESS (as
//! std does): progress needs a pipe winio doesn't make.

/// How a child writes a `.file` given as its stdout or stderr. It gets the file opened again (it
/// can't share an overlapped handle), with a position of its own.
pub const FileWrites = enum {
    /// From the start, overwriting: as std.Io.Threaded.
    from_start,
    /// Every write at the file's end, wherever another writer left it (append-only access, as a
    /// shell's `>>`): children sharing a log don't overwrite each other.
    append,
};

/// Which handles a child inherits.
pub const Inheritance = enum {
    /// Every handle inheritable when it's created: as std.Io.Threaded. Its own (its pipes, its
    /// `.file`s) are inheritable only while winio spawns it, and winio's spawns take turns; but
    /// another Io spawning meanwhile (a std.Io.Threaded) can give its child one of them, and a
    /// pipe end held by that child keeps this child's reads from ending until it exits.
    all_inheritable,
    /// Only its own: its std handles, `inherit_files` and `inherit_dirs`
    /// (PROC_THREAD_ATTRIBUTE_HANDLE_LIST). A child of another Io can still inherit this one's
    /// handles while it's spawned, but this one never inherits another's.
    listed,
};

pub fn spawn(
    gpa: std.mem.Allocator,
    options: std.process.SpawnOptions,
    file_writes: FileWrites,
    inheritance: Inheritance,
) std.process.SpawnError!std.process.Child {
    if (options.progress_node.index != .none) std.debug.panic("winio: spawning with a progress node isn't implemented", .{});
    if (options.expand_arg0 != .no_expand) std.debug.panic("winio: spawning with expand_arg0 isn't implemented", .{});
    if (options.uid != null or options.gid != null or options.pgid != null) std.debug.panic("winio: spawning with a uid, gid or pgid: they have no meaning on Windows", .{});

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd_w: ?[:0]u16 = switch (options.cwd) {
        .inherit => null,
        .dir => |cwd_dir| cwd: {
            const buf = try arena.alloc(u16, windows.PATH_MAX_WIDE + 1);
            const path = try std.Io.Threaded.GetFinalPathNameByHandle(cwd_dir.handle, .{}, buf[0..windows.PATH_MAX_WIDE]);
            buf[path.len] = 0;
            break :cwd buf[0..path.len :0];
        },
        .path => |cwd| try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd),
    };

    // An app name with a directory in it is split: the directory goes on the search directory,
    // as NtQueryDirectoryFile takes no separators in its file name. An absolute one's directory
    // is the whole search directory.
    var app_w_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const app_path_w: ?[]const u16, const app_dir_w: ?[]const u16, const app_name_w: []const u16 = app: {
        const path = switch (options.exe) {
            .detect, .search, .path => options.argv[0],
            .file => |file| {
                const path_w = try std.Io.Threaded.GetFinalPathNameByHandle(file.handle, .{}, &app_w_buf);
                var it: std.Io.Dir.path.ComponentIterator(.windows, u16) = .init(path_w);
                const base = it.last().?;
                break :app .{ null, if (it.previous()) |dir| dir.path else it.root(), base.name };
            },
            .explicit => |explicit| explicit.path,
        };
        break :app .{
            if (std.Io.Dir.path.isAbsolute(path)) null else switch (options.exe) {
                // As on POSIX, the child's cwd is where a relative executable is looked for.
                .detect, .search => cwd_w,
                .path => |dir| try std.Io.Threaded.GetFinalPathNameByHandle(dir.handle, .{}, &app_w_buf),
                .file => unreachable,
                .explicit => |explicit| try std.Io.Threaded.GetFinalPathNameByHandle(explicit.dir.handle, .{}, &app_w_buf),
            },
            if (std.Io.Dir.path.dirname(path)) |dir| try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir) else null,
            try std.unicode.wtf8ToWtf16LeAllocZ(arena, std.Io.Dir.path.basename(path)),
        };
    };

    var flags: windows.CreateProcessFlags = .{
        .create_suspended = options.start_suspended,
        .create_unicode_environment = true,
        .create_no_window = options.create_no_window,
    };

    // From the inheritable handles to CreateProcessW: another thread's child spawned meanwhile
    // would inherit them too (std holds a mutex for this). Short, so the thread just blocks.
    win32.AcquireSRWLockExclusive(&spawn_lock);
    defer win32.ReleaseSRWLockExclusive(&spawn_lock);

    const nul = if (options.stdin == .ignore or options.stdout == .ignore or options.stderr == .ignore) try openNul() else undefined;
    defer if (options.stdin == .ignore or options.stdout == .ignore or options.stderr == .ignore) windows.CloseHandle(nul);

    const any_pipe = options.stdin == .pipe or options.stdout == .pipe or options.stderr == .pipe;
    const pipe_device = if (any_pipe) try openNamedPipeDevice() else undefined;
    defer if (any_pipe) windows.CloseHandle(pipe_device);
    // Each: winio's end (overlapped, returned), then the child's (inheritable, synchronous,
    // closed here once the child has it, or on failure).
    const stdin_pipe = if (options.stdin == .pipe) try createPipe(pipe_device, .outbound) else undefined;
    errdefer if (options.stdin == .pipe) windows.CloseHandle(stdin_pipe[0]);
    defer if (options.stdin == .pipe) windows.CloseHandle(stdin_pipe[1]);
    const stdout_pipe = if (options.stdout == .pipe) try createPipe(pipe_device, .inbound) else undefined;
    errdefer if (options.stdout == .pipe) windows.CloseHandle(stdout_pipe[0]);
    defer if (options.stdout == .pipe) windows.CloseHandle(stdout_pipe[1]);
    const stderr_pipe = if (options.stderr == .pipe) try createPipe(pipe_device, .inbound) else undefined;
    errdefer if (options.stderr == .pipe) windows.CloseHandle(stderr_pipe[0]);
    defer if (options.stderr == .pipe) windows.CloseHandle(stderr_pipe[1]);

    // Inheritable for CreateProcessW only.
    // Undone however far setting got (as std: an undo that fails has reported itself).
    defer for (options.inherit_dirs) |dir| setInherit(dir.handle, false) catch {};
    for (options.inherit_dirs) |dir| try setInherit(dir.handle, true);
    defer for (options.inherit_files) |file| setInherit(file.handle, false) catch {};
    for (options.inherit_files) |file| try setInherit(file.handle, true);

    // `.file`s, opened again for the child: closed here once the child has them, or on failure.
    const read: windows.ACCESS_MASK = .{ .STANDARD = .{ .SYNCHRONIZE = true }, .GENERIC = .{ .READ = true } };
    const write: windows.ACCESS_MASK = switch (file_writes) {
        .from_start => .{ .STANDARD = .{ .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true } },
        // GENERIC_WRITE without WRITE_DATA.
        .append => .{ .STANDARD = .{ .RIGHTS = .WRITE, .SYNCHRONIZE = true }, .SPECIFIC = .{ .FILE = .{ .APPEND_DATA = true, .WRITE_ATTRIBUTES = true, .WRITE_EA = true } } },
    };
    const stdin_file = if (options.stdin == .file) try reopenInheritable(options.stdin.file, read) else undefined;
    defer if (options.stdin == .file) windows.CloseHandle(stdin_file);
    const stdout_file = if (options.stdout == .file) try reopenInheritable(options.stdout.file, write) else undefined;
    defer if (options.stdout == .file) windows.CloseHandle(stdout_file);
    const stderr_file = if (options.stderr == .file) try reopenInheritable(options.stderr.file, write) else undefined;
    defer if (options.stderr == .file) windows.CloseHandle(stderr_file);

    const peb = windows.peb();
    var startup_full: Startup = .{ .ex = .{ .info = .{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .hStdInput = switch (options.stdin) {
            .inherit => peb.ProcessParameters.hStdInput,
            .file => stdin_file,
            .ignore => nul,
            .pipe => stdin_pipe[1],
            .close => null,
        },
        .hStdOutput = switch (options.stdout) {
            .inherit => peb.ProcessParameters.hStdOutput,
            .file => stdout_file,
            .ignore => nul,
            .pipe => stdout_pipe[1],
            .close => null,
        },
        .hStdError = switch (options.stderr) {
            .inherit => peb.ProcessParameters.hStdError,
            .file => stderr_file,
            .ignore => nul,
            .pipe => stderr_pipe[1],
            .close => null,
        },
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
    }, .attribute_list = null }, .inherit = .TRUE };
    const startup = &startup_full.ex.info;

    // `.listed`: only its own handles; with none, nothing.
    var inherited: std.ArrayList(windows.HANDLE) = .empty;
    if (inheritance == .listed) {
        for ([_]?windows.HANDLE{ startup.hStdInput, startup.hStdOutput, startup.hStdError }) |handle| try addInherited(arena, &inherited, handle);
        for (options.inherit_files) |file| try addInherited(arena, &inherited, file.handle);
        for (options.inherit_dirs) |dir| try addInherited(arena, &inherited, dir.handle);
        if (inherited.items.len == 0) startup_full.inherit = .FALSE;
    }
    if (inherited.items.len > 0) {
        var size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &size);
        const list = try arena.alignedAlloc(u8, .of(usize), size);
        if (0 == win32.InitializeProcThreadAttributeList(list.ptr, 1, 0, &size)) return windows.unexpectedError(windows.GetLastError());
        if (0 == win32.UpdateProcThreadAttribute(list.ptr, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @ptrCast(inherited.items.ptr), inherited.items.len * @sizeOf(windows.HANDLE), null, null)) {
            win32.DeleteProcThreadAttributeList(list.ptr);
            return windows.unexpectedError(windows.GetLastError());
        }
        startup_full.ex.attribute_list = list.ptr;
        startup.cb = @sizeOf(StartupInfoEx);
        flags.extended_startupinfo_present = true;
    }
    defer if (startup_full.ex.attribute_list) |list| win32.DeleteProcThreadAttributeList(list);

    // Without ZIG_PROGRESS: removed (INVALID_HANDLE_VALUE), as no progress pipe is made.
    const env_block = if (options.environ_map) |map|
        try map.createWindowsBlock(arena, .{ .zig_progress_handle = windows.INVALID_HANDLE_VALUE })
    else
        try std.process.Environ.createWindowsBlock(.{ .block = .global }, arena, .{ .zig_progress_handle = windows.INVALID_HANDLE_VALUE });

    var info: windows.PROCESS.INFORMATION = undefined;
    run: {
        // Scanned each time: the PEB's environment pointer isn't stable.
        const env_strings: EnvironStrings = .scan();
        const PATH = env_strings.PATH orelse &[_:0]u16{};
        const PATHEXT = env_strings.PATHEXT orelse &[_:0]u16{};

        // Which command line (a .bat/.cmd script's is different) is known only once the
        // executable is found.
        var cmd_line_cache: CommandLineCache = .{ .allocator = arena, .argv = options.argv };

        var app_buf: std.ArrayList(u16) = .empty;
        try app_buf.appendSlice(arena, app_name_w);
        var dir_buf: std.ArrayList(u16) = .empty;
        if (app_path_w) |app_path| try dir_buf.appendSlice(arena, app_path);
        if (app_dir_w) |app_dir| {
            if (dir_buf.items.len > 0) try dir_buf.append(arena, std.Io.Dir.path.sep);
            try dir_buf.appendSlice(arena, app_dir);
        }

        const cwd_ptr = if (cwd_w) |cwd| cwd.ptr else null;
        // If nothing starts, the error is why the first directory didn't (as std).
        const first = try createProcessIn(arena, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, env_block, cwd_ptr, flags, &startup_full, &info);
        if (first == .started) break :run;
        // PATH is searched even when the cwd is absolute, as the given cwd is only where a
        // relative executable is looked for first.
        if (switch (options.exe) {
            // A directory in the app name rules out searching PATH.
            .detect => app_dir_w != null,
            // An absolute one needs no search.
            .search => app_path_w == null,
            .path, .file, .explicit => true,
        }) return notStarted(first);
        var it = std.mem.tokenizeScalar(u16, PATH, ';');
        while (it.next()) |search_path| {
            dir_buf.clearRetainingCapacity();
            try dir_buf.appendSlice(arena, search_path);
            if (try createProcessIn(arena, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, env_block, cwd_ptr, flags, &startup_full, &info) == .started) break :run;
        }
        return notStarted(first);
    }

    return .{
        .id = info.hProcess,
        .thread_handle = info.hThread,
        .stdin = if (options.stdin == .pipe) .{ .handle = stdin_pipe[0], .flags = .{ .nonblocking = true } } else null,
        .stdout = if (options.stdout == .pipe) .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = true } } else null,
        .stderr = if (options.stderr == .pipe) .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = true } } else null,
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
    };
}

/// Opens `file` again (the empty name relative to it), synchronous and inheritable, for a child.
/// STARTUPINFOEXW, with std's STARTUPINFOW (CreateProcessW takes a pointer to `info`).
const StartupInfoEx = extern struct {
    info: windows.STARTUPINFOW,
    attribute_list: ?*anyopaque,
};

/// What CreateProcessW is given about the child's handles.
const Startup = struct {
    ex: StartupInfoEx,
    inherit: windows.BOOL,
};

/// Adds `handle` to the handles the child inherits: once, and only an inheritable one (the
/// parent's own std handles needn't be; then the child gets their value, as before, unusable).
fn addInherited(arena: std.mem.Allocator, inherited: *std.ArrayList(windows.HANDLE), handle: ?windows.HANDLE) error{ OutOfMemory, Unexpected }!void {
    const h = handle orelse return;
    if (h == windows.INVALID_HANDLE_VALUE) return;
    for (inherited.items) |other| if (other == h) return;
    var info: u32 = 0;
    if (0 == win32.GetHandleInformation(h, &info)) return windows.unexpectedError(windows.GetLastError());
    if (info & @as(u32, @bitCast(win32.HANDLE_FLAG_INHERIT)) == 0) return;
    try inherited.append(arena, h);
}

/// A pipe can't be reopened (as std.Io.Threaded: error.NoDevice).
fn reopenInheritable(file: std.Io.File, access: windows.ACCESS_MASK) error{ AccessDenied, NoDevice, Unexpected }!windows.HANDLE {
    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var name: windows.UNICODE_STRING = .init(&.{});
    switch (windows.ntdll.NtCreateFile(&handle, access, &.{
        .RootDirectory = file.handle,
        .Attributes = .{ .INHERIT = true },
        .ObjectName = &name,
    }, &iosb, null, .{ .NORMAL = true }, .VALID_FLAGS, .OPEN, .{ .IO = .SYNCHRONOUS_NONALERT }, null, 0)) {
        .SUCCESS => return handle,
        .ACCESS_DENIED => return error.AccessDenied,
        .PIPE_NOT_AVAILABLE => return error.NoDevice,
        else => |status| return windows.unexpectedStatus(status),
    }
}

/// \Device\Null, inheritable: for `.ignore`.
fn openNul() std.Io.UnexpectedError!windows.HANDLE {
    return openDevice(&.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' }, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_DATA = true, .WRITE_DATA = true } },
    }, true);
}

/// \Device\NamedPipe\, where `createPipe` makes its pipes.
fn openNamedPipeDevice() std.Io.UnexpectedError!windows.HANDLE {
    return openDevice(&.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'a', 'm', 'e', 'd', 'P', 'i', 'p', 'e', '\\' }, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
    }, false);
}

fn openDevice(path: []const u16, access: windows.ACCESS_MASK, inherit: bool) std.Io.UnexpectedError!windows.HANDLE {
    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var name: windows.UNICODE_STRING = .init(path);
    switch (windows.ntdll.NtOpenFile(&handle, access, &.{ .Attributes = .{ .INHERIT = inherit }, .ObjectName = &name }, &iosb, .VALID_FLAGS, .{ .IO = .SYNCHRONOUS_NONALERT })) {
        .SUCCESS => return handle,
        else => |status| return windows.unexpectedStatus(status),
    }
}

/// An unnamed pipe: winio's end (overlapped) and the child's (inheritable, synchronous). The
/// data flows `inbound` (child to winio) or `outbound`.
fn createPipe(device: windows.HANDLE, direction: enum { inbound, outbound }) error{ SystemResources, Unexpected }![2]windows.HANDLE {
    const inbound = direction == .inbound;
    const quota = 4096;
    var server: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    // Two minutes, as std's.
    const default_timeout: windows.LARGE_INTEGER = -120 * std.time.ns_per_s / 100;
    switch (windows.ntdll.NtCreateNamedPipeFile(
        &server,
        .{ .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = inbound, .WRITE_DATA = !inbound, .WRITE_ATTRIBUTES = true } }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .RootDirectory = device, .Attributes = .{ .INHERIT = false } },
        &iosb,
        .{ .READ = true, .WRITE = true },
        .CREATE,
        .{ .IO = .ASYNCHRONOUS },
        .{ .TYPE = .BYTE_STREAM },
        .{ .MODE = .BYTE_STREAM },
        .{ .OPERATION = .QUEUE },
        1,
        if (inbound) quota else 0,
        if (inbound) 0 else quota,
        &default_timeout,
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    errdefer windows.CloseHandle(server);
    var client: windows.HANDLE = undefined;
    switch (windows.ntdll.NtOpenFile(
        &client,
        .{ .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = !inbound, .WRITE_DATA = inbound, .WRITE_ATTRIBUTES = true } }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .RootDirectory = server, .Attributes = .{ .INHERIT = true } },
        &iosb,
        .{ .READ = true, .WRITE = true },
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    return .{ server, client };
}

fn setInherit(handle: windows.HANDLE, inherit: bool) std.Io.UnexpectedError!void {
    switch (windows.ntdll.NtSetInformationObject(handle, .HandleFlag, &windows.OBJECT.HANDLE_FLAG{ .INHERIT = inherit }, @sizeOf(windows.OBJECT.HANDLE_FLAG))) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
}

/// PATH and PATHEXT from this process's environment.
const EnvironStrings = struct {
    PATH: ?[:0]const u16 = null,
    PATHEXT: ?[:0]const u16 = null,

    fn scan() EnvironStrings {
        const peb = windows.peb();
        std.debug.assert(windows.ntdll.RtlEnterCriticalSection(peb.FastPebLock) == .SUCCESS);
        defer std.debug.assert(windows.ntdll.RtlLeaveCriticalSection(peb.FastPebLock) == .SUCCESS);
        const ptr = peb.ProcessParameters.Environment;
        var result: EnvironStrings = .{};
        var i: usize = 0;
        while (ptr[i] != 0) {
            const key_start = i;
            // Some special variables start with '=', which isn't their separator.
            // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
            if (ptr[key_start] == '=') i += 1;
            while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
            const key_w = ptr[key_start..i];
            if (ptr[i] == '=') i += 1;
            const value_start = i;
            while (ptr[i] != 0) : (i += 1) {}
            const value_w = ptr[value_start..i :0];
            i += 1;
            inline for (@typeInfo(EnvironStrings).@"struct".field_names) |field_name| {
                if (windows.eqlIgnoreCaseWtf16(key_w, comptime std.unicode.wtf8ToWtf16LeStringLiteral(field_name))) @field(result, field_name) = value_w;
            }
        }
        return result;
    }
};

/// What trying the executable in one directory (or one candidate there) came to. Anything but
/// `started` means the search goes on to the next directory.
const Tried = enum {
    started,
    /// Nothing there by that name (or the directory can't be opened).
    not_found,
    access_denied,
    /// There, but not something CreateProcessW can run.
    invalid_exe,
};

/// What ends the search, and the spawn: an error no other directory could make right, or one
/// that must not decide which file runs (as std).
const SearchError = error{
    OutOfMemory,
    InvalidWtf8,
    InvalidBatchScriptArg,
    /// argv[0] has characters no executable's name can have.
    FileNotFound,
    /// A .exe that CreateProcessW can't run: std doesn't look further.
    InvalidExe,
    InvalidName,
    NameTooLong,
    BadPathName,
    FileBusy,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || std.Io.Cancelable || std.Io.UnexpectedError;

/// The error for a search that started nothing, from what the first directory came to.
fn notStarted(first: Tried) std.process.SpawnError {
    return switch (first) {
        .started => unreachable, // a search that started something returned
        .not_found => error.FileNotFound,
        .access_denied => error.AccessDenied,
        .invalid_exe => error.InvalidExe,
    };
}

/// Tries the executable `app_buf` in the directory `dir_buf` as it is and with each PATHEXT
/// extension that exists there, and starts the first that works.
///
/// It avoids CreateProcessW for names that don't exist: one wildcard query (`<app name>*`) of
/// the directory finds every candidate, so a directory with none costs an open, a query and a
/// close.
fn createProcessIn(
    arena: std.mem.Allocator,
    dir_buf: *std.ArrayList(u16),
    app_buf: *std.ArrayList(u16),
    pathext: [:0]const u16,
    cmd_line_cache: *CommandLineCache,
    env_block: std.process.Environ.WindowsBlock,
    cwd_ptr: ?[*:0]u16,
    flags: windows.CreateProcessFlags,
    startup: *Startup,
    info: *windows.PROCESS.INFORMATION,
) SearchError!Tried {
    const app_name_len = app_buf.items.len;
    const dir_path_len = dir_buf.items.len;
    if (app_name_len == 0) return .not_found;
    defer app_buf.shrinkRetainingCapacity(app_name_len);
    defer dir_buf.shrinkRetainingCapacity(dir_path_len);

    const dir = dir: {
        try dir_buf.append(arena, 0);
        defer dir_buf.shrinkRetainingCapacity(dir_path_len);
        const prefixed = std.Io.Threaded.wToPrefixedFileW(null, dir_buf.items[0 .. dir_buf.items.len - 1 :0], .{}) catch |err| switch (err) {
            error.FileNotFound => return .not_found,
            error.AccessDenied => return .access_denied,
            else => |e| return e,
        };
        // A directory that can't be opened can't hold the executable; the other errors (as
        // std) must not decide which file runs.
        break :dir std.Io.Threaded.dirOpenDirWindows(.cwd(), prefixed.span(), .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled, error.SystemResources, error.Unexpected, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => |e| return e,
            error.AccessDenied, error.PermissionDenied, error.SymLinkLoop, error.FileNotFound, error.NotDir, error.NoDevice, error.NetworkNotFound, error.NameTooLong, error.BadPathName => return .not_found,
        };
    };
    defer windows.CloseHandle(dir.handle);

    try app_buf.append(arena, '*');
    try app_buf.append(arena, 0);
    const app_name_wildcard = app_buf.items[0 .. app_buf.items.len - 1 :0];

    // Room for several entries a query; at least one of the longest.
    var info_buf: [2048]u8 align(@alignOf(windows.FILE_DIRECTORY_INFORMATION)) = undefined;
    comptime std.debug.assert(info_buf.len >= @sizeOf(windows.FILE_DIRECTORY_INFORMATION) + windows.NAME_MAX * 2);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var pathext_seen: [@typeInfo(std.process.WindowsExtension).@"enum".field_names.len]bool = @splat(false);
    var any_pathext_seen = false;
    var unappended_exists = false;
    // Every match first: the order is the file system's (FAT32 can list `blah.exe.obj` before
    // `blah.exe`).
    while (true) {
        var wildcard: windows.UNICODE_STRING = .init(app_name_wildcard);
        switch (windows.ntdll.NtQueryDirectoryFile(dir.handle, null, null, null, &iosb, &info_buf, info_buf.len, .Directory, .FALSE, &wildcard, .FALSE)) {
            .SUCCESS => {},
            // Nothing by that name, with or without an extension.
            .NO_SUCH_FILE => return .not_found,
            .NO_MORE_FILES => break,
            .ACCESS_DENIED => return .access_denied,
            else => |status| return windows.unexpectedStatus(status),
        }
        // Only with no room for one entry, which `info_buf` has.
        std.debug.assert(iosb.Information != 0);
        var it = windows.FileInformationIterator(windows.FILE_DIRECTORY_INFORMATION){ .buf = &info_buf };
        while (it.next()) |entry| {
            if (entry.FileAttributes.DIRECTORY) continue;
            const filename = @as([*]u16, @ptrCast(&entry.FileName))[0 .. entry.FileNameLength / 2];
            // All start with the app name (the wildcard): one as long is the app name itself.
            // It may still fail to start, so the extensions are tried after it.
            if (filename.len == app_name_len) {
                unappended_exists = true;
            } else if (supportedExtension(filename[app_name_len..])) |ext| {
                pathext_seen[@backingInt(ext)] = true;
                any_pathext_seen = true;
            }
        }
    }

    // The name as given; what it came to is this directory's answer unless an extension starts.
    const unappended: Tried = if (!unappended_exists) .not_found else unappended: {
        try appendSeparator(arena, dir_buf, dir_path_len);
        try dir_buf.appendSlice(arena, app_buf.items[0..app_name_len]);
        try dir_buf.append(arena, 0);
        const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];
        const app_name = app_buf.items[0..app_name_len];
        const ext: ?std.process.WindowsExtension = if (std.mem.findScalarLast(u16, app_name, '.')) |start| supportedExtension(app_name[start..]) else null;
        break :unappended try createProcessAs(cmd_line_cache, full_app_name, ext, env_block, cwd_ptr, flags, startup, info);
    };
    if (unappended == .started or !any_pathext_seen) return unappended;
    var ext_it = std.mem.tokenizeScalar(u16, pathext, ';');
    while (ext_it.next()) |ext_w| {
        const ext = supportedExtension(ext_w) orelse continue;
        if (!pathext_seen[@backingInt(ext)]) continue;
        dir_buf.shrinkRetainingCapacity(dir_path_len);
        try appendSeparator(arena, dir_buf, dir_path_len);
        try dir_buf.appendSlice(arena, app_buf.items[0..app_name_len]);
        try dir_buf.appendSlice(arena, ext_w);
        try dir_buf.append(arena, 0);
        const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];
        if (try createProcessAs(cmd_line_cache, full_app_name, ext, env_block, cwd_ptr, flags, startup, info) == .started) return .started;
    }
    return unappended;
}

fn appendSeparator(arena: std.mem.Allocator, dir_buf: *std.ArrayList(u16), dir_path_len: usize) error{OutOfMemory}!void {
    if (dir_path_len != 0) switch (dir_buf.items[dir_buf.items.len - 1]) {
        '/', '\\' => {},
        else => try dir_buf.append(arena, std.Io.Dir.path.sep),
    };
}

/// Starts `full_app_name` (extension `ext`): a .bat or .cmd script through cmd.exe, with its
/// quoting.
fn createProcessAs(
    cmd_line_cache: *CommandLineCache,
    full_app_name: [:0]u16,
    ext: ?std.process.WindowsExtension,
    env_block: std.process.Environ.WindowsBlock,
    cwd_ptr: ?[*:0]u16,
    flags: windows.CreateProcessFlags,
    startup: *Startup,
    info: *windows.PROCESS.INFORMATION,
) SearchError!Tried {
    const script = ext == .bat or ext == .cmd;
    const cmd_line = if (script) try cmd_line_cache.scriptCommandLine(full_app_name) else cmd_line_cache.commandLine() catch |err| switch (err) {
        error.InvalidArg0 => return error.FileNotFound,
        else => |e| return e,
    };
    const app = if (script) try cmd_line_cache.cmdExePath() else full_app_name;
    const tried = try createProcess(app.ptr, cmd_line.ptr, env_block, cwd_ptr, flags, startup, info);
    // A .exe that can't run ends the search (std); anything else that can't is skipped.
    if (tried == .invalid_exe and ext == .exe) return error.InvalidExe;
    return tried;
}

/// The extension (case-insensitive) if it's one CreateProcessW can run.
fn supportedExtension(ext: []const u16) ?std.process.WindowsExtension {
    if (ext.len != 4 or ext[0] != '.') return null;
    inline for (@typeInfo(std.process.WindowsExtension).@"enum".field_names) |name| {
        if (windows.eqlIgnoreCaseWtf16(ext[1..], comptime std.unicode.wtf8ToWtf16LeStringLiteral(name))) return @field(std.process.WindowsExtension, name);
    }
    return null;
}

fn createProcess(
    app_name: [*:0]u16,
    cmd_line: [*:0]u16,
    env_block: std.process.Environ.WindowsBlock,
    cwd_ptr: ?[*:0]u16,
    flags: windows.CreateProcessFlags,
    startup: *Startup,
    info: *windows.PROCESS.INFORMATION,
) error{ InvalidName, NameTooLong, FileBusy, SystemResources, Unexpected }!Tried {
    if (windows.kernel32.CreateProcessW(app_name, cmd_line, null, null, startup.inherit, flags, env_block.slice.ptr, cwd_ptr, &startup.ex.info, info).toBool()) return .started;
    switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .DIRECTORY => return .not_found,
        .ACCESS_DENIED => return .access_denied,
        .INVALID_NAME => return error.InvalidName,
        .FILENAME_EXCED_RANGE => return error.NameTooLong,
        .SHARING_VIOLATION => return error.FileBusy,
        .COMMITMENT_LIMIT => return error.SystemResources,
        // What the CRT maps to ENOEXEC (crt/src/dosmap.c, urt/misc/errno.cpp), and a text file
        // named .exe (EXE_MACHINE_TYPE_MISMATCH).
        .BAD_FORMAT,
        .INVALID_STARTING_CODESEG,
        .INVALID_STACKSEG,
        .INVALID_MODULETYPE,
        .INVALID_EXE_SIGNATURE,
        .EXE_MARKED_INVALID,
        .BAD_EXE_FORMAT,
        .ITERATED_DATA_EXCEEDS_64k,
        .INVALID_MINALLOCSIZE,
        .DYNLINK_FROM_INVALID_RING,
        .IOPL_NOT_ENABLED,
        .INVALID_SEGDPL,
        .AUTODATASEG_EXCEEDS_64k,
        .RING2SEG_MUST_BE_MOVABLE,
        .RELOC_CHAIN_XEEDS_SEGLIM,
        .INFLOOP_IN_RELOC_CHAIN,
        .EXE_MACHINE_TYPE_MISMATCH,
        => return .invalid_exe,
        else => |err| return windows.unexpectedError(err),
    }
}

/// argv as a command line, made when first needed: which kind (a script's differs) is known
/// only once the executable is found, and it's reused while PATH is searched.
const CommandLineCache = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cmd_line: ?[:0]u16 = null,
    cmd_exe_path: ?[:0]u16 = null,

    fn commandLine(c: *CommandLineCache) ![:0]u16 {
        if (c.cmd_line == null) c.cmd_line = try argvToCommandLine(c.allocator, c.argv);
        return c.cmd_line.?;
    }

    /// Not kept: the script's path changes as PATH is searched. `script_path` should be as full
    /// as can be, so cmd.exe doesn't search for it again.
    fn scriptCommandLine(c: *CommandLineCache, script_path: []const u16) ![:0]u16 {
        return argvToScriptCommandLine(c.allocator, script_path, c.argv[1..]);
    }

    fn cmdExePath(c: *CommandLineCache) error{OutOfMemory}![:0]u16 {
        if (c.cmd_exe_path == null) {
            const system_dir = std.mem.trimEnd(u16, windows.getSystemDirectoryWtf16Le(), &.{ '/', '\\' });
            const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\cmd.exe");
            const buf = try c.allocator.allocSentinel(u16, system_dir.len + suffix.len, 0);
            @memcpy(buf[0..system_dir.len], system_dir);
            @memcpy(buf[system_dir.len..], suffix);
            c.cmd_exe_path = buf;
        }
        return c.cmd_exe_path.?;
    }
};

/// argv (WTF-8) as a command line for `cmd.exe /c`, escaped by cmd.exe's rules: the mitigation
/// against arbitrary command execution from
/// https://flatt.tech/research/posts/batbadbut-you-cant-securely-execute-commands-on-windows/
/// Only for a .bat or .cmd script known to exist at `script_path` (relative: to the cwd).
fn argvToScriptCommandLine(
    allocator: std.mem.Allocator,
    script_path: []const u16,
    script_args: []const []const u8,
) error{ OutOfMemory, InvalidWtf8, InvalidBatchScriptArg }![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    // /d: no AutoRun commands. /e:ON and /v:OFF, as the mitigation needs: escaping % needs
    // command extensions, and delayed expansion must be off.
    try buf.appendSlice(allocator, "cmd.exe /d /e:ON /v:OFF /c \"");
    // Always quoted, and always with a separator, so cmd.exe doesn't search PATH for it. Not
    // escaped: the characters that matter can't be in a path, and the script exists.
    try buf.append(allocator, '"');
    if (std.mem.findAny(u16, script_path, &.{ '\\', '/' }) == null) try buf.appendSlice(allocator, ".\\");
    // At most 3 bytes a unit.
    try buf.ensureUnusedCapacity(allocator, 3 * script_path.len);
    buf.items.len += std.unicode.wtf16LeToWtf8(buf.unusedCapacitySlice(), script_path);
    try buf.append(allocator, '"');
    for (script_args) |arg| {
        // cmd.exe strips CR, and NUL or LF end the command: such an argument can't arrive
        // as given.
        if (std.mem.findAny(u8, arg, "\x00\r\n") != null) return error.InvalidBatchScriptArg;
        try buf.append(allocator, ' ');
        // Quoted when empty (it would be lost), when it ends in '\' (it would escape the
        // closing quote of "%~2"), or with anything not known to be safe.
        const needs_quotes = arg.len == 0 or arg[arg.len - 1] == '\\' or for (arg) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
                else => break true,
            }
        } else false;
        if (needs_quotes) try buf.append(allocator, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            switch (c) {
                '\\' => backslashes += 1,
                '"' => {
                    try buf.appendNTimes(allocator, '\\', backslashes);
                    try buf.append(allocator, '"');
                    backslashes = 0;
                },
                // `%` becomes `%%cd:~,%`: `%cd:~,%` is an empty substring of %cd% (always
                // set), so `%foo%` comes out as itself, not expanded.
                '%' => {
                    try buf.appendSlice(allocator, "%%cd:~,");
                    backslashes = 0;
                },
                else => backslashes = 0,
            }
            try buf.append(allocator, c);
        }
        if (needs_quotes) {
            try buf.appendNTimes(allocator, '\\', backslashes);
            try buf.append(allocator, '"');
        }
    }
    try buf.append(allocator, '"');
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}

/// argv (WTF-8) as a command line that CommandLineToArgvW splits back into it. Not for .bat or
/// .cmd scripts (`argvToScriptCommandLine`).
fn argvToCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) error{ OutOfMemory, InvalidWtf8, InvalidArg0 }![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (argv.len != 0) {
        // The first is quoted if empty or with spaces or control characters (not DEL). Its
        // backslashes aren't special, so some with quotes can't be passed without leaking into
        // the next argument; quotes can't be in a path anyway, so any is refused.
        const arg0 = argv[0];
        var needs_quotes = arg0.len == 0;
        for (arg0) |c| {
            if (c <= ' ') needs_quotes = true else if (c == '"') return error.InvalidArg0;
        }
        if (needs_quotes) try buf.append(allocator, '"');
        try buf.appendSlice(allocator, arg0);
        if (needs_quotes) try buf.append(allocator, '"');
        for (argv[1..]) |arg| {
            try buf.append(allocator, ' ');
            // Quoted if empty, or with spaces, quotes or control characters (not DEL).
            const quote = arg.len == 0 or for (arg) |c| {
                if (c <= ' ' or c == '"') break true;
            } else false;
            if (!quote) {
                try buf.appendSlice(allocator, arg);
                continue;
            }
            try buf.append(allocator, '"');
            var backslashes: usize = 0;
            for (arg) |c| switch (c) {
                '\\' => backslashes += 1,
                '"' => {
                    try buf.appendNTimes(allocator, '\\', backslashes * 2 + 1);
                    try buf.append(allocator, '"');
                    backslashes = 0;
                },
                else => {
                    try buf.appendNTimes(allocator, '\\', backslashes);
                    try buf.append(allocator, c);
                    backslashes = 0;
                },
            };
            try buf.appendNTimes(allocator, '\\', backslashes * 2);
            try buf.append(allocator, '"');
        }
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}

/// Held while a child's inheritable handles exist (`spawn`).
var spawn_lock: win32.RTL_SRWLOCK = .{ .Ptr = null };

const std = @import("std");
const win32 = @import("win32").everything;
const windows = std.os.windows;
