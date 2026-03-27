const std = @import("std");

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// For a kill or pkill command, look up the targeted processes and return a
/// compact single-line description such as:
///   "PID 1234: nginx (user: www-data), PID 5678: bash (user: alice)"
///
/// Returns null if:
///   - the command is not kill/pkill
///   - no PIDs can be identified
///   - any subprocess call fails
///
/// Caller owns the returned slice.
pub fn lookupKillContext(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |tok| try tokens.append(allocator, tok);

    if (tokens.items.len == 0) return null;
    const prog = tokens.items[0];
    const args = tokens.items[1..];

    if (std.mem.eql(u8, prog, "kill") or std.mem.eql(u8, prog, "killall")) {
        return lookupKill(io, allocator, args);
    } else if (std.mem.eql(u8, prog, "pkill")) {
        return lookupPkill(io, allocator, args);
    }
    return null;
}

/// Parse kill/killall args, extract PIDs or name, and query ps.
fn lookupKill(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !?[]u8 {
    var pids: std.ArrayList([]const u8) = .empty;
    defer pids.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) continue;
        if (arg[0] == '-') {
            // -s SIGNAME and --signal SIGNAME consume the next token
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
                i += 1;
            }
            // All other -FLAG or -N forms are self-contained
            continue;
        }
        if (isAllDigits(arg)) {
            try pids.append(allocator, arg);
        }
    }

    if (pids.items.len == 0) return null;
    return queryPs(io, allocator, pids.items);
}

/// Parse pkill args, find the process name pattern, run pgrep to get PIDs,
/// then query ps.
fn lookupPkill(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !?[]u8 {
    var pattern: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) continue;
        if (arg[0] == '-') {
            // Flags that consume a separate value token
            if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "-U") or
                std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "-g") or
                std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "-s") or
                std.mem.eql(u8, arg, "-t"))
            {
                i += 1;
            }
            continue;
        }
        pattern = arg;
        break;
    }

    const name = pattern orelse return null;

    // Run pgrep to find matching PIDs
    var child = std.process.spawn(io, .{
        .argv = &.{ "pgrep", name },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    const pgrep_stdout = child.stdout orelse {
        child.kill(io);
        return null;
    };

    var rd_buf: [4096]u8 = undefined;
    var file_rd = pgrep_stdout.reader(io, &rd_buf);
    const pgrep_out = file_rd.interface.allocRemaining(allocator, .unlimited) catch {
        _ = child.wait(io) catch {};
        return null;
    };
    defer allocator.free(pgrep_out);
    _ = child.wait(io) catch {};

    var pids: std.ArrayList([]const u8) = .empty;
    defer pids.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, pgrep_out, '\n');
    while (line_it.next()) |line| {
        const pid = std.mem.trim(u8, line, " \t\r");
        if (pid.len > 0 and isAllDigits(pid)) {
            try pids.append(allocator, pid);
        }
    }

    if (pids.items.len == 0) return null;
    return queryPs(io, allocator, pids.items);
}

/// Run `ps -p PID1,PID2,... -o pid=,user=,comm=` and format results as a
/// compact comma-separated list.
fn queryPs(io: std.Io, allocator: std.mem.Allocator, pids: []const []const u8) !?[]u8 {
    const pid_csv = try std.mem.join(allocator, ",", pids);
    defer allocator.free(pid_csv);

    var child = std.process.spawn(io, .{
        .argv = &.{ "ps", "-p", pid_csv, "-o", "pid=,user=,comm=" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    const ps_stdout = child.stdout orelse {
        child.kill(io);
        return null;
    };

    var rd_buf: [4096]u8 = undefined;
    var file_rd = ps_stdout.reader(io, &rd_buf);
    const ps_out = file_rd.interface.allocRemaining(allocator, .unlimited) catch {
        _ = child.wait(io) catch {};
        return null;
    };
    defer allocator.free(ps_out);
    _ = child.wait(io) catch {};

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, ps_out, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var field_it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const pid = field_it.next() orelse continue;
        const user = field_it.next() orelse continue;
        const comm = field_it.next() orelse continue;

        if (result.items.len > 0) try result.appendSlice(allocator, ", ");
        const entry = try std.fmt.allocPrint(allocator, "PID {s}: {s} (user: {s})", .{ pid, comm, user });
        defer allocator.free(entry);
        try result.appendSlice(allocator, entry);
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return null;
    }
    return try result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests (parsing only — subprocess calls are not tested here)
// ---------------------------------------------------------------------------

test "lookupKillContext: non-kill command returns null" {
    const allocator = std.testing.allocator;
    const result = try lookupKillContext(undefined, allocator, "git status");
    try std.testing.expect(result == null);
}

test "lookupKillContext: empty command returns null" {
    const allocator = std.testing.allocator;
    const result = try lookupKillContext(undefined, allocator, "");
    try std.testing.expect(result == null);
}

test "lookupKill: no PIDs returns null" {
    const allocator = std.testing.allocator;
    const result = try lookupKillContext(undefined, allocator, "kill -9");
    try std.testing.expect(result == null);
}

test "lookupPkill: no pattern returns null" {
    const allocator = std.testing.allocator;
    const result = try lookupKillContext(undefined, allocator, "pkill -u root");
    try std.testing.expect(result == null);
}
