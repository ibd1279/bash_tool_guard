# Planning Prompt: Upgrade bash-tool-guard to Zig 0.16 Idioms

## Original Intent

"I want this code base to upgrade to zig 0.16 idioms. I want you to plan this intent using the subagents."

**Goal**: Audit and modernize the bash-tool-guard codebase to ensure it uses idiomatic Zig 0.16 patterns throughout all source files.

## Context Summary

### Codebase Context

**Relevant Files**:
- `src/main.zig` - Main hook executable (Claude Code hook that evaluates bash commands)
- `src/report.zig` - CLI tool for managing allow/deny patterns and analyzing logs
- `src/guard.zig` - Command parsing and sanitization
- `src/pipeline.zig` - Evaluation logic and VibeFn type definition
- `src/patterns.zig` - Regex pattern matching (uses @cImport for POSIX regex)
- `src/flags.zig` - Flag analysis
- `src/process_info.zig` - Process lookup via pgrep
- `src/vibe.zig` - AI safety check (spawns vibe process)
- `src/log.zig` - JSONL logging
- `src/settings.zig` - Claude settings parsing
- `src/project.zig` - Git project detection
- `src/output.zig` - JSON output utilities
- `src/root.zig` - Module root
- `build.zig` - Build system configuration
- `build.zig.zon` - Package manifest

**Existing Patterns** (from codebase audit):
- Uses `const std = @import("std")` throughout
- Uses `std.Io`, `std.Io.File`, `std.Io.Dir`, `std.Io.Clock` namespace
- Uses `std.ArrayList` with `.empty` initializer and explicit allocator passing
- Uses `std.ArrayListUnmanaged` in report.zig for manual memory management
- Uses `std.StringHashMap` for string-keyed maps
- Uses `std.json.parseFromSlice` with `std.json.Value`
- Uses `std.process.spawn` with struct config
- Uses `std.posix` for POSIX system calls (openat, poll, regexec via @cImport)
- Uses `writer(io, &buf)` and `reader(io, &buf)` interface pattern

**Key Symbols**:
- `std.Io`, `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`
- `std.ArrayList`, `std.ArrayListUnmanaged`
- `std.StringHashMap`
- `std.json.Value`, `std.json.parseFromSlice`
- `std.process.spawn`, `std.process.Init`
- `std.mem.Allocator`
- `std.fs.path` (for path operations)
- `VibeFn` type: `*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult`

