const builtin = @import("builtin");
const std = @import("std");

const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

fn writeIntFd(fd: i32, value: ErrInt) !void {
    const file: std.fs.File = .{ .handle = fd };
    file.writer().writeInt(u64, @intCast(value), .little) catch return error.SystemResources;
}

fn setUpChildIo(stdio: std.process.Child.StdIo, pipe_fd: i32, std_fileno: i32, dev_null_fd: i32) !void {
    switch (stdio) {
        .Pipe => try std.posix.dup2(pipe_fd, std_fileno),
        .Close => std.posix.close(std_fileno),
        .Inherit => {},
        .Ignore => try std.posix.dup2(dev_null_fd, std_fileno),
    }
}

fn destroyPipe(pipe: [2]std.posix.fd_t) void {
    if (pipe[0] != -1) std.posix.close(pipe[0]);
    if (pipe[0] != pipe[1]) std.posix.close(pipe[1]);
}

// Child of fork calls this to report an error to the fork parent.
// Then the child exits.
fn forkChildErrReport(fd: i32, err: anytype) noreturn {
    writeIntFd(fd, @as(ErrInt, @intFromError(err))) catch {};
    // If we're linking libc, some naughty applications may have registered atexit handlers
    // which we really do not want to run in the fork child. I caught LLVM doing this and
    // it caused a deadlock instead of doing an exit syscall. In the words of Avril Lavigne,
    // "Why'd you have to go and make things so complicated?"
    if (builtin.link_libc) {
        // The _exit(2) function does nothing but make the exit syscall, unlike exit(3)
        std.c._exit(1);
    }
    std.posix.exit(1);
}

