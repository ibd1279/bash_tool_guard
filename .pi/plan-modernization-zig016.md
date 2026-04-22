# Zig 0.16 Modernization Plan for bash-tool-guard

## Executive Summary

The bash-tool-guard codebase is on Zig 0.16.0 but uses mixed 0.15 and 0.16 patterns. This plan documents the modernization effort to ensure idiomatic Zig 0.16 usage across all source files.

## Current State Analysis

### Files Identified for Modernization

**High Priority (std.Io usage):**
- `src/main.zig` - Uses `std.Io.File.stdin()`, `std.Io.Dir.accessAbsolute()`, `std.Io.Dir.cwd()`
- `src/project.zig` - Uses `std.Io.Dir.accessAbsolute()`
- `src/settings.zig` - Uses `std.Io.Dir.cwd().readFileAlloc()`
- `src/output.zig` - Uses `std.Io.File.stdout()`
- `src/log.zig` - Uses `std.Io.Clock.real.now()`
- `src/report.zig` - Extensive usage: `std.Io.File`, `std.Io.Dir`, `std.Io.Dir.cwd().readFileAlloc()`
- `src/patterns.zig` - Uses `std.Io.Dir.cwd().readFileAlloc()`

**High Priority (ArrayListUnmanaged):**
- `src/report.zig` - 8 instances of `std.ArrayListUnmanaged`

**Medium Priority (Other patterns):**
- Build system: `build.zig` - Uses modern patterns but should be verified

## Modernization Tasks by Priority

### Priority 1: std.Io → std.fs Migration

#### Changes Required:
```zig
// OLD (0.15):
std.Io.File.stdin().reader(io, &buf)
std.Io.File.stdout().writer(io, &buf)
std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited)
std.Io.Dir.accessAbsolute(io, path, .{})
std.Io.Dir.createDirAbsolute(io, path, .default_dir)
std.Io.Dir.createFileAbsolute(io, path, .{})
std.Io.Dir.deleteFileAbsolute(io, path)
std.Io.Clock.real.now(io)

// NEW (0.16):
std.fs.File.stdin().reader(allocator, &buf)
std.fs.File.stdout().writer(allocator, &buf)
std.fs.cwd().openFile(path, .{}) catch |err| ...
std.fs.accessAbsolute(path, .{}) catch |err| ...
std.fs.cwd().makeDirAbsolute(path, .default_dir) catch |err| ...
std.fs.cwd().createFile(path, .{}) catch |err| ...
std.fs.cwd().deleteFile(path) catch |err| ...
std.time.Instant.now()
```

#### Files to Update:

1. **src/main.zig** (10 occurrences)
   - Line 23: `std.Io.File.stdin().reader(io, &rd_buf)`
   - Line 76: `std.Io.Dir.accessAbsolute(io, allow_file, .{})`
   - Line 111: `std.process.getCwdAlloc(allocator)` (keep - this is correct)
   - Line 133: `std.Io.Dir.cwd().readFileAlloc(io, ...)`
   - Line 155: `std.Io.Dir.createFileAbsolute(io, ...)`
   - Line 167: `std.Io.Dir.accessAbsolute(io, deny_path, .{})`
   - Line 171: `std.Io.Dir.createFileAbsolute(io, deny_path, .{})`
   - Line 183: `std.fs.path.join()` (keep - this is correct)
   - Line 209-247: Multiple `std.Io.File.stdout().writer()` calls
   - Line 261: `std.Io.Clock.real.now(io)` (in log.zig import)

2. **src/project.zig** (1 occurrence)
   - Line 14: `std.Io.Dir.accessAbsolute(io, git_path, .{})`

3. **src/settings.zig** (1 occurrence)
   - Line 30: `std.Io.Dir.cwd().readFileAlloc(io, settings_path, ...)`

4. **src/output.zig** (3 occurrences)
   - Lines 6, 20, 34: `std.Io.File.stdout().writer(io, &buf)`

5. **src/log.zig** (2 occurrences)
   - Line 191: `std.Io.Clock.real.now(io)`
   - Line 222: `std.Io.File{ .handle = fd }`

6. **src/report.zig** (30+ occurrences)
   - Lines 20, 247, 399, 556, 684, 954: `std.Io.Dir.cwd().readFileAlloc()`
   - Lines 64, 141, 871: `std.Io.Dir.createDirAbsolute()`
   - Lines 71, 895: `std.Io.File{ .handle = fd }`
   - Lines 151, 155, 167, 171: `std.Io.Dir.accessAbsolute()`
   - Lines 134, 196, 209, 228, 505, 535, 663, 938, 1068: `std.Io.File.stdout().writer()`
   - Line 672: `std.Io.File.stderr().writer()`
   - Lines 1115, 1126, 1139: `std.Io.File.stderr().writer()`
   - Line 513: `std.Io.Dir.deleteFileAbsolute()`

7. **src/patterns.zig** (1 occurrence)
   - Line 9: `std.Io.Dir.cwd().readFileAlloc()`

