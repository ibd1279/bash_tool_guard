const std = @import("std");

/// Convert a Claude Code permissions.allow entry like `Bash(cmd *)` to an
/// ERE pattern suitable for `patterns.matchEre`.  Returns null if the entry
/// is not a Bash(...) entry.  Caller owns the returned slice.
pub fn bashPatternToEre(allocator: std.mem.Allocator, entry: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, entry, "Bash(") or !std.mem.endsWith(u8, entry, ")")) return null;
    const inner = entry["Bash(".len .. entry.len - 1];
    if (std.mem.endsWith(u8, inner, " *")) {
        const prefix = inner[0 .. inner.len - 2];
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "^{s}([^[:alnum:]_]|$)", .{prefix}));
    } else if (std.mem.endsWith(u8, inner, ":*")) {
        const prefix = inner[0 .. inner.len - 2];
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "^{s}([^[:alnum:]_]|$)", .{prefix}));
    } else {
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "^{s}$", .{inner}));
    }
}

/// Load ERE allow patterns derived from Bash(...) entries in a Claude Code
/// settings JSON file (permissions.allow).  Returns an owned slice of owned
/// strings.  Silently returns empty on missing file or parse error.
pub fn loadClaudeAllowPats(allocator: std.mem.Allocator, settings_path: []const u8) ![][]const u8 {
    var pats: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pats.items) |p| allocator.free(p);
        pats.deinit(allocator);
    }

    const data = std.fs.cwd().readFileAlloc(allocator, settings_path, 1 << 20) catch
        return pats.toOwnedSlice(allocator);
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return pats.toOwnedSlice(allocator);
    defer parsed.deinit();

    const perms = switch (parsed.value) {
        .object => |o| o.get("permissions") orelse return pats.toOwnedSlice(allocator),
        else => return pats.toOwnedSlice(allocator),
    };
    const allow_arr = switch (perms) {
        .object => |o| o.get("allow") orelse return pats.toOwnedSlice(allocator),
        else => return pats.toOwnedSlice(allocator),
    };
    const items = switch (allow_arr) {
        .array => |a| a.items,
        else => return pats.toOwnedSlice(allocator),
    };

    for (items) |item| {
        const entry = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (try bashPatternToEre(allocator, entry)) |ere| {
            try pats.append(allocator, ere);
        }
    }
    return pats.toOwnedSlice(allocator);
}
