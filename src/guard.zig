const std = @import("std");

/// Remove 'single' and "double" quoted substrings from input.
/// Returns newly allocated string.
pub fn stripQuotes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch == '\'') {
            // Skip until closing single quote
            i += 1;
            while (i < input.len and input[i] != '\'') : (i += 1) {}
            if (i < input.len) i += 1; // skip closing quote
        } else if (ch == '"') {
            // Skip until closing double quote (no escape handling for simplicity)
            i += 1;
            while (i < input.len and input[i] != '"') : (i += 1) {}
            if (i < input.len) i += 1; // skip closing quote
        } else {
            try result.append(allocator, ch);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Returns true if command contains $( or backtick outside single quotes or
/// single-quoted heredoc bodies.
/// Single-quoted regions and <<'MARKER' heredoc bodies are skipped because
/// the shell treats their content literally.
pub fn hasSubstitution(cmd: []const u8) bool {
    var i: usize = 0;
    while (i < cmd.len) {
        // Skip single-quoted region.
        if (cmd[i] == '\'') {
            i += 1;
            while (i < cmd.len and cmd[i] != '\'') : (i += 1) {}
            if (i < cmd.len) i += 1;
            continue;
        }
        // Skip single-quoted heredoc bodies (<<'MARKER'...\nMARKER).
        // Backticks inside single-quoted heredocs are literal, not substitutions.
        if (cmd[i] == '<' and i + 1 < cmd.len and cmd[i + 1] == '<') {
            var j = i + 2;
            if (j < cmd.len and cmd[j] == '-') j += 1; // optional -
            while (j < cmd.len and (cmd[j] == ' ' or cmd[j] == '\t')) : (j += 1) {}
            if (j < cmd.len and cmd[j] == '\'') {
                j += 1;
                const marker_start = j;
                while (j < cmd.len and cmd[j] != '\'') : (j += 1) {}
                const marker = cmd[marker_start..j];
                if (j < cmd.len) j += 1; // skip closing quote
                if (marker.len > 0) {
                    while (j < cmd.len and cmd[j] != '\n') : (j += 1) {} // skip intro line
                    if (j < cmd.len) j += 1;
                    while (j < cmd.len) { // skip body lines until closing marker
                        var ls = j;
                        while (ls < cmd.len and cmd[ls] == '\t') : (ls += 1) {}
                        if (ls + marker.len <= cmd.len and
                            std.mem.eql(u8, cmd[ls .. ls + marker.len], marker))
                        {
                            const after = ls + marker.len;
                            if (after >= cmd.len or cmd[after] == '\n' or
                                cmd[after] == '\r' or cmd[after] == ')' or cmd[after] == ' ')
                            {
                                j = after;
                                while (j < cmd.len and cmd[j] != '\n') : (j += 1) {}
                                if (j < cmd.len) j += 1;
                                break;
                            }
                        }
                        while (j < cmd.len and cmd[j] != '\n') : (j += 1) {}
                        if (j < cmd.len) j += 1;
                    }
                    i = j;
                    continue;
                }
            }
        }
        if (cmd[i] == '`') return true;
        if (cmd[i] == '$' and i + 1 < cmd.len and cmd[i + 1] == '(') return true;
        i += 1;
    }
    return false;
}

/// Replace heredoc body content with spaces, preserving newlines.
/// Handles <<'MARKER', <<"MARKER", <<\MARKER, <<MARKER and <<-MARKER variants.
/// Used before segment splitting to prevent heredoc body text from being
/// classified as commands in reports.
pub fn stripHeredocBodies(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, cmd);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) {
        if (!(i + 1 < out.len and out[i] == '<' and out[i + 1] == '<')) {
            i += 1;
            continue;
        }
        i += 2;
        if (i < out.len and out[i] == '-') i += 1; // optional -
        while (i < out.len and (out[i] == ' ' or out[i] == '\t')) : (i += 1) {}

        // Extract marker, stripping any surrounding quotes.
        var marker_buf: [128]u8 = undefined;
        var mlen: usize = 0;
        if (i < out.len and (out[i] == '\'' or out[i] == '"')) {
            const q = out[i];
            i += 1;
            while (i < out.len and out[i] != q and mlen < marker_buf.len) {
                marker_buf[mlen] = out[i];
                mlen += 1;
                i += 1;
            }
            if (i < out.len) i += 1;
        } else if (i < out.len and out[i] == '\\') {
            i += 1;
            while (i < out.len and out[i] != ' ' and out[i] != '\t' and
                out[i] != '\n' and mlen < marker_buf.len)
            {
                marker_buf[mlen] = out[i];
                mlen += 1;
                i += 1;
            }
        } else {
            while (i < out.len and out[i] != ' ' and out[i] != '\t' and
                out[i] != '\n' and out[i] != ')' and mlen < marker_buf.len)
            {
                marker_buf[mlen] = out[i];
                mlen += 1;
                i += 1;
            }
        }
        if (mlen == 0) continue;
        const marker = marker_buf[0..mlen];

        // Skip to end of intro line (the <<'EOF' line itself).
        while (i < out.len and out[i] != '\n') : (i += 1) {}
        if (i < out.len) i += 1;

        // Blank body lines until the closing marker.
        while (i < out.len) {
            var ls = i;
            while (ls < out.len and out[ls] == '\t') : (ls += 1) {} // skip leading tabs (<<-)
            if (ls + marker.len <= out.len and
                std.mem.eql(u8, out[ls .. ls + marker.len], marker))
            {
                const after = ls + marker.len;
                if (after >= out.len or out[after] == '\n' or out[after] == '\r' or
                    out[after] == ')' or out[after] == ' ')
                {
                    i = after;
                    while (i < out.len and out[i] != '\n') : (i += 1) {}
                    if (i < out.len) i += 1;
                    break;
                }
            }
            while (i < out.len and out[i] != '\n') {
                out[i] = ' ';
                i += 1;
            }
            if (i < out.len) i += 1; // preserve \n
        }
    }
    return out;
}

