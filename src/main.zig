const std = @import("std");
const guard = @import("guard.zig");
const patterns = @import("patterns.zig");
const vibe = @import("vibe.zig");
const log_mod = @import("log.zig");
const output = @import("output.zig");
const pipeline = @import("pipeline.zig");
const project = @import("project.zig");
const settings = @import("settings.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const home: []const u8 = if (std.c.getenv("HOME")) |v| std.mem.span(v) else "/tmp";

    // Read all stdin until EOF.
    var input_list: std.ArrayList(u8) = .empty;
    defer input_list.deinit(allocator);
    {
        var tmp: [4096]u8 = undefined;
        var rd_buf: [4096]u8 = undefined;
        var stdin_rd = std.Io.File.stdin().reader(io, &rd_buf);
        while (true) {
            const n = try stdin_rd.interface.readSliceShort(&tmp);
            if (n == 0) break;
            try input_list.appendSlice(allocator, tmp[0..n]);
        }
    }
    const input = input_list.items;

    // Parse JSON input; silently exit 0 on any parse failure.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
        std.process.exit(0);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => std.process.exit(0),
    };

    // Determine which hook event this is.
    const is_post = blk: {
        const ev = root.get("hook_event_name") orelse break :blk false;
        break :blk switch (ev) {
            .string => |s| std.mem.eql(u8, s, "PostToolUse"),
            else => false,
        };
    };

    // Extract command from tool_input.command; exit 0 if missing/null/wrong type.
    const command: []const u8 = blk: {
        const tool_input_val = root.get("tool_input") orelse std.process.exit(0);
        const tool_input = switch (tool_input_val) {
            .object => |o| o,
            else => std.process.exit(0),
        };
        const cmd_val = tool_input.get("command") orelse std.process.exit(0);
        switch (cmd_val) {
            .string => |s| break :blk s,
            else => std.process.exit(0),
        }
    };
    if (command.len == 0) std.process.exit(0);

    // Sanitize command: blank env var values, quoted strings, and heredoc bodies.
    const command_sanitized = try guard.sanitizeCommand(allocator, command);
    defer allocator.free(command_sanitized);

    // Build shared paths.
    const allow_file = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.allow" });
    defer allocator.free(allow_file);

    // Load global allow patterns (empty slice if file does not exist).
    const global_allow_pats = blk: {
        std.Io.Dir.accessAbsolute(io, allow_file, .{}) catch break :blk try allocator.alloc([]const u8, 0);
        break :blk try patterns.loadPatterns(io, allocator, allow_file);
    };
    defer {
        for (global_allow_pats) |p| allocator.free(p);
        allocator.free(global_allow_pats);
    }

    // Find project root and load per-project Claude settings allow patterns.
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const maybe_project_root = try project.findProjectRoot(io, allocator, cwd, home);
    defer if (maybe_project_root) |r| allocator.free(r);

    const project_allow_pats = blk: {
        const root_path = maybe_project_root orelse break :blk try allocator.alloc([]const u8, 0);
        var pats: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (pats.items) |p| allocator.free(p);
            pats.deinit(allocator);
        }
        for (&[_][]const u8{ "settings.json", "settings.local.json" }) |fname| {
            const path = try std.fs.path.join(allocator, &.{ root_path, ".claude", fname });
            defer allocator.free(path);
            const file_pats = try settings.loadClaudeAllowPats(io, allocator, path);
            defer {
                for (file_pats) |p| allocator.free(p);
                allocator.free(file_pats);
            }
            for (file_pats) |p| {
                const owned = try allocator.dupe(u8, p);
                errdefer allocator.free(owned);
                try pats.append(allocator, owned);
            }
        }
        break :blk try pats.toOwnedSlice(allocator);
    };
    defer {
        for (project_allow_pats) |p| allocator.free(p);
        allocator.free(project_allow_pats);
    }

    // Merge global and project allow patterns.
    var merged_allow: std.ArrayList([]const u8) = .empty;
    defer merged_allow.deinit(allocator);
    try merged_allow.appendSlice(allocator, global_allow_pats);
    try merged_allow.appendSlice(allocator, project_allow_pats);
    const allow_pats = merged_allow.items;

    if (is_post) {
        // PostToolUse path.

        // Belt-and-suspenders: if tool_response.exitCode is present and non-zero,
        // the command failed; skip logging.
        if (root.get("tool_response")) |tr| {
            if (switch (tr) {
                .object => |o| o,
                else => null,
            }) |tr_obj| {
                if (tr_obj.get("exitCode")) |ec| {
                    switch (ec) {
                        .integer => |n| if (n != 0) std.process.exit(0),
                        .float => |f| if (f != 0.0) std.process.exit(0),
                        else => {},
                    }
                }
            }
        }

        const decision = try pipeline.classifyForPost(allocator, command_sanitized, allow_pats);
        if (decision == .log) {
            const post_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.post.log.jsonl" });
            defer allocator.free(post_log);
            log_mod.appendEntry(io, allocator, post_log, command_sanitized, "post: ran", maybe_project_root) catch {};
        }

        // PostToolUse hooks must produce no stdout output.
        std.process.exit(0);
    }

    // PreToolUse path (default).

    // Build deny path and load deny patterns.
    const deny_file = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.deny" });
    defer allocator.free(deny_file);
    const deny_pats = try patterns.loadPatterns(io, allocator, deny_file);
    defer {
        for (deny_pats) |p| allocator.free(p);
        allocator.free(deny_pats);
    }

    const vibe_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.vibe.log.jsonl" });
    defer allocator.free(vibe_log);
    const allow_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.allow.log.jsonl" });
    defer allocator.free(allow_log);

    const decision = try pipeline.evaluate(io, allocator, command_sanitized, deny_pats, allow_pats, vibe.evaluate);
    defer decision.deinit(allocator);

    switch (decision) {
        .allow_fast => {
            log_mod.appendEntry(io, allocator, allow_log, command_sanitized, "", maybe_project_root) catch {};
            try output.allow(io);
        },
        .allow_vibe => {
            log_mod.appendEntry(io, allocator, vibe_log, command_sanitized, "vibe: safe", maybe_project_root) catch {};
            try output.allow(io);
        },
        .deny => |reason| try output.deny(io, allocator, reason),
        .ask => |reason| {
            log_mod.appendEntry(io, allocator, vibe_log, command_sanitized, reason, maybe_project_root) catch {};
            try output.ask(io, allocator, reason);
        },
    }
}
