## Original Intent
I want this code base to upgrade to zig 0.16 idioms. I want you to plan this intent using the subagents.

## Goal
Audit and modernize the bash-tool-guard codebase to ensure it uses idiomatic Zig 0.16 patterns throughout all source files.

## Domain
Zig language modernization, standard library API usage, build system configuration

## Technology Signals
- Zig 0.16 (current and target version - project already on 0.16.0)
- yazap argument-parsing package
- POSIX regex (regexec via @cImport)
- JSONL logging
- Claude Code hooks (PreToolUse, PostToolUse)
- std.Io, std.mem, std.fs, std.process, std.json, std.fmt, std.posix

## Scope
Refactor / Modernization - ensuring all code uses current 0.16 idioms

## Documentation Sources
- Zig 0.16 Release Notes: https://ziglang.org/download/0.16.0/release-notes.html
- Zig 0.16 Standard Library Documentation: https://ziglang.org/documentation/0.16.0/std/
- Zig 0.16 Language Reference: https://ziglang.org/documentation/0.16.0/
- Zig 0.16 std.mem changes (ArrayList, HashMap patterns)
- Zig 0.16 std.io changes (Io vs fs.File patterns)

## Key Observations from Initial Code Review

The codebase is already on Zig 0.16.0 but uses mixed patterns:

1. **std.Io pattern**: Code uses `std.Io`, `std.Io.File`, `std.Io.Dir`, `std.Io.Clock` - this is the 0.16 pattern
2. **ArrayList patterns**: Uses `.empty` initializer and explicit allocator passing - matches 0.16 style
3. **Error handling**: Uses `anyerror!` return types in some places, explicit error unions in others
4. **JSON parsing**: Uses `std.json.parseFromSlice` with `std.json.Value` - current pattern
5. **File I/O**: Uses `std.Io.Dir.cwd().readFileAlloc()` with `.unlimited` - 0.16 pattern
6. **Process spawning**: Uses `std.process.spawn` with struct config - 0.16 pattern
7. **Writer/Reader patterns**: Uses `writer(io, &buf)` and `reader(io, &buf)` interface pattern

Potential areas for review:
- `std.ArrayListUnmanaged` usage in report.zig - verify if this is still the recommended pattern
- `std.StringHashMap` usage - verify 0.16 idioms
- Error union handling patterns
- Any deprecated std APIs that may have been replaced in 0.16
- Build system configuration for latest conventions

## Scope Decisions
- **Scope Depth**: Comprehensive - Full modernization including fixing all compilation errors, auditing all files for consistent std.Io usage, and ensuring idiomatic 0.16 patterns throughout
- **Test Strategy**: Enhanced - Add tests for any new patterns introduced during modernization
- **Documentation**: Update inline comments to reflect 0.16 patterns

## Open Questions
- None deferred to implementation time

## Identified Issues Requiring Fixes

### Compilation Errors (Blocking)
1. **main.zig:23** - `std.fs.File.stdin()` should be `std.Io.File.stdin()`
2. **output.zig:4,15,29** - `std.fs.File.stdout()` should be `std.Io.File.stdout()`
3. **output.zig:4,15,29** - Unused `io: std.Io` parameters (functions don't use them)
4. **patterns.zig:8** vs **report.zig:236** - `loadPatterns()` signature mismatch:
   - Declaration: `fn loadPatterns(allocator: std.mem.Allocator, path: []const u8)`
   - Call site: `loadPatterns(io, allocator, allow_file)` (passes extra `io` argument)

### Pattern Inconsistencies (To Audit)
1. Verify all `std.fs.File.*` usage should be `std.Io.File.*`
2. Verify all `std.fs.Dir.*` usage should be `std.Io.Dir.*`
3. Verify all `std.fs.path.*` usage (this may be correct as-is)
4. Check reader/writer interface patterns for consistency
5. Verify allocator passing patterns are consistent