/// Returns true if command has a file-writing redirect after stripping safe patterns.
/// Implements manual string scanning without regex.
pub fn hasUnsafeRedirect(allocator: std.mem.Allocator, cmd: []const u8) !bool {
    // Work on a mutable buffer we can shrink by replacing removed regions with spaces
    var buf = try allocator.dupe(u8, cmd);
    defer allocator.free(buf);

    // Step 0: blank out quoted regions — > inside quotes is not a redirect.
    {
        var i: usize = 0;
        while (i < buf.len) {
            if (buf[i] == '\'' or buf[i] == '"') {
                const close = buf[i];
                i += 1;
                while (i < buf.len and buf[i] != close) : (i += 1) {
                    buf[i] = ' ';
                }
                if (i < buf.len) i += 1; // skip closing quote
            } else {
                i += 1;
            }
        }
    }

    // Step 1: Remove fd redirects like N>&M or >&M or N>& (digits optional on either side)
    // Pattern: [0-9]*>&[0-9]*
    {
        var i: usize = 0;
        while (i < buf.len) {
            // Find >& sequence
            if (buf[i] == '>' and i + 1 < buf.len and buf[i + 1] == '&') {
                // Walk back to find leading digits
                var start = i;
                if (start > 0) {
                    var j = i;
                    while (j > 0 and std.ascii.isDigit(buf[j - 1])) : (j -= 1) {}
                    start = j;
                }
                // Walk forward past >& and trailing digits
                var end = i + 2;
                while (end < buf.len and std.ascii.isDigit(buf[end])) : (end += 1) {}
                // Blank out the region
                @memset(buf[start..end], ' ');
                i = end;
            } else {
                i += 1;
            }
        }
    }

    // Helper: remove all occurrences of a literal string by blanking with spaces
    const removeAll = struct {
        fn run(b: []u8, needle: []const u8) void {
            var start: usize = 0;
            while (std.mem.indexOf(u8, b[start..], needle)) |rel| {
                const abs = start + rel;
                @memset(b[abs .. abs + needle.len], ' ');
                start = abs + needle.len;
            }
        }
    }.run;

    // Step 2: Remove &>/dev/null
    removeAll(buf, "&>/dev/null");

    // Step 3: Remove N>/dev/null and N>>/dev/null (N is an optional leading digit).
    {
        var i: usize = 0;
        while (i < buf.len) {
            const start = i;
            var j = i;
            if (j < buf.len and std.ascii.isDigit(buf[j])) j += 1;
            if (j < buf.len and buf[j] == '>') {
                j += 1;
                if (j < buf.len and buf[j] == '>') j += 1; // consume optional second >
                const null_dev = "/dev/null";
                if (j + null_dev.len <= buf.len and std.mem.eql(u8, buf[j .. j + null_dev.len], null_dev)) {
                    @memset(buf[start .. j + null_dev.len], ' ');
                    i = j + null_dev.len;
                    continue;
                }
            }
            i += 1;
        }
    }

    // Step 4: Remove <<< then <<
    removeAll(buf, "<<<");
    removeAll(buf, "<<");

    // Step 5: Remove <( then <
    removeAll(buf, "<(");
    removeAll(buf, "<");

    // Step 6: Check if > remains
    return std.mem.indexOfScalar(u8, buf, '>') != null;
}

// --- Wrapper splitting helpers ---

fn skipWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

fn skipTok(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    return i;
}

pub const WrapperSplit = struct {
    /// The wrapper invocation (e.g. "timeout 30", "env APIKEY=foo").
    wrapper_part: []const u8,
    /// The sub-command to be evaluated independently.
    inner_part: []const u8,
    /// When true, the wrapper command itself does not need an allow-list match —
    /// only the inner target is checked. Used for shells (bash, sh, zsh).
    implicit: bool = false,
};

