const std = @import("std");
const c = @cImport({
    @cInclude("regex.h");
});

/// Load a pattern file: skip blank lines and lines starting with '#'.
/// Returns owned slice of owned pattern strings.
pub fn loadPatterns(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer allocator.free(contents);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        const owned = try allocator.dupe(u8, line);
        try list.append(allocator, owned);
    }

    return try list.toOwnedSlice(allocator);
}

/// Expand non-POSIX ERE escape sequences to portable POSIX equivalents.
/// REG_ENHANCED (macOS-only) supports \b, \s, \S, \w, \W, \d, \D — this
/// function replaces them so patterns work with plain REG_EXTENDED everywhere.
fn expandEreEscapes(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 1 < pattern.len and pattern[i] == '\\') {
            switch (pattern[i + 1]) {
                'b' => { try out.appendSlice(allocator, "([^[:alnum:]_]|$)"); i += 2; },
                's' => { try out.appendSlice(allocator, "[[:space:]]");        i += 2; },
                'S' => { try out.appendSlice(allocator, "[^[:space:]]");       i += 2; },
                'w' => { try out.appendSlice(allocator, "[[:alnum:]_]");       i += 2; },
                'W' => { try out.appendSlice(allocator, "[^[:alnum:]_]");      i += 2; },
                'd' => { try out.appendSlice(allocator, "[[:digit:]]");        i += 2; },
                'D' => { try out.appendSlice(allocator, "[^[:digit:]]");       i += 2; },
                else => { try out.append(allocator, pattern[i]); i += 1; },
            }
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Test subject against a single ERE pattern using POSIX regcomp/regexec.
/// `\b` in the pattern is expanded to the portable word-boundary form.
pub fn matchEre(allocator: std.mem.Allocator, pattern: []const u8, subject: [:0]const u8) !bool {
    const expanded = try expandEreEscapes(allocator, pattern);
    defer allocator.free(expanded);
    const expanded_z = try allocator.dupeZ(u8, expanded);
    defer allocator.free(expanded_z);

    var preg: c.regex_t = undefined;
    const rc = c.regcomp(&preg, expanded_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
    if (rc != 0) return false;
    defer c.regfree(&preg);
    const exec_rc = c.regexec(&preg, subject.ptr, 0, null, 0);
    return exec_rc == 0;
}

/// Test subject against all patterns. Returns first matching pattern or null.
pub fn findMatch(allocator: std.mem.Allocator, patterns: []const []const u8, subject: []const u8) !?[]const u8 {
    const subject_z = try allocator.dupeZ(u8, subject);
    defer allocator.free(subject_z);

    for (patterns) |pat| {
        if (try matchEre(allocator, pat, subject_z)) {
            return pat;
        }
    }
    return null;
}

/// Test subject against all patterns. Returns true if any matches.
pub fn matchesAny(allocator: std.mem.Allocator, patterns_list: []const []const u8, subject: []const u8) !bool {
    const match = try findMatch(allocator, patterns_list, subject);
    return match != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// --- matchEre ---

test "matchEre: ^git\\b matches git status" {
    try std.testing.expect(try matchEre(std.testing.allocator, "^git\\b", "git status"));
}

test "matchEre: ^git\\b does not match notgit" {
    try std.testing.expect(!try matchEre(std.testing.allocator, "^git\\b", "notgit"));
}

test "matchEre: rm\\s+.*-rf matches rm -rf /" {
    try std.testing.expect(try matchEre(std.testing.allocator, "rm\\s+.*-rf", "rm -rf /"));
}

test "matchEre: curl|wget matches curl evil.com" {
    try std.testing.expect(try matchEre(std.testing.allocator, "(curl|wget)\\s", "curl evil.com"));
}

test "matchEre: malformed pattern returns false" {
    // '[' is an unclosed bracket — regcomp should fail and matchEre returns false.
    try std.testing.expect(!try matchEre(std.testing.allocator, "[", "anything"));
}

// --- findMatch / matchesAny ---

test "findMatch: returns first matching pattern" {
    const allocator = std.testing.allocator;
    const pats: []const []const u8 = &.{ "^foo\\b", "^git\\b" };
    const matched = try findMatch(allocator, pats, "git status");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("^git\\b", matched.?);
}

test "findMatch: returns null when no pattern matches" {
    const allocator = std.testing.allocator;
    const pats: []const []const u8 = &.{ "^foo\\b", "^bar\\b" };
    const matched = try findMatch(allocator, pats, "git status");
    try std.testing.expect(matched == null);
}

test "matchesAny: returns true when a pattern matches" {
    const allocator = std.testing.allocator;
    const pats: []const []const u8 = &.{"^git\\b"};
    try std.testing.expect(try matchesAny(allocator, pats, "git status"));
}

test "matchesAny: returns false when no pattern matches" {
    const allocator = std.testing.allocator;
    const pats: []const []const u8 = &.{"^git\\b"};
    try std.testing.expect(!try matchesAny(allocator, pats, "npm install"));
}
