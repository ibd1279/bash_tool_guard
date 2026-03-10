const std = @import("std");

/// Escape a string for embedding inside a JSON string value in an NDJSON log.
/// Newline and carriage-return characters are replaced with a space so that
/// each log entry stays on a single line.  Tab characters are also replaced
/// with a space for the same reason.  Backslash and double-quote are escaped
/// per the JSON spec.  Caller owns the returned slice.
pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n', '\r', '\t' => try out.append(allocator, ' '),
            else => try out.append(allocator, ch),
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "jsonEscape: newline becomes space" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "line1\nline2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1 line2", result);
}

test "jsonEscape: carriage return becomes space" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "a\rb");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a b", result);
}

test "jsonEscape: tab becomes space" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "a\tb");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a b", result);
}

test "jsonEscape: backslash is escaped" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "a\\b");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\\\\b", result);
}

test "jsonEscape: double quote is escaped" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "say \"hi\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", result);
}

test "jsonEscape: plain string is unchanged" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "git status");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("git status", result);
}

test "jsonEscape: multi-line vibe explanation becomes single line" {
    const allocator = std.testing.allocator;
    const result = try jsonEscape(allocator, "This is dangerous\nbecause reasons\r\nand more");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("This is dangerous because reasons  and more", result);
}

/// Format a unix timestamp as ISO 8601 UTC string: "2024-01-15T10:30:00Z"
fn formatTimestamp(allocator: std.mem.Allocator, unix_secs: i64) ![]u8 {
    const secs: u64 = @intCast(if (unix_secs < 0) 0 else unix_secs);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(secs / std.time.s_per_day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = secs % std.time.s_per_day;
    const hour = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const second = day_secs % 60;

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        hour,
        minute,
        second,
    });
}

pub fn appendEntry(allocator: std.mem.Allocator, path: []const u8, cmd: []const u8, reason: []const u8, project_root: ?[]const u8) !void {
    const ts = try formatTimestamp(allocator, std.time.timestamp());
    defer allocator.free(ts);

    const cmd_escaped = try jsonEscape(allocator, cmd);
    defer allocator.free(cmd_escaped);

    const reason_escaped = try jsonEscape(allocator, reason);
    defer allocator.free(reason_escaped);

    // Build the optional "project" field. Omit entirely when null or empty.
    const project_part: []u8 = if (project_root) |pr| blk: {
        if (pr.len == 0) break :blk try allocator.dupe(u8, "");
        const pr_escaped = try jsonEscape(allocator, pr);
        defer allocator.free(pr_escaped);
        break :blk try std.fmt.allocPrint(allocator, ",\"project\":\"{s}\"", .{pr_escaped});
    } else try allocator.dupe(u8, "");
    defer allocator.free(project_part);

    const line = try std.fmt.allocPrint(allocator, "{{\"cmd\":\"{s}\",\"reason\":\"{s}\",\"ts\":\"{s}\"{s}}}\n", .{
        cmd_escaped,
        reason_escaped,
        ts,
        project_part,
    });
    defer allocator.free(line);

    // Open with O_APPEND for POSIX atomic-append semantics (no seekFromEnd race).
    const flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std.posix.open(path, flags, 0o644);
    const file = std.fs.File{ .handle = fd };
    defer file.close();

    try file.writeAll(line);
}