/// If `seg` begins with a known transparent wrapper command, split it into
/// the wrapper invocation and the sub-command. Returns null if not a known
/// wrapper or if the wrapper has no sub-command following it.
///
/// Supported wrappers and what they consume before the sub-command:
///   nohup    — no own args
///   time     — optional flags (e.g. -p)
///   env      — flags (some with values) + VAR=value assignments
///   timeout  — flags (some with values) + one positional DURATION argument
///   nice     — optional -n increment flag, then sub-command
///   bash     — optional behavior flags + optional script file (implicit; -c returns null)
///   sh       — optional behavior flags + optional script file (implicit; -c returns null)
///   zsh      — optional behavior flags + optional script file (implicit; -c returns null)
///   jexec    — flags (some with values) + one positional jail id/name, then sub-command
///   doas     — flags (some with values) + optional --, then sub-command
///   bastille — global flags + 'cmd' subcommand + cmd flags + TARGET, then sub-command
///   pot      — 'exec' subcommand + flags (-e/-u/-U/-p take values), then sub-command
pub fn splitWrapper(seg: []const u8) ?WrapperSplit {
    const first_end = skipTok(seg, 0);
    if (first_end == 0) return null;
    const first = seg[0..first_end];

    var i: usize = first_end;

    if (std.mem.eql(u8, first, "nohup")) {
        // nohup COMMAND [ARG]... — no own args
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else if (std.mem.eql(u8, first, "time")) {
        // time [-p] COMMAND [ARG]... — skip optional flags
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            i = skipTok(seg, i);
        }
    } else if (std.mem.eql(u8, first, "env")) {
        // env [OPTION] [VAR=VALUE]... COMMAND [ARG]...
        // Skip flags (some consume a value), then VAR=value tokens; first plain
        // token is the sub-command.
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            if (tok.len == 0) return null;
            if (tok[0] == '-') {
                // Flags that take a separate value token (no '=' embedded)
                const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                    (std.mem.eql(u8, tok, "-u") or
                    std.mem.eql(u8, tok, "-C") or
                    std.mem.eql(u8, tok, "--unset") or
                    std.mem.eql(u8, tok, "--chdir") or
                    std.mem.eql(u8, tok, "--split-string"));
                if (takes_val) {
                    i = skipWs(seg, i);
                    i = skipTok(seg, i);
                }
            } else if (std.mem.indexOfScalar(u8, tok, '=') != null) {
                // VAR=value assignment — continue
            } else {
                // First plain token: this is the sub-command; rewind
                i = tok_start;
                break;
            }
        }
    } else if (std.mem.eql(u8, first, "timeout")) {
        // timeout [OPTION] DURATION COMMAND [ARG]...
        // Skip flags (some consume a value), then skip the DURATION positional.
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            // -s/--signal and -k/--kill-after take a separate value token
            const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                (std.mem.eql(u8, tok, "-s") or
                std.mem.eql(u8, tok, "-k") or
                std.mem.eql(u8, tok, "--signal") or
                std.mem.eql(u8, tok, "--kill-after"));
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
        // Skip DURATION (one positional arg)
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        i = skipTok(seg, i);
        // Now at sub-command
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else if (std.mem.eql(u8, first, "nice")) {
        // nice [-n increment] COMMAND [ARG]...
        // -n takes a separate value token; deprecated -N form (e.g. -5) is
        // self-contained and handled by the generic flag-skip branch.
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            const takes_val = std.mem.eql(u8, tok, "-n");
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
    } else if (std.mem.eql(u8, first, "bash") or
               std.mem.eql(u8, first, "sh") or
               std.mem.eql(u8, first, "zsh"))
    {
        // bash/sh/zsh [options] script [args...]
        // Transparent wrapper for script-file execution.
        // Return null for -c (string execution) so flags.check can escalate it.
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null; // bare shell with no script
            if (seg[i] == '-') {
                const tok_start = i;
                i = skipTok(seg, i);
                const tok = seg[tok_start..i];
                // Short flags may combine chars: -ec means -e -c.  Return null if
                // any character in the flag group is 'c' (string execution).
                if (tok.len >= 2 and tok[1] != '-') {
                    for (tok[1..]) |ch| if (ch == 'c') return null;
                }
                if (std.mem.eql(u8, tok, "--")) break; // end of options
                // -O and --init-file/--rcfile take a separate value token
                if (std.mem.eql(u8, tok, "-O") or
                    std.mem.eql(u8, tok, "--init-file") or
                    std.mem.eql(u8, tok, "--rcfile"))
                {
                    i = skipWs(seg, i);
                    i = skipTok(seg, i);
                }
                // All other flags (-e -x -u -i -l -r -s -D -v -n --posix etc.)
                // are boolean behavior modifiers; already skipped by skipTok above.
            } else {
                break; // found the script positional
            }
        }
        // i may be at whitespace before the script filename; skip it.
        i = skipWs(seg, i);
        const inner_start_shell = i;
        if (inner_start_shell >= seg.len) return null;
        return .{
            .wrapper_part = std.mem.trimRight(u8, seg[0..inner_start_shell], " \t"),
            .inner_part = seg[inner_start_shell..],
            .implicit = true,
        };
    } else if (std.mem.eql(u8, first, "jexec")) {
        // jexec [-l] [-d dir] [-u user | -U user] jail COMMAND [ARG]...
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            // -d, -u, -U take a separate value token
            const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                (std.mem.eql(u8, tok, "-d") or
                std.mem.eql(u8, tok, "-u") or
                std.mem.eql(u8, tok, "-U"));
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
        // Skip jail id/name (one positional)
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        i = skipTok(seg, i);
        // Now at sub-command
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else if (std.mem.eql(u8, first, "doas")) {
        // doas [-nSs] [-a style] [-C config] [-u user] [--] COMMAND [ARG]...
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            if (std.mem.eql(u8, tok, "--")) break; // end of options
            // -a, -C, -u take a separate value token
            const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                (std.mem.eql(u8, tok, "-a") or
                std.mem.eql(u8, tok, "-C") or
                std.mem.eql(u8, tok, "-u"));
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
        // Skip whitespace after flags or after consuming '--'
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else if (std.mem.eql(u8, first, "bastille")) {
        // bastille [-vh] [-c file] cmd [-ax] TARGET COMMAND [ARG]...
        // Only the 'cmd' subcommand executes arbitrary commands inside a jail;
        // other subcommands (start, stop, pkg, …) are not transparent wrappers.
        // Skip global flags
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            // -c/--config takes a separate value token
            const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                (std.mem.eql(u8, tok, "-c") or
                std.mem.eql(u8, tok, "--config"));
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
        // Require 'cmd' subcommand
        const bastille_sub_start = i;
        i = skipTok(seg, i);
        if (!std.mem.eql(u8, seg[bastille_sub_start..i], "cmd")) return null;
        // Skip cmd-level flags (-a/--auto, -x/--debug — all boolean)
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            i = skipTok(seg, i);
        }
        // Skip TARGET (one positional)
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        i = skipTok(seg, i);
        // Now at sub-command
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else if (std.mem.eql(u8, first, "pot")) {
        // pot exec [-hvdt] [-e var=value] [-u user] [-U user] -p pot COMMAND [ARG]...
        // Only the 'exec' subcommand runs arbitrary commands inside a pot.
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        const pot_sub_start = i;
        i = skipTok(seg, i);
        if (!std.mem.eql(u8, seg[pot_sub_start..i], "exec")) return null;
        // Skip flags; -e, -u, -U, -p each take a separate value token
        while (true) {
            i = skipWs(seg, i);
            if (i >= seg.len) return null;
            if (seg[i] != '-') break;
            const tok_start = i;
            i = skipTok(seg, i);
            const tok = seg[tok_start..i];
            const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
                (std.mem.eql(u8, tok, "-e") or
                std.mem.eql(u8, tok, "-u") or
                std.mem.eql(u8, tok, "-U") or
                std.mem.eql(u8, tok, "-p"));
            if (takes_val) {
                i = skipWs(seg, i);
                i = skipTok(seg, i);
            }
        }
        // Now at COMMAND
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
    } else {
        return null;
    }

    const inner_start = i;
    if (inner_start >= seg.len) return null;

    return .{
        .wrapper_part = std.mem.trimRight(u8, seg[0..inner_start], " \t"),
        .inner_part = seg[inner_start..],
    };
}

/// Expand a segment by recursively splitting known wrapper commands, appending
/// each part to `out`. For example "timeout 30 git status" appends
/// "timeout 30" then "git status". No allocation beyond the ArrayList.
pub fn expandWrappers(allocator: std.mem.Allocator, seg: []const u8, out: *std.ArrayList([]const u8)) !void {
    var current = seg;
    while (splitWrapper(current)) |split| {
        if (!split.implicit) try out.append(allocator, split.wrapper_part);
        current = split.inner_part;
    }
    try out.append(allocator, current);
}

/// Classification of a shell segment: pure shell structure (safe, skip) or
/// an actual command to be evaluated against allow/deny patterns.
pub const SegmentClass = union(enum) {
    /// Pure shell keyword, test builtin, variable assignment, or loop header —
    /// inherently safe shell syntax with no external command to evaluate.
    shell_structure,
    /// An actual command. The slice is a substring of the original segment,
    /// with any leading shell keyword or variable-assignment prefix removed.
    command: []const u8,
};

/// Returns true if `word` is a shell variable assignment name: matches
/// [A-Za-z_][A-Za-z0-9_]*= (no substitution — that was checked upstream).
fn isVarAssign(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    const name = word[0..eq];
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Classify a shell segment as pure structure or an actual command.
///
/// Shell keywords, test builtins, variable assignments, and loop/case headers
/// are classified as `.shell_structure` — safe to skip without pattern
/// matching.  For segments with a command-bearing keyword prefix
/// (`if CMD`, `then CMD`, `do CMD`, etc.) or a variable-assignment prefix
/// (`VAR=val CMD`), the prefix is stripped and the remainder is returned as
/// `.command`.  The returned slice is a substring of `seg` — no allocation.
pub fn classifySegment(seg: []const u8) SegmentClass {
    var s = std.mem.trim(u8, seg, " \t");
    while (true) {
        if (s.len == 0) return .shell_structure;

        const first_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        const first = s[0..first_end];
        const rest = if (first_end < s.len) std.mem.trimLeft(u8, s[first_end..], " \t") else "";

        // Shell comments.
        if (first[0] == '#') return .shell_structure;

        // Test builtins [ ... ] and [[ ... ]] are side-effect-free reads.
        if (std.mem.eql(u8, first, "[") or std.mem.eql(u8, first, "[[")) return .shell_structure;

        // Pure structural keywords — nothing to evaluate.
        for (&[_][]const u8{ "fi", "done", "esac", "in" }) |kw| {
            if (std.mem.eql(u8, first, kw)) return .shell_structure;
        }

        // Loop / case headers have no command to execute.
        if (std.mem.eql(u8, first, "for") or std.mem.eql(u8, first, "case")) {
            return .shell_structure;
        }

        // Keywords that may carry a command after them — strip and loop.
        var is_cmd_kw = false;
        for (&[_][]const u8{ "if", "while", "until", "elif", "then", "do", "else" }) |kw| {
            if (std.mem.eql(u8, first, kw)) {
                is_cmd_kw = true;
                break;
            }
        }
        if (is_cmd_kw) {
            if (rest.len == 0) return .shell_structure;
            s = rest;
            continue;
        }

        // Variable-assignment prefix: NAME=value [NAME=value ...] [CMD ...].
        // No-substitution was verified upstream; the value is a literal string.
        if (isVarAssign(first)) {
            if (rest.len == 0) return .shell_structure;
            s = rest;
            continue;
        }

        return .{ .command = s };
    }
}

// --- Segment splitting ---

/// Split command by &&, ||, |, ;, \n into segments (trim whitespace, skip empty).
/// Quote-aware: separators inside single-quoted or double-quoted strings are not
/// treated as separators.  Double-quoted regions honour backslash-escaping of `"`.
pub fn splitSegments(allocator: std.mem.Allocator, cmd: []const u8) ![][]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    var in_single_quote: bool = false;
    var in_double_quote: bool = false;

    while (i < cmd.len) {
        const ch = cmd[i];

        // Track single-quote state (only when not inside a double-quoted region).
        if (ch == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }

        // Track double-quote state (only when not inside a single-quoted region).
        if (ch == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        // Inside a double-quoted region, a backslash escapes the next character.
        // Advance past the escape sequence so `\"` does not prematurely close the quote.
        if (in_double_quote and ch == '\\' and i + 1 < cmd.len) {
            i += 2;
            continue;
        }

        // While inside any quoted region, characters are literal — never separators.
        if (in_single_quote or in_double_quote) {
            i += 1;
            continue;
        }

        // Outside quotes: check 2-char tokens first (&&, ||).
        if (i + 1 < cmd.len) {
            const two = cmd[i .. i + 2];
            if (std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||")) {
                const seg = std.mem.trim(u8, cmd[start..i], " \t\r\n");
                if (seg.len > 0) try segments.append(allocator, seg);
                i += 2;
                start = i;
                continue;
            }
        }

        // Outside quotes: check 1-char separator tokens.
        if (ch == '|' or ch == ';' or ch == '\n') {
            const seg = std.mem.trim(u8, cmd[start..i], " \t\r\n");
            if (seg.len > 0) try segments.append(allocator, seg);
            i += 1;
            start = i;
            continue;
        }

        i += 1;
    }

    // Remaining segment
    const seg = std.mem.trim(u8, cmd[start..], " \t\r\n");
    if (seg.len > 0) try segments.append(allocator, seg);

    return segments.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// --- stripQuotes ---

test "stripQuotes: single-quoted content removed" {
    const allocator = std.testing.allocator;
    const result = try stripQuotes(allocator, "rm 'evil file'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("rm ", result);
}

test "stripQuotes: double-quoted content removed" {
    const allocator = std.testing.allocator;
    const result = try stripQuotes(allocator, "echo \"hello\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("echo ", result);
}

test "stripQuotes: no quotes unchanged" {
    const allocator = std.testing.allocator;
    const result = try stripQuotes(allocator, "no quotes");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no quotes", result);
}

// --- hasSubstitution ---

test "hasSubstitution: plain command returns false" {
    try std.testing.expect(!hasSubstitution("git status"));
}

test "hasSubstitution: dollar-paren returns true" {
    try std.testing.expect(hasSubstitution("echo $(pwd)"));
}

test "hasSubstitution: backtick returns true" {
    try std.testing.expect(hasSubstitution("echo `pwd`"));
}

test "hasSubstitution: bare dollar variable returns false" {
    try std.testing.expect(!hasSubstitution("$HOME/bin"));
}

// --- hasUnsafeRedirect ---

test "hasUnsafeRedirect: plain command returns false" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "git log"));
}

test "hasUnsafeRedirect: redirect to file returns true" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try hasUnsafeRedirect(allocator, "cmd > file"));
}