pub fn spawnPosix(self: *std.process.Child) !void {
    // The child process does need to access (one end of) these pipes. However,
    // we must initially set CLOEXEC to avoid a race condition. If another thread
    // is racing to spawn a different child process, we don't want it to inherit
    // these FDs in any scenario; that would mean that, for instance, calls to
    // `poll` from the parent would not report the child's stdout as closing when
    // expected, since the other child may retain a reference to the write end of
    // the pipe. So, we create the pipes with CLOEXEC initially. After fork, we
    // need to do something in the new child to make sure we preserve the reference
    // we want. We could use `fcntl` to remove CLOEXEC from the FD, but as it
    // turns out, we `dup2` everything anyway, so there's no need!
    const pipe_flags: std.posix.O = .{ .CLOEXEC = true };

    const stdin_pipe = if (self.stdin_behavior == .Pipe) try std.posix.pipe2(pipe_flags) else undefined;
    errdefer if (self.stdin_behavior == .Pipe) {
        destroyPipe(stdin_pipe);
    };

    const stderr_pipe = if (self.stderr_behavior == .Pipe) try std.posix.pipe2(pipe_flags) else undefined;
    errdefer if (self.stderr_behavior == .Pipe) {
        destroyPipe(stderr_pipe);
    };

    const stdout_pipe = if (self.stdout_behavior == .Pipe) try std.posix.dup(stderr_pipe[1]) else undefined;

    const any_ignore = (self.stdin_behavior == .Ignore or self.stdout_behavior == .Ignore or self.stderr_behavior == .Ignore);
    const dev_null_fd = if (any_ignore)
        std.posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch |err| switch (err) {
            error.PathAlreadyExists => unreachable,
            error.NoSpaceLeft => unreachable,
            error.FileTooBig => unreachable,
            error.DeviceBusy => unreachable,
            error.FileLocksNotSupported => unreachable,
            error.BadPathName => unreachable, // Windows-only
            error.WouldBlock => unreachable,
            error.NetworkNotFound => unreachable, // Windows-only
            else => |e| return e,
        }
    else
        undefined;
    defer {
        if (any_ignore) std.posix.close(dev_null_fd);
    }

    const prog_pipe: [2]std.posix.fd_t = p: {
        if (self.progress_node.index == .none) {
            break :p .{ -1, -1 };
        } else {
            // We use CLOEXEC for the same reason as in `pipe_flags`.
            break :p try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        }
    };
    errdefer destroyPipe(prog_pipe);

    var arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // The POSIX standard does not allow malloc() between fork() and execve(),
    // and `self.allocator` may be a libc allocator.
    // I have personally observed the child process deadlocking when it tries
    // to call malloc() due to a heap allocation between fork() and execve(),
    // in musl v1.1.24.
    // Additionally, we want to reduce the number of possible ways things
    // can fail between fork() and execve().
    // Therefore, we do all the allocation for the execve() before the fork().
    // This means we must do the null-termination of argv and env vars here.
    const argv_buf = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const prog_fileno = 3;
    comptime std.debug.assert(@max(std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO) + 1 == prog_fileno);

    const envp: [*:null]const ?[*:0]const u8 = m: {
        const prog_fd: i32 = if (prog_pipe[1] == -1) -1 else prog_fileno;
        if (self.env_map) |env_map| {
            break :m (try std.process.createEnvironFromMap(arena, env_map, .{
                .zig_progress_fd = prog_fd,
            })).ptr;
        } else if (builtin.link_libc) {
            break :m (try std.process.createEnvironFromExisting(arena, std.c.environ, .{
                .zig_progress_fd = prog_fd,
            })).ptr;
        } else if (builtin.output_mode == .Exe) {
            // Then we have Zig start code and this works.
            // TODO type-safety for null-termination of `os.environ`.
            break :m (try std.process.createEnvironFromExisting(arena, @ptrCast(std.os.environ.ptr), .{
                .zig_progress_fd = prog_fd,
            })).ptr;
        } else {
            // TODO come up with a solution for this.
            @compileError("missing std lib enhancement: ChildProcess implementation has no way to collect the environment variables to forward to the child process");
        }
    };

    // This pipe is used to communicate errors between the time of fork
    // and execve from the child process to the parent process.
    const err_pipe = blk: {
        const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
        // There's no distinction between the readable and the writeable
        // end with eventfd
        break :blk [2]std.posix.fd_t{ fd, fd };
    };
    errdefer destroyPipe(err_pipe);

    const pid_result = try std.posix.fork();
    if (pid_result == 0) {
        // we are the child
        setUpChildIo(self.stdin_behavior, stdin_pipe[0], std.posix.STDIN_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);
        setUpChildIo(self.stdout_behavior, stdout_pipe, std.posix.STDOUT_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);
        setUpChildIo(self.stderr_behavior, stderr_pipe[1], std.posix.STDERR_FILENO, dev_null_fd) catch |err| forkChildErrReport(err_pipe[1], err);

        if (self.cwd_dir) |cwd| {
            std.posix.fchdir(cwd.fd) catch |err| forkChildErrReport(err_pipe[1], err);
        } else if (self.cwd) |cwd| {
            std.posix.chdir(cwd) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        // Must happen after fchdir above, the cwd file descriptor might be
        // equal to prog_fileno and be clobbered by this dup2 call.
        if (prog_pipe[1] != -1) std.posix.dup2(prog_pipe[1], prog_fileno) catch |err| forkChildErrReport(err_pipe[1], err);

        if (self.gid) |gid| {
            std.posix.setregid(gid, gid) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        if (self.uid) |uid| {
            std.posix.setreuid(uid, uid) catch |err| forkChildErrReport(err_pipe[1], err);
        }

        const err = switch (self.expand_arg0) {
            .expand => std.posix.execvpeZ_expandArg0(.expand, argv_buf.ptr[0].?, argv_buf.ptr, envp),
            .no_expand => std.posix.execvpeZ_expandArg0(.no_expand, argv_buf.ptr[0].?, argv_buf.ptr, envp),
        };
        forkChildErrReport(err_pipe[1], err);
    }

    // we are the parent
    const pid: i32 = @intCast(pid_result);
    if (self.stdin_behavior == .Pipe) {
        self.stdin = .{ .handle = stdin_pipe[1] };
    } else {
        self.stdin = null;
    }
    self.stdout = null;
    if (self.stderr_behavior == .Pipe) {
        self.stderr = .{ .handle = stderr_pipe[0] };
    } else {
        self.stderr = null;
    }

    self.id = pid;
    self.err_pipe = err_pipe;
    self.term = null;

    if (self.stdin_behavior == .Pipe) {
        std.posix.close(stdin_pipe[0]);
    }
    if (self.stdout_behavior == .Pipe) {
        std.posix.close(stdout_pipe);
    }
    if (self.stderr_behavior == .Pipe) {
        std.posix.close(stderr_pipe[1]);
    }

    if (prog_pipe[1] != -1) {
        std.posix.close(prog_pipe[1]);
    }
    self.progress_node.setIpcFd(prog_pipe[0]);
}