### Priority 2: ArrayListUnmanaged → ArrayList Migration

#### Changes Required:
```zig
// OLD (0.15):
var result: std.ArrayListUnmanaged([]u8) = .empty;
errdefer {
    for (result.items) |e| allocator.free(e);
    result.deinit(allocator);
}
try result.append(allocator, value);
return result.toOwnedSlice(allocator);

// NEW (0.16):
var result = std.ArrayList([]u8).init(allocator);
defer result.deinit();
errdefer {
    for (result.items) |e| allocator.free(e);
}
try result.append(value);
return result.toOwnedSlice();
```

#### Files to Update:

**src/report.zig** (8 instances):
- Line 14: `var result: std.ArrayListUnmanaged([]u8) = .empty;`
- Line 446: `var list: std.ArrayListUnmanaged(Entry) = .empty;`
- Line 549: `var raw_pats: std.ArrayListUnmanaged(RawPattern) = .empty;`
- Line 790: `var new_entries: std.ArrayListUnmanaged([]u8) = .empty;`
- Line 827: `var all_allow: std.ArrayListUnmanaged([]u8) = .empty;`
- Line 878: `var json_buf: std.ArrayListUnmanaged(u8) = .empty;`
- Line 1009: `var prompt_buf: std.ArrayListUnmanaged(u8) = .empty;`
- Line 1054: `var selector_list: std.ArrayListUnmanaged([]const u8) = .empty;`

### Priority 3: Build System Verification

**build.zig** - Already uses modern patterns:
- ✓ Uses `b.standardTargetOptions()` and `b.standardOptimizeOption()`
- ✓ Uses `b.addModule()` correctly
- ✓ Uses `b.installArtifact()` correctly
- ✓ Uses `b.createModule()` for test modules
- ✓ Modern step dependencies

**No changes needed** - build.zig is already idiomatic 0.16.

### Priority 4: Error Handling Improvements

While error handling is generally good, we should:
1. Ensure all error unions use explicit error sets where appropriate
2. Verify error propagation patterns are consistent
3. Check that `catch` blocks handle errors appropriately

### Priority 5: Memory Management Patterns

1. Verify all `ArrayList` and `StringHashMap` have proper `defer` cleanup
2. Ensure allocator parameters are passed correctly
3. Check for memory leaks in error paths

## Implementation Strategy

### Phase 1: std.Io → std.fs Migration

**Approach:**
1. Create a comprehensive search/replace plan
2. Update each file incrementally
3. Test after each file change
4. Use systematic patterns for replacement

**Replacement Patterns:**

```bash
# Pattern 1: File readers/writers
s/std\.Io\.File\.stdin\(\)\.reader(io, &buf)/std.fs.File.stdin().reader(allocator, &buf)/g
s/std\.Io\.File\.stdout\(\)\.writer(io, &buf)/std.fs.File.stdout().writer(allocator, &buf)/g
s/std\.Io\.File\.stderr\(\)\.writer(io, &buf)/std.fs.File.stderr().writer(allocator, &buf)/g

# Pattern 2: Directory operations
s/std\.Io\.Dir\.cwd\(\)\.readFileAlloc(io, ([^,]+), allocator, \.unlimited)/std.fs.cwd().openFile($1, .{}) catch |err| .../g
s/std\.Io\.Dir\.accessAbsolute(io, ([^,]+), \.\{)/std.fs.accessAbsolute($1, .{}) catch |err| .../g
s/std\.Io\.Dir\.createDirAbsolute(io, ([^,]+), \.default_dir)/std.fs.cwd().makeDirAbsolute($1, .default_dir) catch |err| .../g
s/std\.Io\.Dir\.createFileAbsolute(io, ([^,]+), \.\{)/std.fs.cwd().createFile($1, .{}) catch |err| .../g
s/std\.Io\.Dir\.deleteFileAbsolute(io, ([^)]+))/std.fs.cwd().deleteFile($1) catch |err| .../g

# Pattern 3: Clock
s/std\.Io\.Clock\.real\.now(io)/std.time.Instant.now()/g

# Pattern 4: File handle creation
s/const file = std\.Io\.File\{\s*\.handle = fd \}/const file = std.fs.File{ .handle = fd }/g
```

### Phase 2: ArrayListUnmanaged → ArrayList Migration

**Approach:**
1. Update error handling patterns first
2. Replace `.empty` initialization with `.init(allocator)`
3. Update `deinit()` calls to use proper allocator
4. Update `toOwnedSlice()` calls to not pass allocator
5. Add `defer` cleanup where missing