test "hasUnsafeRedirect: 2>/dev/null is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd 2>/dev/null"));
}

test "hasUnsafeRedirect: &>/dev/null is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd &>/dev/null"));
}

test "hasUnsafeRedirect: >&2 fd redirect is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd >&2"));
}

test "hasUnsafeRedirect: 2>&1 fd redirect is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd 2>&1"));
}

test "hasUnsafeRedirect: heredoc input is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd << EOF"));
}

test "hasUnsafeRedirect: redirect to file with safe stderr is unsafe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try hasUnsafeRedirect(allocator, "cmd > file 2>/dev/null"));
}

// --- splitSegments ---

test "splitSegments: && separates into three segments" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "a && b && c");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqualStrings("a", segs[0]);
    try std.testing.expectEqualStrings("b", segs[1]);
    try std.testing.expectEqualStrings("c", segs[2]);
}

test "splitSegments: pipe separates two segments" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "a | b");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("a", segs[0]);
    try std.testing.expectEqualStrings("b", segs[1]);
}

test "splitSegments: || separates two segments" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "a || b");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("a", segs[0]);
    try std.testing.expectEqualStrings("b", segs[1]);
}

test "splitSegments: semicolon separates two segments" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "a ; b");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("a", segs[0]);
    try std.testing.expectEqualStrings("b", segs[1]);
}

