const std = @import("std");
const log_mod = @import("log.zig");

pub fn allow(io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var bw = std.Io.File.stdout().writer(io, &buf);
    const out = &bw.interface;
    try out.print(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"AI safety check: command appears safe\"}}}}\n",
        .{},
    );
    try out.flush();
}

pub fn deny(io: std.Io, allocator: std.mem.Allocator, reason: []const u8) !void {
    const escaped = try log_mod.jsonEscape(allocator, reason);
    defer allocator.free(escaped);

    var buf: [8192]u8 = undefined;
    var bw = std.Io.File.stdout().writer(io, &buf);
    const out = &bw.interface;
    try out.print(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"{s}\"}}}}\n",
        .{escaped},
    );
    try out.flush();
}

pub fn ask(io: std.Io, allocator: std.mem.Allocator, reason: []const u8) !void {
    const escaped = try log_mod.jsonEscape(allocator, reason);
    defer allocator.free(escaped);

    var buf: [8192]u8 = undefined;
    var bw = std.Io.File.stdout().writer(io, &buf);
    const out = &bw.interface;
    try out.print(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"{s}\"}}}}\n",
        .{escaped},
    );
    try out.flush();
}