**Replacement Pattern:**
```bash
# Pattern: ArrayListUnmanaged to ArrayList
s/var ([a-z_]+): std\.ArrayListUnmanaged\(([^)]+)\) = \.empty;/var $1 = std.ArrayList($2).init(allocator);/g

# Pattern: errdefer cleanup for ArrayListUnmanaged
s/errdefer \{\n        for \(result\.items\) \|e\| allocator\.free\(e\);
        result\.deinit\(allocator\);
    \}/errdefer {
        for ($1.items) |e| allocator.free(e);
    }/g

# Pattern: toOwnedSlice allocator removal
s/result\.toOwnedSlice\(allocator\)/result.toOwnedSlice()/g

# Pattern: append with allocator
s/try result\.append\(allocator,/try $1.append(/g
```

### Phase 3: Testing and Validation

1. Build the project after each phase
2. Run existing tests
3. Manual testing of key functionality:
   - File reading/writing
   - Directory operations
   - Process execution
   - JSON parsing
4. Verify error handling paths

## Detailed File-by-File Changes

### src/main.zig

**Changes:**
1. Line 23: Update stdin reader
2. Line 76: Update accessAbsolute
3. Line 133: Update readFileAlloc
4. Lines 155, 167, 171: Update createFileAbsolute and accessAbsolute
5. Lines 209-247: Update stdout writers
6. Remove io parameter from functions that no longer need it

**Impact:** Medium - main function is entry point

### src/report.zig

**Changes:**
1. All std.Io usage (30+ occurrences)
2. All ArrayListUnmanaged usage (8 instances)
3. Update function signatures to remove io parameter where not needed

**Impact:** High - report.zig is a major component with many functions

### src/project.zig, src/settings.zig, src/output.zig, src/log.zig, src/patterns.zig

**Changes:**
1. Update std.Io usage to std.fs
2. Update Clock usage to Instant

**Impact:** Low-Medium - smaller files with fewer changes

## Risk Assessment

### Low Risk:
- ArrayListUnmanaged → ArrayList migration (well-tested pattern)
- std.Io → std.fs for file operations (clear API changes)

### Medium Risk:
- Changes to error handling paths
- Changes to memory management in complex functions
- Changes to file I/O that might affect behavior

### Mitigation Strategies:
1. Test after each file change
2. Use version control to track changes
3. Create backup before large refactoring
4. Focus on one pattern at a time

## Success Criteria

1. All code compiles without warnings on Zig 0.16.0
2. All tests pass
3. No memory leaks detected
4. Error handling is consistent and idiomatic
5. Build system works correctly
6. All file I/O operations function correctly
7. Performance characteristics maintained

## Timeline Estimate

**Phase 1: std.Io → std.fs Migration**
- Duration: 2-3 days
- Effort: High (many files, many changes)

**Phase 2: ArrayListUnmanaged → ArrayList Migration**
- Duration: 1-2 days  
- Effort: Medium (fewer files, systematic changes)

**Phase 3: Testing and Validation**
- Duration: 1-2 days
- Effort: Medium (comprehensive testing)

**Total: 4-7 days**

## Rollback Plan

If issues arise:
1. Revert to git HEAD
2. Fix critical issues in current version
3. Re-apply changes incrementally
4. Document issues and adjust approach

## Dependencies

- Zig 0.16.0 installed
- Git repository with clean working directory
- Test environment for validation
- Backup of important data (logs, config files)

## Pre-Implementation Checklist

- [ ] Verify Zig version: `zig version` → 0.16.0
- [ ] Create backup branch: `git checkout -b modernization-zig016`
- [ ] Run existing tests: `zig build test`
- [ ] Build project: `zig build`
- [ ] Document current state
- [ ] Create issue tracker for bugs found

## Post-Implementation Checklist

- [ ] All tests pass
- [ ] No compiler warnings
- [ ] Memory leak check passes
- [ ] Performance unchanged
- [ ] Documentation updated
- [ ] Code review completed
- [ ] Merge to main branch

---

## Implementation Notes

### Key Differences Between 0.15 and 0.16:

1. **std.Io → std.fs**: The Io module was split - file and directory operations moved to std.fs
2. **Explicit Allocators**: All allocation operations now require explicit allocator parameter
3. **Error Handling**: More consistent error sets and propagation
4. **Memory Management**: ArrayListUnmanaged deprecated in favor of allocator-aware ArrayList

### Best Practices for Modern Zig 0.16:

1. Always pass allocator explicitly to functions that allocate
2. Use `defer` for resource cleanup
3. Use `errdefer` for error path cleanup
4. Prefer std.fs over std.Io for file operations
5. Use std.time.Instant instead of std.Io.Clock
6. Use std.fs.accessAbsolute instead of std.Io.Dir.accessAbsolute

### Common Pitfalls:

1. Forgetting to update function signatures when removing io parameter
2. Not adding proper defer cleanup for new ArrayList instances
3. Mixing old and new patterns in the same function
4. Not testing error paths thoroughly
5. Memory leaks from not freeing temporary allocations

---

## Next Steps

1. Create modernization branch
2. Start with Phase 1: std.Io → std.fs migration
3. Update src/main.zig first (entry point)
4. Test thoroughly
5. Proceed to other files
6. Complete Phase 2: ArrayList migration
7. Final testing and validation