test "splitSegments: single command returns one segment" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "single");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("single", segs[0]);
}

test "splitSegments: padded command is trimmed" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "  spaced  ");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("spaced", segs[0]);
}

test "splitSegments: newline separates statements" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "a\nb");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("a", segs[0]);
    try std.testing.expectEqualStrings("b", segs[1]);
}

test "splitSegments: comment line and command on separate lines split correctly" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "# count things\ngrep foo bar");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("# count things", segs[0]);
    try std.testing.expectEqualStrings("grep foo bar", segs[1]);
}

test "splitSegments: pipe inside double-quoted arg is not a separator" {
    const allocator = std.testing.allocator;
    // The | inside "foo\|bar" is literal; the | between grep and head is a separator.
    const segs = try splitSegments(allocator, "grep -n \"foo\\|bar\" file | head");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("grep -n \"foo\\|bar\" file", segs[0]);
    try std.testing.expectEqualStrings("head", segs[1]);
}

test "splitSegments: newline inside double-quoted arg is not a separator" {
    const allocator = std.testing.allocator;
    // An actual newline embedded inside double quotes must not split the segment.
    const segs = try splitSegments(allocator, "git commit -m \"line1\nline2\"");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("git commit -m \"line1\nline2\"", segs[0]);
}

test "splitSegments: semicolon inside single-quoted arg is not a separator" {
    const allocator = std.testing.allocator;
    const segs = try splitSegments(allocator, "echo 'a;b;c'");
    defer allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("echo 'a;b;c'", segs[0]);
}

