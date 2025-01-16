const std = @import("std");

pub fn mkdtemp(prefix: []const u8, out: []u8) ![]const u8 {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var count: usize = 1;
    var tentative_dir: []const u8 = undefined;
    while (true) : (count += 1) {
        tentative_dir = try std.fmt.bufPrint(out, "{s}/{s}-{d}", .{ tmpdir, prefix, count });
        std.posix.mkdir(tentative_dir, std.fs.Dir.default_mode) catch continue;
        break;
    }
    return tentative_dir;
}
