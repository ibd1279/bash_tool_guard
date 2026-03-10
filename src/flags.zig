const std = @import("std");

pub const Verdict = enum { allow, escalate, pass };

pub const Result = struct {
    verdict: Verdict,
    /// For .escalate: the flag token that triggered it (sub-slice of input, not owned).
    trigger: []const u8 = "",
};

const FlagDef = struct {
    flag: []const u8,
    verdict: Verdict,
};

const SubcmdDef = struct {
    subcmd: []const u8,
    rules: []const FlagDef,
    /// Verdict when no flag rule matches in this subcommand context.
    default: Verdict,
};

const CmdDef = struct {
    name: []const u8,
    /// Subcommand-specific rules checked before cmd_rules.
    subcmds: []const SubcmdDef,
    /// Flag rules applied when no subcommand matches (or subcmds is empty).
    cmd_rules: []const FlagDef,
    /// Verdict when no flag matches and no subcommand rule applies.
    cmd_default: Verdict,
};

/// Command flag rules. Add new entries with /add-command-flags.
const RULES: []const CmdDef = &.{
    .{
        .name = "find",
        .subcmds = &.{},
        .cmd_rules = &.{
            .{ .flag = "-exec",    .verdict = .escalate },
            .{ .flag = "-execdir", .verdict = .escalate },
            .{ .flag = "-delete",  .verdict = .escalate },
            .{ .flag = "-ok",      .verdict = .escalate },
            .{ .flag = "-okdir",   .verdict = .escalate },
        },
        .cmd_default = .pass,
    },
    .{
        .name = "git",
        .subcmds = &.{
            .{
                .subcmd = "push",
                .rules = &.{
                    .{ .flag = "--dry-run",           .verdict = .allow },
                    .{ .flag = "-n",                  .verdict = .allow },
                    .{ .flag = "--force",             .verdict = .escalate },
                    .{ .flag = "-f",                  .verdict = .escalate },
                    .{ .flag = "--force-with-lease",  .verdict = .escalate },
                    .{ .flag = "--force-if-includes", .verdict = .escalate },
                    .{ .flag = "--mirror",            .verdict = .escalate },
                    .{ .flag = "--delete",            .verdict = .escalate },
                    .{ .flag = "-d",                  .verdict = .escalate },
                    .{ .flag = "--prune",             .verdict = .escalate },
                    .{ .flag = "--no-verify",         .verdict = .escalate },
                },
                .default = .escalate,
            },
        },
        .cmd_rules = &.{},
        .cmd_default = .pass,
    },
    .{
        .name = "docker",
        .subcmds = &.{
            .{
                // docker run executes arbitrary code inside a container.
                .subcmd = "run",
                .rules = &.{
                    .{ .flag = "--privileged", .verdict = .escalate },
                    .{ .flag = "--pid",        .verdict = .escalate },
                    .{ .flag = "--network",    .verdict = .escalate },
                },
                .default = .escalate,
            },
            .{
                // docker exec opens a shell or runs a command inside a running container.
                .subcmd = "exec",
                .rules = &.{},
                .default = .escalate,
            },
            .{
                // docker system prune/df etc. — prune can delete all images/volumes.
                .subcmd = "system",
                .rules = &.{},
                .default = .escalate,
            },
        },
        .cmd_rules = &.{},
        .cmd_default = .pass,
    },
    .{
        .name = "kubectl",
        .subcmds = &.{
            .{
                // kubectl apply/create/replace modify live cluster state.
                .subcmd = "apply",
                .rules = &.{
                    .{ .flag = "--dry-run", .verdict = .allow },
                },
                .default = .escalate,
            },
            .{
                .subcmd = "create",
                .rules = &.{
                    .{ .flag = "--dry-run", .verdict = .allow },
                },
                .default = .escalate,
            },
            .{
                .subcmd = "delete",
                .rules = &.{
                    .{ .flag = "--dry-run", .verdict = .allow },
                },
                .default = .escalate,
            },
            .{
                .subcmd = "patch",
                .rules = &.{
                    .{ .flag = "--dry-run", .verdict = .allow },
                },
                .default = .escalate,
            },
            .{
                .subcmd = "edit",
                .rules = &.{},
                .default = .escalate,
            },
            .{
                // kubectl exec opens a shell/command inside a running pod.
                .subcmd = "exec",
                .rules = &.{},
                .default = .escalate,
            },
            .{
                .subcmd = "scale",
                .rules = &.{
                    .{ .flag = "--dry-run", .verdict = .allow },
                },
                .default = .escalate,
            },
            .{
                .subcmd = "rollout",
                .rules = &.{},
                .default = .escalate,
            },
        },
        .cmd_rules = &.{},
        .cmd_default = .pass,
    },
    .{
        .name = "bash",
        .subcmds = &.{},
        .cmd_rules = &.{
            .{ .flag = "-c", .verdict = .escalate },
        },
        .cmd_default = .pass,
    },
    .{
        .name = "sh",
        .subcmds = &.{},
        .cmd_rules = &.{
            .{ .flag = "-c", .verdict = .escalate },
        },
        .cmd_default = .pass,
    },
    .{
        .name = "zsh",
        .subcmds = &.{},
        .cmd_rules = &.{
            .{ .flag = "-c", .verdict = .escalate },
        },
        .cmd_default = .pass,
    },
    .{
        .name = "zig",
        .subcmds = &.{
            .{
                // zig run compiles and immediately executes a program — escalate
                // regardless of flags. zig build, test, fmt etc. are .pass.
                .subcmd = "run",
                .rules = &.{},
                .default = .escalate,
            },
        },
        .cmd_rules = &.{},
        .cmd_default = .pass,
    },
    // entries inserted here by /add-command-flags
};