// --- splitWrapper ---

test "splitWrapper: nohup splits correctly" {
    const result = splitWrapper("nohup git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("nohup", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: time -p splits correctly" {
    const result = splitWrapper("time -p git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("time -p", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: timeout 30 splits correctly" {
    const result = splitWrapper("timeout 30 git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("timeout 30", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: timeout -s TERM 30 splits correctly" {
    const result = splitWrapper("timeout -s TERM 30 git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("timeout -s TERM 30", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: env APIKEY=foo splits correctly" {
    const result = splitWrapper("env APIKEY=foo git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("env APIKEY=foo", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: env -u HOME splits correctly" {
    const result = splitWrapper("env -u HOME git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("env -u HOME", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: plain git is not a wrapper" {
    try std.testing.expect(splitWrapper("git status") == null);
}

test "splitWrapper: nohup alone has no sub-command" {
    try std.testing.expect(splitWrapper("nohup") == null);
}

test "splitWrapper: timeout 30 with no command is null" {
    try std.testing.expect(splitWrapper("timeout 30") == null);
}

test "splitWrapper: nice -n 5 splits correctly" {
    const result = splitWrapper("nice -n 5 git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("nice -n 5", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: nice with negative increment splits correctly" {
    const result = splitWrapper("nice -n -10 git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("nice -n -10", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: nice no flags splits correctly" {
    const result = splitWrapper("nice git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("nice", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: nice alone has no sub-command" {
    try std.testing.expect(splitWrapper("nice") == null);
}

test "splitWrapper: bash script.sh splits transparently" {
    const result = splitWrapper("bash script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bash", result.?.wrapper_part);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
    try std.testing.expect(result.?.implicit == true);
}

test "splitWrapper: bash -e script.sh skips option flag" {
    const result = splitWrapper("bash -e script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
    try std.testing.expect(result.?.implicit == true);
}

test "splitWrapper: bash -ex script.sh skips combined option flags" {
    const result = splitWrapper("bash -ex script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
}

test "splitWrapper: bash -c returns null (string execution)" {
    try std.testing.expect(splitWrapper("bash -c something") == null);
}

test "splitWrapper: bash -ec returns null (combined flag with c)" {
    try std.testing.expect(splitWrapper("bash -ec something") == null);
}

test "splitWrapper: bare bash returns null" {
    try std.testing.expect(splitWrapper("bash") == null);
}

test "splitWrapper: bash -- script.sh handles end-of-options" {
    const result = splitWrapper("bash -- script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
}

test "splitWrapper: sh script.sh is implicit wrapper" {
    const result = splitWrapper("sh script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
    try std.testing.expect(result.?.implicit == true);
}

test "splitWrapper: zsh script.sh is implicit wrapper" {
    const result = splitWrapper("zsh script.sh");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("script.sh", result.?.inner_part);
    try std.testing.expect(result.?.implicit == true);
}

test "splitWrapper: jexec jail splits correctly" {
    const result = splitWrapper("jexec myjail git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("jexec myjail", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: jexec -u user jail splits correctly" {
    const result = splitWrapper("jexec -u root myjail git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("jexec -u root myjail", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: jexec alone has no sub-command" {
    try std.testing.expect(splitWrapper("jexec myjail") == null);
}

test "splitWrapper: doas splits correctly" {
    const result = splitWrapper("doas git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("doas", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: doas -u user splits correctly" {
    const result = splitWrapper("doas -u root git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("doas -u root", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: doas -- splits correctly" {
    const result = splitWrapper("doas -- git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("doas --", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: doas alone has no sub-command" {
    try std.testing.expect(splitWrapper("doas") == null);
}

test "splitWrapper: bastille cmd splits correctly" {
    const result = splitWrapper("bastille cmd myjail git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bastille cmd myjail", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: bastille cmd with subopts splits correctly" {
    const result = splitWrapper("bastille cmd -a myjail git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bastille cmd -a myjail", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: bastille non-cmd subcommand returns null" {
    try std.testing.expect(splitWrapper("bastille start myjail") == null);
}

test "splitWrapper: pot exec -p potname splits correctly" {
    const result = splitWrapper("pot exec -p mypot git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("pot exec -p mypot", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: pot exec -p potname alone returns null" {
    try std.testing.expect(splitWrapper("pot exec -p mypot") == null);
}

test "splitWrapper: pot term returns null (not an exec wrapper)" {
    try std.testing.expect(splitWrapper("pot term -p mypot") == null);
}

test "expandWrappers: bash script.sh yields only script.sh (implicit)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    try expandWrappers(allocator, "bash run_tests.sh", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("run_tests.sh", out.items[0]);
}

test "expandWrappers: nohup still yields wrapper_part (non-implicit)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    try expandWrappers(allocator, "nohup git status", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("nohup", out.items[0]);
    try std.testing.expectEqualStrings("git status", out.items[1]);
}

// --- expandWrappers ---

test "expandWrappers: timeout 30 nohup git status expands to three parts" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    try expandWrappers(allocator, "timeout 30 nohup git status", &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("timeout 30", out.items[0]);
    try std.testing.expectEqualStrings("nohup", out.items[1]);
    try std.testing.expectEqualStrings("git status", out.items[2]);
}

test "expandWrappers: plain git status stays as one part" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    try expandWrappers(allocator, "git status", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("git status", out.items[0]);
}

// --- classifySegment ---

test "classifySegment: shell comment is shell_structure" {
    try std.testing.expect(classifySegment("# count things") == .shell_structure);
}

test "classifySegment: fi is shell_structure" {
    try std.testing.expect(classifySegment("fi") == .shell_structure);
}

test "classifySegment: done is shell_structure" {
    try std.testing.expect(classifySegment("done") == .shell_structure);
}

test "classifySegment: esac is shell_structure" {
    try std.testing.expect(classifySegment("esac") == .shell_structure);
}

test "classifySegment: bare then is shell_structure" {
    try std.testing.expect(classifySegment("then") == .shell_structure);
}

test "classifySegment: bare do is shell_structure" {
    try std.testing.expect(classifySegment("do") == .shell_structure);
}

test "classifySegment: bare else is shell_structure" {
    try std.testing.expect(classifySegment("else") == .shell_structure);
}

test "classifySegment: for loop header is shell_structure" {
    try std.testing.expect(classifySegment("for f in *.txt") == .shell_structure);
}

test "classifySegment: case header is shell_structure" {
    try std.testing.expect(classifySegment("case $x in") == .shell_structure);
}

test "classifySegment: test builtin [ is shell_structure" {
    try std.testing.expect(classifySegment("[ -f foo ]") == .shell_structure);
}

test "classifySegment: test builtin [[ is shell_structure" {
    try std.testing.expect(classifySegment("[[ -n $str ]]") == .shell_structure);
}

test "classifySegment: if with test builtin is shell_structure" {
    try std.testing.expect(classifySegment("if [ -f foo ]") == .shell_structure);
}

test "classifySegment: while with test builtin is shell_structure" {
    try std.testing.expect(classifySegment("while [[ $i -lt 10 ]]") == .shell_structure);
}

test "classifySegment: variable assignment alone is shell_structure" {
    try std.testing.expect(classifySegment("FOO=bar") == .shell_structure);
}

test "classifySegment: then CMD returns command remainder" {
    const cls = classifySegment("then git status");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git status", cls.command);
}

test "classifySegment: if CMD returns command remainder" {
    const cls = classifySegment("if git diff --quiet");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git diff --quiet", cls.command);
}

test "classifySegment: do CMD returns command remainder" {
    const cls = classifySegment("do cat file.txt");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("cat file.txt", cls.command);
}

test "classifySegment: elif CMD returns command remainder" {
    const cls = classifySegment("elif git diff --quiet");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git diff --quiet", cls.command);
}

test "classifySegment: VAR=val CMD returns command remainder" {
    const cls = classifySegment("FOO=bar git status");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git status", cls.command);
}

test "classifySegment: plain command is command" {
    const cls = classifySegment("git status");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git status", cls.command);
}

test "classifySegment: leading whitespace is trimmed" {
    const cls = classifySegment("  git status  ");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git status", cls.command);
}

test "classifySegment: multiple VAR=val prefixes all stripped" {
    const cls = classifySegment("A=1 B=2 git status");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git status", cls.command);
}

test "classifySegment: consecutive keywords stripped (then do CMD)" {
    const cls = classifySegment("then do git pull");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git pull", cls.command);
}

test "hasSubstitution: single-quoted dollar-paren is NOT substitution" {
    try std.testing.expect(!hasSubstitution("echo '$(pwd)'"));
}

test "hasSubstitution: double-quoted dollar-paren IS substitution" {
    try std.testing.expect(hasSubstitution("echo \"$(pwd)\""));
}

test "hasSubstitution: single-quoted backtick is NOT substitution" {
    try std.testing.expect(!hasSubstitution("echo '`pwd`'"));
}

test "hasUnsafeRedirect: double-quoted > is not a redirect" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "echo \"cmd > output\""));
}

test "hasUnsafeRedirect: single-quoted > is not a redirect" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "echo '>'"));
}

test "hasUnsafeRedirect: >>/dev/null is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd >>/dev/null"));
}

test "hasUnsafeRedirect: 2>>/dev/null is safe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try hasUnsafeRedirect(allocator, "cmd 2>>/dev/null"));
}

test "hasUnsafeRedirect: >> to a file is unsafe" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try hasUnsafeRedirect(allocator, "cmd >> file"));
}

test "classifySegment: until with condition returns command remainder" {
    const cls = classifySegment("until git diff --quiet");
    try std.testing.expect(std.meta.activeTag(cls) == .command);
    try std.testing.expectEqualStrings("git diff --quiet", cls.command);
}

test "classifySegment: bare until is shell_structure" {
    try std.testing.expect(classifySegment("until") == .shell_structure);
}

// --- hasSubstitution: heredoc cases ---

test "hasSubstitution: single-quoted heredoc body with backtick is NOT substitution" {
    // <<'EOF' bodies are literal; backticks inside are not substitutions.
    try std.testing.expect(!hasSubstitution("cat <<'EOF'\n`date`\nEOF"));
}

test "hasSubstitution: unquoted heredoc body with backtick IS substitution" {
    // <<EOF bodies expand; backticks inside are substitutions.
    try std.testing.expect(hasSubstitution("cat <<EOF\n`date`\nEOF"));
}

// --- stripHeredocBodies ---

test "stripHeredocBodies: single-quoted marker, body blanked" {
    const allocator = std.testing.allocator;
    const input = "git commit -m <<'EOF'\nmy message\ninit\nEOF";
    const result = try stripHeredocBodies(allocator, input);
    defer allocator.free(result);
    // Body lines replaced with spaces; newlines preserved; marker lines kept.
    try std.testing.expect(std.mem.indexOf(u8, result, "init") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "git commit") != null);
}

test "stripHeredocBodies: unquoted marker, body blanked" {
    const allocator = std.testing.allocator;
    const input = "cat <<EOF\nsome body\nEOF";
    const result = try stripHeredocBodies(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "some body") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cat") != null);
}

test "stripHeredocBodies: no heredoc, input unchanged" {
    const allocator = std.testing.allocator;
    const input = "git status";
    const result = try stripHeredocBodies(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripHeredocBodies: double-quoted marker, body blanked" {
    const allocator = std.testing.allocator;
    const input = "cat <<\"MARKER\"\nbody line\nMARKER";
    const result = try stripHeredocBodies(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "body line") == null);
}
