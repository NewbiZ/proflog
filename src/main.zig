const std = @import("std");
const tmpdir = @import("tmpdir.zig");
const sitecustomize = @embedFile("sitecustomize.py");
const spawn_posix = @import("spawn_posix.zig");

const print = std.debug.print;
const assert = std.debug.assert;

const LINE_BUFFER_SIZE = 64 * 1024;

const COLOR = true;

const COLOR_START = if (COLOR) "\x1b[0;34m" else "";
const COLOR_STOP = if (COLOR) "\x1b[0m" else "";

const POLL_STACKTRACE = 500;
const POLL_DURATION = 50 * std.time.ns_per_ms;

var TMPDIR_BUFFER: [1024]u8 = undefined;
var STACKTRACE_BUFFER: [4096]u8 = undefined;

fn prepareStacktraceDir() ![]const u8 {
    const stacktraceDir = try tmpdir.mkdtemp("proflog", &TMPDIR_BUFFER);

    var sitecustomizePathBuffer: [1024]u8 = undefined;
    const sitecustomizeFile = try std.fs.cwd().createFile(
        try std.fmt.bufPrint(&sitecustomizePathBuffer, "{s}/sitecustomize.py", .{stacktraceDir}),
        .{ .exclusive = true },
    );
    try sitecustomizeFile.writeAll(sitecustomize);

    return stacktraceDir;
}

fn cleanupStacktraceDir(stacktraceDir: []const u8) !void {
    try std.fs.cwd().deleteTree(stacktraceDir);
}

fn spawnSubprocess(cmd: []const []const u8, environment: *std.process.EnvMap, allocator: std.mem.Allocator) !std.process.Child {
    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.request_resource_usage_statistics = true;
    child.env_map = environment;

    try spawn_posix.spawnPosix(&child);

    return child;
}

fn consumeFifo(fifo: *std.io.PollFifo, lineBuffer: *[LINE_BUFFER_SIZE]u8) !?[]const u8 {
    if (fifo.readableLength() > 0) {
        if (std.mem.indexOf(u8, fifo.readableSlice(0), "\n")) |i| {
            return lineBuffer[0 .. fifo.read(lineBuffer[0 .. i + 1]) - 1];
        }
    }
    return null;
}

fn elapsedSince(since: i64) u64 {
    return @intCast(std.time.milliTimestamp() - since);
}

fn formatLine(elapsed: u64, line: []const u8, stacktraceLine: []const u8) void {
    const minutes = elapsed / 1000 / 60;
    const seconds = elapsed / 1000 % 60;
    const millis = elapsed % 1000;
    const columns = getTerminalSize().columns;
    const stacktraceLineTruncated = if (stacktraceLine.len <= columns - 15) stacktraceLine else stacktraceLine[0 .. columns - 15];
    print("\x1b[F\x1b[2K{s}{d:0>2}:{d:0>2}.{:0>3}{s} │ {s}\n\x1b[2K{s}executing{s} │ {s}{s}", .{
        COLOR_START,
        minutes,
        seconds,
        millis,
        COLOR_STOP,
        line,
        COLOR_START,
        COLOR_STOP,
        stacktraceLineTruncated,
        if (stacktraceLine.len <= columns - 15) "" else "…",
    });
}

fn getTerminalSize() struct { rows: u16, columns: u16 } {
    var winsize: std.posix.winsize = .{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const err = std.posix.system.ioctl(std.io.getStdOut().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) != .SUCCESS) {
        return .{ .rows = 25, .columns = 80 };
    }
    return .{ .rows = winsize.ws_row, .columns = winsize.ws_col };
}

fn readLatestStacktrace(stacktraceFile: []const u8) []const u8 {
    const file = std.fs.cwd().openFile(stacktraceFile, .{}) catch return "?";
    defer file.close();

    const fileSize: u64 = file.getEndPos() catch return "?";
    file.seekFromEnd(-@as(i64, @intCast(@min(fileSize, STACKTRACE_BUFFER.len)))) catch return "?";
    const readSize = file.readAll(&STACKTRACE_BUFFER) catch return "?";
    const endOfStacktrace = std.mem.lastIndexOf(u8, STACKTRACE_BUFFER[0..readSize], "\n") orelse return "?";
    const startOfStacktrace = std.mem.lastIndexOf(u8, STACKTRACE_BUFFER[0..endOfStacktrace], "\n") orelse return "?";

    return STACKTRACE_BUFFER[startOfStacktrace + 1 .. endOfStacktrace];
}

