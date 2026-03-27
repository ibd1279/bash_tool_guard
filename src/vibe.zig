const std = @import("std");

pub const VibeResult = struct {
    safe: bool,
    explanation: []const u8, // owned, allocator-allocated
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VibeResult) void {
        self.allocator.free(self.explanation);
    }
};

const PROMPT_PREFIX =
    \\You are a safety gate for Claude Code, an AI coding assistant running commands in a developer's local environment.
    \\
    \\Evaluate the command below and respond with a SINGLE LINE — no other text.
    \\
    \\  safe          — the command is routine development work with no meaningful risk of data loss,
    \\                  credential exposure, or unintended side effects. When in doubt about a normal
    \\                  dev command, prefer safe.
    \\  ask: <risk>   — there is a specific, concrete risk worth surfacing. One sentence describing
    \\                  the risk or irreversible action, not a description of what the command does.
    \\
    \\Square-bracket annotations appended to the command provide pre-check context:
    \\  [not in allow list: X, Y]  — these executables bypassed the fast-path allow list
    \\  [dangerous flags: X]       — a flag rule flagged this specific invocation
    \\  [process info: ...]        — identified targets for kill/pkill commands
    \\
    \\Command:
;

fn failResult(allocator: std.mem.Allocator) !VibeResult {
    return VibeResult{
        .safe = false,
        .explanation = try allocator.dupe(u8, "vibe unavailable"),
        .allocator = allocator,
    };
}

/// Spawn vibe with an arbitrary prompt and return the full trimmed stdout.
/// Caller owns the returned slice. On any error returns an empty owned slice.
pub fn query(io: std.Io, allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "vibe", "-p", prompt, "--max-turns", "1" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return allocator.dupe(u8, "");

    const stdout_file = child.stdout orelse {
        child.kill(io);
        return allocator.dupe(u8, "");
    };

    var pollfds = [1]std.posix.pollfd{.{
        .fd = stdout_file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pollfds, 30_000) catch {
        _ = std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
        return allocator.dupe(u8, "");
    };
    if (ready == 0) {
        _ = std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
        return allocator.dupe(u8, "");
    }

    var rd_buf: [4096]u8 = undefined;
    var file_rd = stdout_file.reader(io, &rd_buf);
    const bytes = file_rd.interface.allocRemaining(allocator, .unlimited) catch {
        _ = child.wait(io) catch {};
        return allocator.dupe(u8, "");
    };
    _ = child.wait(io) catch {};
    return bytes; // caller owns
}

/// Spawn vibe and parse response. On any error, returns safe=false, explanation="Failed to evaluate command".
pub fn evaluate(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !VibeResult {
    const prompt = std.fmt.allocPrint(allocator, "{s}{s}", .{ PROMPT_PREFIX, command }) catch {
        return failResult(allocator);
    };
    defer allocator.free(prompt);

    var child = std.process.spawn(io, .{
        .argv = &.{ "vibe", "-p", prompt, "--max-turns", "1" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return failResult(allocator);
    };

    // Read stdout from the pipe
    const stdout_file = child.stdout orelse {
        child.kill(io);
        return failResult(allocator);
    };

    // Wait up to 30 seconds for vibe to produce output before reading.
    var pollfds = [1]std.posix.pollfd{.{
        .fd = stdout_file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pollfds, 30_000) catch {
        _ = std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
        return failResult(allocator);
    };
    if (ready == 0) {
        _ = std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
        return failResult(allocator);
    }

    var rd_buf: [4096]u8 = undefined;
    var file_rd = stdout_file.reader(io, &rd_buf);
    const stdout_bytes = file_rd.interface.allocRemaining(allocator, .unlimited) catch {
        _ = child.wait(io) catch {};
        return failResult(allocator);
    };
    defer allocator.free(stdout_bytes);

    _ = child.wait(io) catch {};

    // Use only the first line; ignore anything after a newline.
    const newline_pos = std.mem.indexOfScalar(u8, stdout_bytes, '\n');
    const first_line_raw = std.mem.trim(
        u8,
        if (newline_pos) |pos| stdout_bytes[0..pos] else stdout_bytes,
        " \t\r\n",
    );

    // Lowercase a copy just for the tag check; preserve original casing for
    // the explanation so the user-visible reason isn't all-lowercase.
    const first_line_lower = try allocator.dupe(u8, first_line_raw);
    defer allocator.free(first_line_lower);
    for (first_line_lower) |*c| c.* = std.ascii.toLower(c.*);

    // Exact match only — substring match would treat "unsafe" as safe.
    if (std.mem.eql(u8, first_line_lower, "safe")) {
        return VibeResult{
            .safe = true,
            .explanation = try allocator.dupe(u8, ""),
            .allocator = allocator,
        };
    }

    // Expected format: "ask: <explanation>" — find the colon in the lowercased
    // copy to locate the split point, then extract from the original-cased line.
    const explanation_raw = if (std.mem.indexOf(u8, first_line_lower, ":")) |colon|
        std.mem.trim(u8, first_line_raw[colon + 1 ..], " \t")
    else
        "";
    const explanation = if (explanation_raw.len > 0)
        try allocator.dupe(u8, explanation_raw)
    else
        try allocator.dupe(u8, "Command requires review");

    return VibeResult{
        .safe = false,
        .explanation = explanation,
        .allocator = allocator,
    };
}
