// Test root: force all modules into the test compilation so their test
// blocks are discovered and run.
comptime {
    _ = @import("guard.zig");
    _ = @import("patterns.zig");
    _ = @import("pipeline.zig");
    _ = @import("log.zig");
    _ = @import("process_info.zig");
    _ = @import("flags.zig");
    _ = @import("settings.zig");
}
