const std = @import("std");

/// Walk up from `cwd` looking for a `.git` directory, staying under `home`.
/// Returns an owned copy of the project root path, or null if not found.
/// Caller owns the returned slice.
pub fn findProjectRoot(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, home: []const u8) !?[]u8 {
    var current = cwd;
    while (true) {
        const under_home = std.mem.startsWith(u8, current, home) and
            (current.len == home.len or current[home.len] == '/');
        if (!under_home) return null;
        const git_path = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(git_path);
        std.Io.Dir.accessAbsolute(io, git_path, .{}) catch {
            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            current = parent;
            continue;
        };
        return try allocator.dupe(u8, current);
    }
}
