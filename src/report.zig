const std = @import("std");
const patterns = @import("patterns.zig");
const guard = @import("guard.zig");
const project = @import("project.zig");
const vibe = @import("vibe.zig");

// ---------------------------------------------------------------------------
// loadRawBashEntries
// ---------------------------------------------------------------------------

/// Read a settings JSON file and return the raw "Bash(...)" strings from
/// permissions.allow.  Caller owns each element and the outer slice.
fn loadRawBashEntries(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var result: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (result.items) |e| allocator.free(e);
        result.deinit(allocator);
    }

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch
        return result.toOwnedSlice(allocator);
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return result.toOwnedSlice(allocator);
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return result.toOwnedSlice(allocator),
    };
    const perms_val = obj.get("permissions") orelse return result.toOwnedSlice(allocator);
    const perms = switch (perms_val) {
        .object => |o| o,
        else => return result.toOwnedSlice(allocator),
    };
    const allow_val = perms.get("allow") orelse return result.toOwnedSlice(allocator);
    const items = switch (allow_val) {
        .array => |a| a.items,
        else => return result.toOwnedSlice(allocator),
    };

    for (items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.startsWith(u8, s, "Bash(")) {
            try result.append(allocator, try allocator.dupe(u8, s));
        }
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// appendPatternFile helper
// ---------------------------------------------------------------------------

/// Append a single pattern line to a config file, creating it if needed.
/// Also ensures `~/.local/etc/` exists.
fn appendPatternFile(io: std.Io, path: []const u8, pattern: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o644);
    const file = std.Io.File{ .handle = fd };
    defer file.close(io);
    try file.writeStreamingAll(io, pattern);
    try file.writeStreamingAll(io, "\n");
}

// ---------------------------------------------------------------------------
// Starter content
// ---------------------------------------------------------------------------

const STARTER_ALLOW =
    \\# Version control
    \\# Plain push escalates to vibe; --force/--mirror/--no-verify escalate further.
    \\# See flags.zig for the full git push rule set.
    \\^git\b
    \\
    \\# Container tools — only read-only / query subcommands fast-pathed.
    \\# docker run, exec, system escalate via flag rules even with ^docker\b.
    \\# Expand this list with: btg allow '^docker build\b'
    \\^docker (ps|images|logs|inspect|stats|version|info|pull)\b
    \\
    \\# Kubernetes — only read-only subcommands fast-pathed.
    \\# apply, delete, exec, edit, patch, scale, rollout escalate via flag rules.
    \\^kubectl (get|describe|logs|version|explain|diff|config)\b
    \\
    \\# Transparent wrappers — the guard sees through these to check the inner command.
    \\^timeout\b
    \\^nohup\b
    \\^nice\b
    \\^time\b
    \\
    \\# Safe read-only utilities
    \\^ls\b
    \\^cat\b
    \\^head\b
    \\^tail\b
    \\^grep\b
    \\^rg\b
    \\^which\b
    \\^echo\b
    \\^pwd\b
    \\^date\b
    \\^wc\b
    \\^diff\b
    \\^jq\b
    \\^sleep\b
;

const STARTER_DENY =
    \\# Pipe download to shell
    \\curl.*\|.*sh
    \\wget.*\|.*sh
    \\
    \\# Recursive delete from root
    \\rm\s+-rf\s+/
;

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

