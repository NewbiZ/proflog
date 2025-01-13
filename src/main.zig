const std = @import("std");

const LINE_BUFFER_SIZE = 64 * 1024;

const COLOR_NONE = "";
const COLOR_BLUE = "\x1b[0;34m";
const COLOR_RESET = "\x1b[0m";

fn spawnSubprocess(cmd: []const []const u8, allocator: std.mem.Allocator) !std.process.Child {
    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    return child;
}

fn consumeFifo(fifo: *std.io.PollFifo, lineBuffer: *[LINE_BUFFER_SIZE]u8) !?[]const u8 {
    if (std.mem.indexOf(u8, fifo.readableSlice(0), "\n")) |i| {
        return lineBuffer[0 .. fifo.read(lineBuffer[0 .. i + 1]) - 1];
    }
    return null;
}

fn elapsedSince(since: i64) u64 {
    return @intCast(std.time.milliTimestamp() - since);
}

fn formatLine(elapsed: u64, line: []const u8, color: bool) void {
    const minutes = elapsed / 1000 / 60;
    const seconds = elapsed / 1000 % 60;
    const millis = elapsed % 1000;
    std.debug.print("\r{s}{d:0>2}:{d:0>2}.{:0>3}{s} ▏ {s}", .{
        if (color) COLOR_BLUE else COLOR_NONE,
        minutes,
        seconds,
        millis,
        if (color) COLOR_RESET else COLOR_NONE,
        line,
    });
}

fn logSubprocess(subprocess: *std.process.Child, color: bool, allocator: std.mem.Allocator) !void {
    var lineBuffer: [LINE_BUFFER_SIZE]u8 = undefined;

    var currentLine: ?[]const u8 = null;
    var currentLineTime: i64 = std.time.milliTimestamp();

    var poller = std.io.poll(
        allocator,
        enum { stdout },
        .{ .stdout = subprocess.stdout.? },
    );
    defer poller.deinit();

    const fifo = poller.fifo(.stdout);

    while (try poller.pollTimeout(0)) {
        if (currentLine) |line| {
            formatLine(elapsedSince(currentLineTime), line, color);
        }
        while (try consumeFifo(fifo, &lineBuffer)) |line| {
            if (currentLine) |_| {
                std.debug.print("\n", .{});
            }
            formatLine(0, line, color);
            currentLine = line;
            currentLineTime = std.time.milliTimestamp();
        }
        if (currentLine) |line| {
            formatLine(elapsedSince(currentLineTime), line, color);
        }

        std.time.sleep(std.time.ns_per_ms * 50);
    }
    std.debug.print("\n", .{});
}

pub fn main() !u8 {
    if (std.os.argv.len < 2) {
        std.debug.print("Usage: proflog [options] -- <command> [args]...\n", .{});
        return 2;
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var args = try allocator.alloc([]const u8, std.os.argv.len - 1);
    defer allocator.free(args);

    for (std.os.argv[1..], 0..) |arg, i| {
        args[i] = std.mem.span(arg);
    }

    var subprocess = try spawnSubprocess(args, allocator);
    try logSubprocess(&subprocess, true, allocator);

    const result = try subprocess.wait();
    return result.Exited;
}