/// Check `seg` (a single pipeline segment, e.g. "find /tmp -exec rm {} +") against
/// flag-level rules. Returns a Result indicating whether to escalate, allow, or pass.
pub fn check(seg: []const u8) Result {
    var it = std.mem.tokenizeAny(u8, seg, " \t");

    // First token is the command name.
    const cmd_name = it.next() orelse return .{ .verdict = .pass };
    if (cmd_name.len == 0) return .{ .verdict = .pass };

    // Find a matching CmdDef.
    const cmd_def = blk: {
        for (RULES) |r| {
            if (std.mem.eql(u8, r.name, cmd_name)) break :blk r;
        }
        return .{ .verdict = .pass };
    };

    // Find subcommand by scanning forward, skipping global flags and key=value
    // tokens (e.g. "git -c user.email=x push --force" must find "push").
    const ActiveRules = struct { rules: []const FlagDef, default: Verdict };
    const active: ActiveRules = blk: {
        if (cmd_def.subcmds.len == 0) break :blk ActiveRules{
            .rules = cmd_def.cmd_rules,
            .default = cmd_def.cmd_default,
        };

        var scan = it;
        while (scan.next()) |tok| {
            if (tok.len == 0) continue;
            if (tok[0] == '-') continue; // skip global flags
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue; // skip key=val
            for (cmd_def.subcmds) |sub| {
                if (std.mem.eql(u8, sub.subcmd, tok)) {
                    it = scan; // advance main iterator past the subcommand
                    break :blk ActiveRules{ .rules = sub.rules, .default = sub.default };
                }
            }
            // Plain token that doesn't match any subcommand: could be a flag
            // value (e.g. "/repo" after "-C"), so keep scanning rather than
            // stopping immediately.
        }
        break :blk ActiveRules{ .rules = cmd_def.cmd_rules, .default = cmd_def.cmd_default };
    };

    // Scan remaining tokens for flags.
    var result: Result = .{ .verdict = active.default };

    while (it.next()) |tok| {
        // Skip non-flag tokens.
        if (tok.len == 0 or tok[0] != '-') continue;

        // Strip =value suffix (e.g. "--output=file" → "--output").
        const flag = if (std.mem.indexOfScalar(u8, tok, '=')) |eq_pos|
            tok[0..eq_pos]
        else
            tok;

        // First try to match the whole flag against the rule set.
        var matched = false;
        for (active.rules) |rule| {
            if (std.mem.eql(u8, rule.flag, flag)) {
                matched = true;
                switch (rule.verdict) {
                    .escalate => return .{ .verdict = .escalate, .trigger = flag },
                    .allow => result = .{ .verdict = .allow },
                    .pass => {}, // no-op
                }
                break;
            }
        }

        // If the whole flag didn't match and it looks like combined short flags
        // (e.g. "-fd" → check "-f" and "-d" individually), try each character.
        // Only applies to flags without "--" prefix and longer than one char.
        if (!matched and flag.len > 2 and flag[1] != '-') {
            var char_buf = [2]u8{ '-', 0 };
            for (flag[1..]) |ch| {
                char_buf[1] = ch;
                for (active.rules) |rule| {
                    if (std.mem.eql(u8, rule.flag, char_buf[0..])) {
                        switch (rule.verdict) {
                            .escalate => return .{ .verdict = .escalate, .trigger = flag },
                            .allow => result = .{ .verdict = .allow },
                            .pass => {},
                        }
                        break;
                    }
                }
            }
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "flags: unknown command returns pass" {
    const result = check("unknowncmd --whatever");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: empty segment returns pass" {
    const result = check("");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: find -exec escalates" {
    const result = check("find . -exec rm {} ;");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
    try std.testing.expectEqualStrings("-exec", result.trigger);
}

test "flags: find -execdir escalates" {
    const result = check("find . -execdir rm {} ;");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
    try std.testing.expectEqualStrings("-execdir", result.trigger);
}

test "flags: find -delete escalates" {
    const result = check("find . -name '*.log' -delete");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: find -ok escalates" {
    const result = check("find . -ok rm {} ;");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: find -name passes" {
    const result = check("find . -name '*.txt'");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: find -type -maxdepth passes" {
    const result = check("find . -type f -maxdepth 2");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: find with no flags passes" {
    const result = check("find .");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: git push --force escalates" {
    const result = check("git push --force origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
    try std.testing.expectEqualStrings("--force", result.trigger);
}

test "flags: git push -f escalates" {
    const result = check("git push -f origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git push --force-with-lease escalates" {
    const result = check("git push --force-with-lease origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git push --no-verify escalates" {
    const result = check("git push --no-verify origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git push --dry-run allows" {
    const result = check("git push --dry-run origin main");
    try std.testing.expectEqual(Verdict.allow, result.verdict);
}

test "flags: git push -n allows" {
    const result = check("git push -n origin main");
    try std.testing.expectEqual(Verdict.allow, result.verdict);
}

test "flags: git push --dry-run --force escalates (force wins)" {
    const result = check("git push --dry-run --force origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git status is unaffected by push rules" {
    const result = check("git status");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: git push -fd escalates (combined force+delete)" {
    const result = check("git push -fd origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git push -nf dry-run beats force (allow wins)" {
    // -n is allow, -f is escalate; escalate wins
    const result = check("git push -nf origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git -c user.email=x push --force escalates" {
    const result = check("git -c user.email=x push --force");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
    try std.testing.expectEqualStrings("--force", result.trigger);
}

test "flags: git -C /repo push --force escalates" {
    const result = check("git -C /repo push --force");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: bash -ec escalates (combined flag containing c)" {
    const result = check("bash -ec 'rm -rf /'");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

// --- git push default escalation ---

test "flags: git push with no flags escalates" {
    const result = check("git push origin main");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: git push --dry-run still allows" {
    const result = check("git push --dry-run origin main");
    try std.testing.expectEqual(Verdict.allow, result.verdict);
}

test "flags: git status unaffected by push escalation" {
    const result = check("git status");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

// --- docker ---

test "flags: docker run escalates" {
    const result = check("docker run nginx");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: docker run --privileged escalates" {
    const result = check("docker run --privileged ubuntu bash");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: docker exec escalates" {
    const result = check("docker exec -it mycontainer bash");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: docker system prune escalates" {
    const result = check("docker system prune -af");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: docker ps passes" {
    const result = check("docker ps");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: docker images passes" {
    const result = check("docker images");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: docker logs passes" {
    const result = check("docker logs mycontainer");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

// --- kubectl ---

test "flags: kubectl apply escalates" {
    const result = check("kubectl apply -f deployment.yaml");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: kubectl apply --dry-run allows" {
    const result = check("kubectl apply --dry-run=client -f deployment.yaml");
    try std.testing.expectEqual(Verdict.allow, result.verdict);
}

test "flags: kubectl delete escalates" {
    const result = check("kubectl delete pod mypod");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: kubectl delete --dry-run allows" {
    const result = check("kubectl delete --dry-run=client pod mypod");
    try std.testing.expectEqual(Verdict.allow, result.verdict);
}

test "flags: kubectl exec escalates" {
    const result = check("kubectl exec -it mypod -- bash");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: kubectl get passes" {
    const result = check("kubectl get pods");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: kubectl describe passes" {
    const result = check("kubectl describe pod mypod");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: kubectl rollout escalates" {
    const result = check("kubectl rollout restart deployment/myapp");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

// --- zig ---

test "flags: zig run escalates" {
    const result = check("zig run src/main.zig");
    try std.testing.expectEqual(Verdict.escalate, result.verdict);
}

test "flags: zig build passes" {
    const result = check("zig build");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: zig test passes" {
    const result = check("zig test src/main.zig");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: zig fmt passes" {
    const result = check("zig fmt src/");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}

test "flags: zig with no subcommand passes" {
    const result = check("zig");
    try std.testing.expectEqual(Verdict.pass, result.verdict);
}