pub fn runInit(io: std.Io, allocator: std.mem.Allocator, home: []const u8, exe_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    // Ensure directories exist.
    for (&[_][]const u8{ ".local/etc", ".local/var" }) |sub| {
        const dir_path = try std.fs.path.join(allocator, &.{ home, sub });
        defer allocator.free(dir_path);
        std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Write btg.allow if it doesn't exist.
    const allow_path = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.allow" });
    defer allocator.free(allow_path);
    const allow_exists = blk: {
        std.Io.Dir.accessAbsolute(io, allow_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!allow_exists) {
        const f = try std.Io.Dir.createFileAbsolute(io, allow_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, STARTER_ALLOW);
        try out.print("Created {s}\n", .{allow_path});
    } else {
        try out.print("Skipped {s} (already exists)\n", .{allow_path});
    }

    // Write btg.deny if it doesn't exist.
    const deny_path = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.deny" });
    defer allocator.free(deny_path);
    const deny_exists = blk: {
        std.Io.Dir.accessAbsolute(io, deny_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!deny_exists) {
        const f = try std.Io.Dir.createFileAbsolute(io, deny_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, STARTER_DENY);
        try out.print("Created {s}\n", .{deny_path});
    } else {
        try out.print("Skipped {s} (already exists)\n", .{deny_path});
    }

    try out.print("\nAdd hooks to ~/.claude/settings.json:\n", .{});
    try out.print(
        \\  "hooks": {{
        \\    "PreToolUse": [{{ "matcher": "Bash", "hooks": [{{ "type": "command", "command": "{s}" }}] }}],
        \\    "PostToolUse": [{{ "matcher": "Bash", "hooks": [{{ "type": "command", "command": "{s}" }}] }}]
        \\  }}
        \\
    , .{exe_path, exe_path});
    try out.flush();
}

// ---------------------------------------------------------------------------
// Allow / Deny
// ---------------------------------------------------------------------------

pub fn runAllow(io: std.Io, allocator: std.mem.Allocator, home: []const u8, pattern: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    const path = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.allow" });
    defer allocator.free(path);

    try appendPatternFile(io, path, pattern);
    try out.print("Added to {s}: {s}\n", .{ path, pattern });
    try out.flush();
}

pub fn runDeny(io: std.Io, allocator: std.mem.Allocator, home: []const u8, pattern: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    const path = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.deny" });
    defer allocator.free(path);

    try appendPatternFile(io, path, pattern);
    try out.print("Added to {s}: {s}\n", .{ path, pattern });
    try out.flush();
}

// ---------------------------------------------------------------------------
// Ask report
// ---------------------------------------------------------------------------

/// Print the "frequently asked commands not in allow list" report.
/// `home` is the value of $HOME (not owned, not freed here).
pub fn runAskReport(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    try out.print("=== Frequently vibe-evaluated commands (not in allow list) ===\n", .{});

    // Load allow patterns.
    const allow_file = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.allow" });
    defer allocator.free(allow_file);
    const allow_pats = try patterns.loadPatterns(io, allocator, allow_file);
    defer {
        for (allow_pats) |p| allocator.free(p);
        allocator.free(allow_pats);
    }

    // Open vibe log.
    const vibe_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.vibe.log.jsonl" });
    defer allocator.free(vibe_log);

    const contents = blk: {
        break :blk std.Io.Dir.cwd().readFileAlloc(io, vibe_log, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                try out.print("  (none)\n", .{});
                try out.flush();
                return;
            },
            else => return err,
        };
    };
    defer allocator.free(contents);

    // Map first_word -> { count, ask_count, ran_count, project }.
    // `ask_count` is the number of occurrences with a non-safe verdict.
    // `ran_count` is the number of times the command appeared in the post log
    //   (executed successfully and was allow-listable).
    // `project` is the single project all occurrences came from, or null if
    // occurrences span multiple projects (or no project was recorded).
    const BucketVal = struct { count: u64, ask_count: u64, ran_count: u64, project: ?[]u8 };
    var counts = std.StringHashMap(BucketVal).init(allocator);
    defer {
        var map_it = counts.iterator();
        while (map_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.project) |p| allocator.free(p);
        }
        counts.deinit();
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();

        const cmd: []const u8 = switch (parsed.value) {
            .object => |o| blk: {
                const v = o.get("cmd") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            },
            else => continue,
        };

        // Extract the project field if present; null means no project recorded.
        const project_label: ?[]const u8 = blk: {
            switch (parsed.value) {
                .object => |o| {
                    if (o.get("project")) |pv| {
                        switch (pv) {
                            .string => |s| if (s.len > 0) break :blk s,
                            else => {},
                        }
                    }
                },
                else => {},
            }
            break :blk null;
        };

        // Determine whether this entry was an ask or a safe verdict.
        const is_ask: bool = blk: {
            switch (parsed.value) {
                .object => |o| {
                    if (o.get("reason")) |rv| {
                        switch (rv) {
                            .string => |s| break :blk !std.mem.eql(u8, s, "vibe: safe"),
                            else => {},
                        }
                    }
                },
                else => {},
            }
            break :blk false;
        };

        const segments = try guard.splitSegments(allocator, cmd);
        defer allocator.free(segments);

        for (segments) |seg| {
            // Skip shell structure (if/then/fi, for loops, variable assignments,
            // test builtins). Strip command-bearing keyword prefixes (then CMD, etc.)
            // and variable-assignment prefixes (VAR=val CMD) before bucketing.
            switch (guard.classifySegment(seg)) {
                .shell_structure => continue,
                .command => |cmd_part| {
                    // Expand wrappers (nohup, timeout, env, ...) so we bucket the
                    // actual executable, not its wrapper.
                    var parts: std.ArrayList([]const u8) = .empty;
                    defer parts.deinit(allocator);
                    try guard.expandWrappers(allocator, cmd_part, &parts);

                    for (parts.items) |exp| {
                        // Skip if covered by an allow pattern (full segment match).
                        if (try patterns.matchesAny(allocator, allow_pats, exp)) continue;

                        // Extract the first word (the command name).
                        const s = std.mem.trimStart(u8, exp, " \t");
                        const word_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
                        if (word_end == 0) continue;
                        const first_word = s[0..word_end];

                        // Skip tokens that cannot produce a useful allow pattern.
                        if (first_word[0] == '$') continue; // variable reference
                        if (std.mem.indexOfScalar(u8, first_word, '/') != null) continue; // path
                        if (first_word[0] > 127) continue; // non-ASCII (emoji, etc.)

                        // Shell wrappers are never allow-listed directly; bash -c should become a script.
                        if (std.mem.eql(u8, first_word, "bash") or
                            std.mem.eql(u8, first_word, "sh") or
                            std.mem.eql(u8, first_word, "zsh")) continue;

                        const owned_key = try allocator.dupe(u8, first_word);
                        const gop = counts.getOrPut(owned_key) catch |err| {
                            allocator.free(owned_key);
                            return err;
                        };
                        if (gop.found_existing) {
                            allocator.free(owned_key);
                            gop.value_ptr.count += 1;
                            if (is_ask) gop.value_ptr.ask_count += 1;
                            // Collapse to null if this occurrence is from a different project.
                            if (gop.value_ptr.project) |stored| {
                                const same = if (project_label) |pl|
                                    std.mem.eql(u8, stored, pl)
                                else
                                    false;
                                if (!same) {
                                    allocator.free(stored);
                                    gop.value_ptr.project = null;
                                }
                            }
                        } else {
                            gop.value_ptr.* = .{
                                .count = 1,
                                .ask_count = if (is_ask) 1 else 0,
                                .ran_count = 0,
                                .project = if (project_label) |pl| try allocator.dupe(u8, pl) else null,
                            };
                        }
                    }
                },
            }
        }
    }

    // Second pass: cross-reference btg.post.log.jsonl to populate ran_count.
    const post_log_path = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.post.log.jsonl" });
    defer allocator.free(post_log_path);
    const post_contents: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, post_log_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (post_contents) |c| allocator.free(c);

    if (post_contents) |pc| {
        var post_lines = std.mem.splitScalar(u8, pc, '\n');
        while (post_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
            defer parsed.deinit();
            const cmd: []const u8 = switch (parsed.value) {
                .object => |o| blk: {
                    const v = o.get("cmd") orelse continue;
                    break :blk switch (v) {
                        .string => |s| s,
                        else => continue,
                    };
                },
                else => continue,
            };
            const segs = try guard.splitSegments(allocator, cmd);
            defer allocator.free(segs);
            for (segs) |seg| {
                switch (guard.classifySegment(seg)) {
                    .shell_structure => continue,
                    .command => |cmd_part| {
                        var parts: std.ArrayList([]const u8) = .empty;
                        defer parts.deinit(allocator);
                        try guard.expandWrappers(allocator, cmd_part, &parts);
                        for (parts.items) |exp| {
                            const s = std.mem.trimStart(u8, exp, " \t");
                            const word_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
                            if (word_end == 0) continue;
                            const first_word = s[0..word_end];
                            if (counts.getPtr(first_word)) |v| v.ran_count += 1;
                        }
                    },
                }
            }
        }
    }

    // Collect entries with count > 1.
    const Entry = struct { cmd: []const u8, project: ?[]const u8, count: u64, ask_count: u64, ran_count: u64 };
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    defer list.deinit(allocator);

    var it = counts.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.count > 1) {
            try list.append(allocator, .{
                .cmd = kv.key_ptr.*,
                .project = kv.value_ptr.project,
                .count = kv.value_ptr.count,
                .ask_count = kv.value_ptr.ask_count,
                .ran_count = kv.value_ptr.ran_count,
            });
        }
    }

    if (list.items.len == 0) {
        try out.print("  (none)\n", .{});
        try out.flush();
        return;
    }

    // Sort descending by count.
    std.sort.block(Entry, list.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    for (list.items) |e| {
        // Build annotation string: [ask: N] [ran: N] [project]
        var ann_buf: [256]u8 = undefined;
        var ann_pos: usize = 0;
        if (e.ask_count > 0) {
            const s = std.fmt.bufPrint(ann_buf[ann_pos..], " [ask: {d}]", .{e.ask_count}) catch "";
            ann_pos += s.len;
        }
        if (e.ran_count > 0) {
            const s = std.fmt.bufPrint(ann_buf[ann_pos..], " [ran: {d}]", .{e.ran_count}) catch "";
            ann_pos += s.len;
        }
        if (e.project) |proj| {
            const s = std.fmt.bufPrint(ann_buf[ann_pos..], " [{s}]", .{proj}) catch "";
            ann_pos += s.len;
        }
        const ann_str = ann_buf[0..ann_pos];
        try out.print("{d:>4}  {s}{s}\n", .{ e.count, e.cmd, ann_str });
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Flush logs
// ---------------------------------------------------------------------------

/// Delete all cbg log files under $HOME/.local/var/.
/// `home` is the value of $HOME (not owned, not freed here).
pub fn runFlush(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    const logs = [_][]const u8{ "btg.vibe.log.jsonl", "btg.allow.log.jsonl", "btg.post.log.jsonl" };
    var flushed: u32 = 0;
    for (logs) |name| {
        const path = try std.fs.path.join(allocator, &.{ home, ".local/var", name });
        defer allocator.free(path);
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        flushed += 1;
    }
    if (flushed > 0) {
        try out.print("Flushed {d} log file(s).\n", .{flushed});
    } else {
        try out.print("No log files found.\n", .{});
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Stale allow report
// ---------------------------------------------------------------------------

/// Print the "allow patterns with zero invocations" report.
/// `home` is the value of $HOME (not owned, not freed here).
pub fn runStaleAllowReport(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    try out.print("=== Allow patterns with zero invocations ===\n", .{});

    const allow_file = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.allow" });
    defer allocator.free(allow_file);

    // Read the allow file manually so we can track raw lines alongside counts.
    const RawPattern = struct {
        line: []u8, // owned
        count: u64,
    };

    var raw_pats: std.ArrayListUnmanaged(RawPattern) = .empty;
    defer {
        for (raw_pats.items) |rp| allocator.free(rp.line);
        raw_pats.deinit(allocator);
    }

    {
        const allow_contents = std.Io.Dir.cwd().readFileAlloc(io, allow_file, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                try out.print("  (none)\n", .{});
                try out.flush();
                return;
            },
            else => return err,
        };
        defer allocator.free(allow_contents);

        var iter = std.mem.splitScalar(u8, allow_contents, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            const owned = try allocator.dupe(u8, line);
            errdefer allocator.free(owned);
            try raw_pats.append(allocator, .{ .line = owned, .count = 0 });
        }
    }

    if (raw_pats.items.len == 0) {
        try out.print("  (none)\n", .{});
        try out.flush();
        return;
    }

    // Open allow log.
    const allow_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.allow.log.jsonl" });
    defer allocator.free(allow_log);

    const maybe_log_contents: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, allow_log, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (maybe_log_contents) |c| allocator.free(c);

    const log_contents: []const u8 = maybe_log_contents orelse "";
    var log_lines = std.mem.splitScalar(u8, log_contents, '\n');
    while (log_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();

        const cmd: []const u8 = switch (parsed.value) {
            .object => |o| blk: {
                const v = o.get("cmd") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            },
            else => continue,
        };

        const segments = try guard.splitSegments(allocator, cmd);
        defer allocator.free(segments);

        for (segments) |seg| {
            // Apply the same classification and wrapper-expansion the guard uses,
            // so shell structure and wrapper prefixes don't hide pattern matches.
            switch (guard.classifySegment(seg)) {
                .shell_structure => continue,
                .command => |cmd_part| {
                    var parts: std.ArrayList([]const u8) = .empty;
                    defer parts.deinit(allocator);
                    try guard.expandWrappers(allocator, cmd_part, &parts);

                    for (parts.items) |exp| {
                        const exp_z = try allocator.dupeZ(u8, exp);
                        defer allocator.free(exp_z);

                        for (raw_pats.items, 0..) |rp, i| {
                            if (try patterns.matchEre(allocator, rp.line, exp_z)) {
                                raw_pats.items[i].count += 1;
                            }
                        }
                    }
                },
            }
        }
    }

    // Print patterns with count == 0.
    var any_stale = false;
    for (raw_pats.items) |rp| {
        if (rp.count == 0) {
            try out.print("  {s}\n", .{rp.line});
            any_stale = true;
        }
    }
    if (!any_stale) {
        try out.print("  (none)\n", .{});
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Suggest
// ---------------------------------------------------------------------------

/// Generate .claude/settings.local.json allow entries for every command seen
/// in the ask log while working in the current project.
pub fn runSuggest(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    // 1. Find project root.
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const project_root = (try project.findProjectRoot(io, allocator, cwd, home)) orelse {
        var ebuf: [256]u8 = undefined;
        var ebw = std.Io.File.stderr().writer(io, &ebuf);
        const err_out = &ebw.interface;
        try err_out.print("error: not inside a git repository under $HOME\n", .{});
        try err_out.flush();
        std.process.exit(1);
    };
    defer allocator.free(project_root);

    // 2. Read post log (commands that executed successfully without red flags).
    const post_log = try std.fs.path.join(allocator, &.{ home, ".local/var/btg.post.log.jsonl" });
    defer allocator.free(post_log);

    const log_contents: []u8 = std.Io.Dir.cwd().readFileAlloc(io, post_log, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("No new entries to add.\n", .{});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer allocator.free(log_contents);

    // 3. Collect deduplicated first_word candidates from this project's entries.
    var candidates = std.StringHashMap(void).init(allocator);
    defer {
        var it = candidates.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        candidates.deinit();
    }

    var log_lines = std.mem.splitScalar(u8, log_contents, '\n');
    while (log_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        // Filter by project field.
        const proj = switch (obj.get("project") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, proj, project_root)) continue;

        const cmd = switch (obj.get("cmd") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const segments = try guard.splitSegments(allocator, cmd);
        defer allocator.free(segments);

        for (segments) |seg| {
            switch (guard.classifySegment(seg)) {
                .shell_structure => continue,
                .command => |cmd_part| {
                    var parts: std.ArrayList([]const u8) = .empty;
                    defer parts.deinit(allocator);
                    try guard.expandWrappers(allocator, cmd_part, &parts);

                    for (parts.items) |exp| {
                        const s = std.mem.trimStart(u8, exp, " \t");
                        const word_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
                        if (word_end == 0) continue;
                        const first_word = s[0..word_end];

                        if (first_word[0] == '$') continue;
                        if (std.mem.indexOfScalar(u8, first_word, '/') != null) continue;
                        if (first_word[0] > 127) continue;
                        if (std.mem.eql(u8, first_word, "bash") or
                            std.mem.eql(u8, first_word, "sh") or
                            std.mem.eql(u8, first_word, "zsh")) continue;

                        const gop = try candidates.getOrPut(first_word);
                        if (!gop.found_existing) {
                            gop.key_ptr.* = try allocator.dupe(u8, first_word);
                        }
                    }
                },
            }
        }
    }

    if (candidates.count() == 0) {
        try out.print("No new entries to add.\n", .{});
        try out.flush();
        return;
    }

    // 4. Load existing raw Bash entries from both settings files for dedup.
    var existing_raw = std.StringHashMap(void).init(allocator);
    defer {
        var it = existing_raw.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        existing_raw.deinit();
    }

    for (&[_][]const u8{ "settings.json", "settings.local.json" }) |fname| {
        const path = try std.fs.path.join(allocator, &.{ project_root, ".claude", fname });
        defer allocator.free(path);
        const entries = try loadRawBashEntries(io, allocator, path);
        defer allocator.free(entries);
        for (entries) |e| {
            const gop = try existing_raw.getOrPut(e);
            if (gop.found_existing) {
                allocator.free(e); // already present; discard duplicate
            }
            // if !found_existing, e is now owned by existing_raw
        }
    }

    // 5. Determine which candidates are not already covered.
    var new_entries: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (new_entries.items) |e| allocator.free(e);
        new_entries.deinit(allocator);
    }

    {
        var it = candidates.keyIterator();
        while (it.next()) |k| {
            const entry = try std.fmt.allocPrint(allocator, "Bash({s} *)", .{k.*});
            errdefer allocator.free(entry);
            if (existing_raw.contains(entry)) {
                allocator.free(entry);
                continue;
            }
            try new_entries.append(allocator, entry);
        }
    }

    if (new_entries.items.len == 0) {
        try out.print("No new entries to add.\n", .{});
        try out.flush();
        return;
    }

    // Sort for deterministic output.
    std.sort.block([]u8, new_entries.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // 6. Load all existing allow items from settings.local.json (to preserve
    //    non-Bash entries when merging).
    const local_path = try std.fs.path.join(allocator, &.{ project_root, ".claude", "settings.local.json" });
    defer allocator.free(local_path);

    var all_allow: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (all_allow.items) |e| allocator.free(e);
        all_allow.deinit(allocator);
    }

    {
        const maybe_data: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, local_path, allocator, .unlimited) catch null;
        if (maybe_data) |d| {
            defer allocator.free(d);
            const maybe_parsed: ?std.json.Parsed(std.json.Value) =
                std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
            if (maybe_parsed) |p| {
                defer p.deinit();
                switch (p.value) {
                    .object => |obj| {
                        if (obj.get("permissions")) |perms| switch (perms) {
                            .object => |po| if (po.get("allow")) |allow| switch (allow) {
                                .array => |arr| for (arr.items) |item| switch (item) {
                                    .string => |s| try all_allow.append(
                                        allocator,
                                        try allocator.dupe(u8, s),
                                    ),
                                    else => {},
                                },
                                else => {},
                            },
                            else => {},
                        };
                    },
                    else => {},
                }
            }
        }
    }

    // Append new entries.
    for (new_entries.items) |e| {
        try all_allow.append(allocator, try allocator.dupe(u8, e));
    }

    // 7. Ensure .claude directory exists and write settings.local.json.
    const claude_dir = try std.fs.path.join(allocator, &.{ project_root, ".claude" });
    defer allocator.free(claude_dir);
    std.Io.Dir.createDirAbsolute(io, claude_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    {
        // Build JSON into a buffer; settings.local.json is small.
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(allocator);

        try json_buf.appendSlice(allocator, "{\n  \"permissions\": {\n    \"allow\": [\n");
        for (all_allow.items, 0..) |entry, i| {
            try json_buf.appendSlice(allocator, "      \"");
            for (entry) |ch| switch (ch) {
                '"' => try json_buf.appendSlice(allocator, "\\\""),
                '\\' => try json_buf.appendSlice(allocator, "\\\\"),
                else => try json_buf.append(allocator, ch),
            };
            try json_buf.append(allocator, '"');
            if (i + 1 < all_allow.items.len) try json_buf.append(allocator, ',');
            try json_buf.append(allocator, '\n');
        }
        try json_buf.appendSlice(allocator, "    ]\n  }\n}\n");

        const file = try std.Io.Dir.createFileAbsolute(io, local_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, json_buf.items);
    }

    // 8. Print summary.
    try out.print("Wrote {d} new {s} to {s}:\n", .{
        new_entries.items.len,
        if (new_entries.items.len == 1) @as([]const u8, "entry") else "entries",
        local_path,
    });
    for (new_entries.items) |entry| {
        try out.print("  {s}\n", .{entry});
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

const PATTERNS_PROMPT_PREFIX =
    \\You are a shell command analyst. The following bash commands all start
    \\with the same executable. Suggest minimal POSIX ERE patterns covering
    \\them for ~/.local/etc/btg.allow.
    \\
    \\Rules:
    \\- One pattern per line, no explanation, no markdown fences
    \\- Only generate patterns for the executable shown — not for other commands
    \\- Anchor with ^ and place \b after the last fixed token
    \\- One pattern per safe command prefix; do NOT enumerate optional subcommands
    \\  or flags in alternations — ^zig build\b covers all zig build invocations
    \\- Only use multiple patterns when subcommands have genuinely different risk
    \\  profiles that warrant separate entries (e.g. ^git push\b vs ^git log\b)
    \\- Do NOT combine safe and risky subcommands with alternation in one pattern
    \\
    \\Commands:
;

/// Feed logged commands whose first word matches `word` to vibe and print
/// suggested ERE allow patterns.
pub fn runPatterns(io: std.Io, allocator: std.mem.Allocator, home: []const u8, word: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_bw.interface;

    // Collect unique commands from vibe log and post log whose first word matches.
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    const log_names = [_][]const u8{ "btg.vibe.log.jsonl", "btg.post.log.jsonl" };
    for (log_names) |log_name| {
        const log_path = try std.fs.path.join(allocator, &.{ home, ".local/var", log_name });
        defer allocator.free(log_path);

        const contents: []u8 = std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .unlimited) catch continue;
        defer allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (seen.count() >= 40) break;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
            defer parsed.deinit();

            const cmd: []const u8 = switch (parsed.value) {
                .object => |o| blk: {
                    const v = o.get("cmd") orelse continue;
                    break :blk switch (v) {
                        .string => |s| s,
                        else => continue,
                    };
                },
                else => continue,
            };

            const segments = try guard.splitSegments(allocator, cmd);
            defer allocator.free(segments);

            for (segments) |seg| {
                switch (guard.classifySegment(seg)) {
                    .shell_structure => continue,
                    .command => |cmd_part| {
                        const s = std.mem.trimStart(u8, cmd_part, " \t");
                        const word_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
                        if (word_end == 0) continue;
                        const first_word = s[0..word_end];

                        if (!std.mem.eql(u8, first_word, word)) continue;

                        if (seen.count() >= 40) break;
                        const gop = try seen.getOrPut(s);
                        if (!gop.found_existing) {
                            gop.key_ptr.* = try allocator.dupe(u8, s);
                        }
                    },
                }
            }
        }
    }

    if (seen.count() == 0) {
        try out.print("(no logged commands for '{s}')\n", .{word});
        try out.flush();
        return;
    }

    // Build prompt.
    var prompt_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    try prompt_buf.appendSlice(allocator, PATTERNS_PROMPT_PREFIX);
    var it = seen.keyIterator();
    while (it.next()) |k| {
        try prompt_buf.appendSlice(allocator, k.*);
        try prompt_buf.append(allocator, '\n');
    }

    const result = try vibe.query(io, allocator, prompt_buf.items);
    defer allocator.free(result);

    // Strip markdown code fences if vibe wraps output in them.
    var result_view = std.mem.trim(u8, result, " \t\r\n");
    if (std.mem.startsWith(u8, result_view, "```")) {
        if (std.mem.indexOfScalar(u8, result_view, '\n')) |nl| {
            result_view = result_view[nl + 1 ..];
        }
    }
    if (std.mem.endsWith(u8, result_view, "```")) {
        result_view = std.mem.trimEnd(u8, result_view[0 .. result_view.len - 3], " \t\r\n");
    }
    result_view = std.mem.trim(u8, result_view, " \t\r\n");

    try out.print("=== Suggested allow patterns for: {s} ===\n", .{word});
    if (result_view.len == 0) {
        try out.print("(vibe returned no suggestions)\n", .{});
    } else {
        try out.print("{s}\n", .{result_view});
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const home: []const u8 = if (std.c.getenv("HOME")) |v| std.mem.span(v) else "/tmp";

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // skip argv[0]
    var selector_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer selector_list.deinit(allocator);
    while (args_iter.next()) |arg| {
        try selector_list.append(allocator, arg);
    }
    const selectors = selector_list.items;

    if (selectors.len == 0) {
        try runAskReport(io, allocator, home);
        return;
    }

    if (std.mem.eql(u8, selectors[0], "-h") or std.mem.eql(u8, selectors[0], "--help")) {
        var buf: [4096]u8 = undefined;
        var stdout_bw = std.Io.File.stdout().writer(io, &buf);
        const out = &stdout_bw.interface;
        try out.print(
            \\Usage: btg [command] [args]
            \\
            \\  (no args)          Show ask report
            \\  ask                Commands frequently sent to vibe, not in any allow list.
            \\                     Annotated with [ask: N] when blocked, [ran: N] when executed.
            \\  stale-allow        Allow patterns with zero recorded invocations
            \\  suggest            Write Bash(cmd *) entries to .claude/settings.local.json
            \\                     from btg.post.log.jsonl for the current project
            \\  patterns <word>    Suggest ERE allow patterns for commands starting with <word>
            \\                     by feeding logged examples to vibe
            \\  flush              Delete all log files under ~/.local/var/
            \\  init               Create ~/.local/etc/btg.allow and btg.deny with starter patterns
            \\  allow <pattern>    Append an ERE pattern to ~/.local/etc/btg.allow
            \\  deny <pattern>     Append an ERE pattern to ~/.local/etc/btg.deny
            \\
            \\Log files:
            \\  ~/.local/var/btg.allow.log.jsonl   fast-pathed commands
            \\  ~/.local/var/btg.vibe.log.jsonl    vibe-evaluated commands
            \\  ~/.local/var/btg.post.log.jsonl    successfully executed allow-listable commands
            \\
        , .{});
        try out.flush();
        return;
    }

    var i: usize = 0;
    while (i < selectors.len) : (i += 1) {
        const sel = selectors[i];
        if (std.mem.eql(u8, sel, "ask")) {
            try runAskReport(io, allocator, home);
        } else if (std.mem.eql(u8, sel, "stale-allow")) {
            try runStaleAllowReport(io, allocator, home);
        } else if (std.mem.eql(u8, sel, "flush")) {
            try runFlush(io, allocator, home);
        } else if (std.mem.eql(u8, sel, "suggest")) {
            try runSuggest(io, allocator, home);
        } else if (std.mem.eql(u8, sel, "init")) {
            const exe_path = try std.process.executablePathAlloc(io, allocator);
            defer allocator.free(exe_path);
            try runInit(io, allocator, home, exe_path);
        } else if (std.mem.eql(u8, sel, "patterns")) {
            i += 1;
            if (i >= selectors.len) {
                var ebuf: [256]u8 = undefined;
                var ebw = std.Io.File.stderr().writer(io, &ebuf);
                const err_out = &ebw.interface;
                try err_out.print("Usage: btg patterns <word>\n", .{});
                try err_out.flush();
                std.process.exit(1);
            }
            try runPatterns(io, allocator, home, selectors[i]);
        } else if (std.mem.eql(u8, sel, "allow") or std.mem.eql(u8, sel, "deny")) {
            i += 1;
            if (i >= selectors.len) {
                var ebuf: [256]u8 = undefined;
                var ebw = std.Io.File.stderr().writer(io, &ebuf);
                const err_out = &ebw.interface;
                try err_out.print("Usage: btg {s} <pattern>\n", .{sel});
                try err_out.flush();
                std.process.exit(1);
            }
            if (std.mem.eql(u8, sel, "allow")) {
                try runAllow(io, allocator, home, selectors[i]);
            } else {
                try runDeny(io, allocator, home, selectors[i]);
            }
        } else {
            var ebuf: [256]u8 = undefined;
            var ebw = std.Io.File.stderr().writer(io, &ebuf);
            const err_out = &ebw.interface;
            try err_out.print("Unknown command: {s}\n", .{sel});
            try err_out.flush();
            std.process.exit(1);
        }
    }
}