**Gaps to Address** (Compilation Errors - Blocking):
1. **main.zig:23** - `std.fs.File.stdin()` should be `std.Io.File.stdin()`
2. **output.zig:4,15,29** - `std.fs.File.stdout()` should be `std.Io.File.stdout()`
3. **output.zig:4,15,29** - Unused `io: std.Io` parameters (functions don't use them)
4. **patterns.zig:8** vs **report.zig:236** - `loadPatterns()` signature mismatch:
   - Declaration: `fn loadPatterns(allocator: std.mem.Allocator, path: []const u8)`
   - Call site: `loadPatterns(io, allocator, allow_file)` (passes extra `io` argument)

**Pattern Inconsistencies to Audit**:
1. Verify all `std.fs.File.*` usage should be `std.Io.File.*`
2. Verify all `std.fs.Dir.*` usage should be `std.Io.Dir.*`
3. Verify all `std.fs.path.*` usage (this may be correct as-is)
4. Check reader/writer interface patterns for consistency
5. Verify allocator passing patterns are consistent
6. Review `std.ArrayListUnmanaged` usage - verify if this is still recommended in 0.16

### Documentation Context

**Source 1: Zig 0.16 Release Notes** (https://ziglang.org/download/0.16.0/release-notes.html)
- Standard library reorganization with module structure changes
- Memory management updates to allocator patterns
- Error handling improvements with error unions and error sets
- File I/O changes to std.Io.File and std.fs interfaces
- Process management updates to std.process APIs
- JSON parsing improvements to std.json
- Build system changes to build.zig conventions

**Key API Change Notes** (from release notes research):
- Some research suggests `std.Io.File` → `std.fs.File` migration
- `ArrayListUnmanaged` may be deprecated in favor of explicit allocator passing
- `readFileAlloc()` patterns may have changed
- `std.process.spawn()` signature may have updates
- Error handling more consistent with named error sets

**Important**: There is conflicting information about whether `std.Io` or `std.fs` is the correct 0.16 pattern. The codebase research indicates `std.Io` is correct for 0.16, but some documentation research suggests migration to `std.fs`. The plan must verify which is actually correct for Zig 0.16.0 (the version in build.zig.zon).

### Dependencies

**External**:
- **Zig 0.16.0** (specified in build.zig.zon)
- **yazap** - Argument parsing package

**Internal**:
- POSIX regex via `@cImport("regex.h")` (regexec)
- Standard library: std.Io, std.mem, std.fs, std.process, std.json, std.fmt, std.posix, std.c

## Scope Choices

The following decisions could affect the plan's scope:

1. **std.Io vs std.fs namespace**: The codebase currently uses `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`. Research is conflicting on whether 0.16 uses `std.Io` or `std.fs`. 
   - Option A: Keep `std.Io` pattern (codebase research says this is 0.16 correct)
   - Option B: Migrate to `std.fs` pattern (some docs research suggests this)
   - **Impact**: Determines whether we fix compilation errors by changing to std.Io or std.fs

2. **ArrayListUnmanaged usage in report.zig**: 
   - Option A: Keep ArrayListUnmanaged where manual control is needed (appropriate for the use case)
   - Option B: Replace all ArrayListUnmanaged with ArrayList + explicit allocator
   - **Impact**: Affects memory management patterns in report.zig

3. **Error handling pattern consistency**:
   - Option A: Standardize on `!T` return types throughout
   - Option B: Keep mixed `!T` and `anyerror!T` based on use case (function pointers need anyerror!)
   - **Impact**: Affects API consistency vs. practical flexibility

4. **Test coverage depth**:
   - Option A: Add comprehensive tests for all modernized patterns
   - Option B: Add minimal tests only for new functionality introduced during fixes
   - **Impact**: Affects timeline and test file creation

## Planning Instructions

Generate a detailed implementation plan that:

1. **Fixes all 4 compilation errors** (blocking issues):
   - main.zig:23 - stdin() call
   - output.zig:4,15,29 - stdout() calls and unused io parameters
   - patterns.zig/report.zig - loadPatterns() signature mismatch

2. **Audits all source files for consistency**:
   - Verify std.Io vs std.fs usage is consistent throughout
   - Check all file I/O patterns match 0.16 idioms
   - Verify allocator passing is consistent
   - Review ArrayList/ArrayListUnmanaged usage

3. **Updates documentation**:
   - Update inline comments to reflect 0.16 patterns
   - Add any missing function documentation

4. **Adds tests**:
   - Add tests for any new patterns introduced
   - Ensure existing tests pass with modernized code

5. **Verifies build**:
   - Plan must include `zig build` verification step
   - Plan must include `zig build test` verification step

6. **Plan structure requirements**:
   - Organize in milestones that can survive context compaction
   - Reference specific file paths and line numbers
   - Include rollback/verification steps between milestones
   - Preserve the original intent verbatim in the plan introduction
   - Prioritize compilation fixes first (blocking), then audits (non-blocking)

7. **Verification criteria**:
   - `zig build` completes without errors
   - `zig build test` passes all tests
   - No deprecation warnings from Zig compiler
   - All source files use consistent std.Io/std.fs patterns
   - All allocator passing is explicit and consistent

## Success Criteria

The modernization is complete when:
- [ ] All 4 compilation errors are fixed
- [ ] All source files use consistent std.Io (or std.fs) patterns
- [ ] No Zig compiler warnings about deprecated APIs
- [ ] `zig build` succeeds
- [ ] `zig build test` passes
- [ ] Inline comments reflect 0.16 patterns
- [ ] Test coverage maintained or improved