fn logSubprocess(subprocess: *std.process.Child, stacktraceDir: []const u8, allocator: std.mem.Allocator) !void {
    var lineBuffer: [LINE_BUFFER_SIZE]u8 = undefined;

    var currentLine: ?[]const u8 = null;
    var currentLineTime: i64 = std.time.milliTimestamp();

    var poller = std.io.poll(
        allocator,
        enum { stderr },
        .{ .stderr = subprocess.stderr.? },
    );
    defer poller.deinit();

    const fifo = poller.fifo(.stderr);

    var stacktraceTime: i64 = std.time.milliTimestamp();
    var stacktraceAvailable = false;
    var stacktraceFileBuffer: [1024]u8 = undefined;
    const stacktraceFile = try std.fmt.bufPrint(
        &stacktraceFileBuffer,
        "{s}/{d}",
        .{ stacktraceDir, subprocess.id },
    );

    while (try poller.pollTimeout(0)) {
        const stacktraceLine = readLatestStacktrace(stacktraceFile);
        if (currentLine) |line| {
            formatLine(elapsedSince(currentLineTime), line, stacktraceLine);
        }
        while (try consumeFifo(fifo, &lineBuffer)) |line| {
            if (currentLine) |_| {
                print("\n", .{});
            } else {
                print("\n", .{});
            }
            formatLine(0, line, stacktraceLine);
            currentLine = line;
            currentLineTime = std.time.milliTimestamp();
        }
        if (currentLine) |line| {
            formatLine(elapsedSince(currentLineTime), line, stacktraceLine);
        }

        if (elapsedSince(stacktraceTime) >= POLL_STACKTRACE) {
            if (stacktraceAvailable) blk: {
                std.fs.cwd().access(stacktraceFile, .{}) catch {
                    stacktraceAvailable = false;
                    break :blk;
                };
                stacktraceTime = std.time.milliTimestamp();
                try std.posix.kill(subprocess.id, std.os.linux.SIG.USR1);
            } else blk: {
                std.fs.cwd().access(stacktraceFile, .{}) catch break :blk;
                stacktraceAvailable = true;
            }
        }

        std.time.sleep(POLL_DURATION);
    }
    print("\n", .{});
}

pub fn main() !u8 {
    if (std.os.argv.len < 2) {
        print("Usage: proflog <command> [args]...\n", .{});
        return 2;
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer assert(gpa.deinit() == .ok);

    var args = try allocator.alloc([]const u8, std.os.argv.len - 1);
    defer allocator.free(args);

    for (std.os.argv[1..], 0..) |arg, i| {
        args[i] = std.mem.span(arg);
    }
    const stacktraceDir = try prepareStacktraceDir();
    defer cleanupStacktraceDir(stacktraceDir) catch |err| {
        print("proflog failed to cleanup stacktrace directory {s}: {any}", .{ stacktraceDir, err });
    };

    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    var pythonPathBuffer: [1024]u8 = undefined;
    const pythonPath = try std.fmt.bufPrint(&pythonPathBuffer, "{s}:{s}", .{ stacktraceDir, environment.get("PYTHONPATH") orelse "" });
    try environment.put("PYTHONPATH", pythonPath);
    try environment.put("PROFLOG_STACKTRACE_DIR", stacktraceDir);

    const startTime = std.time.milliTimestamp();
    var subprocess = try spawnSubprocess(args, &environment, allocator);
    try logSubprocess(&subprocess, stacktraceDir, allocator);

    const elapsedTime = elapsedSince(startTime);
    const elapsedMinutes = elapsedTime / 1000 / 60;
    const elapsedSeconds = elapsedTime / 1000 % 60;
    const elapsedMillis = elapsedTime % 1000;

    print("\x1b[F\x1b[2K", .{});
    print("{s}Total execution time{s} {d:0>2}:{d:0>2}.{:0>3}\n", .{ COLOR_START, COLOR_STOP, elapsedMinutes, elapsedSeconds, elapsedMillis });

    switch (try subprocess.wait()) {
        .Signal => |s| {
            print("{s}Terminated by signal{s} {d}\n", .{ COLOR_START, COLOR_STOP, s });
            return 128 + @as(u8, @intCast(s));
        },
        .Exited => |c| {
            print("{s}Terminated with code{s} {d} ({s})\n", .{ COLOR_START, COLOR_STOP, c, if (c == 0) "OK" else "NOK" });
            const maxrss = @as(u64, @intCast(subprocess.resource_usage_statistics.rusage.?.maxrss));
            print("{s}Resource usage summary:{s}\n", .{ COLOR_START, COLOR_STOP });
            print("    {s}Memory:{s} {}\n", .{ COLOR_START, COLOR_STOP, std.fmt.fmtIntSizeBin(maxrss * 1024) });
            return c;
        },
        .Stopped => |c| {
            print("{s}Terminated with stop{s} {d} ({s})\n", .{ COLOR_START, COLOR_STOP, c, if (c == 0) "OK" else "NOK" });
            return 1;
        },
        else => return 42,
    }
}
