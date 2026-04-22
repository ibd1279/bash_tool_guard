# Zig 0.16 Upgrade Plan for bash-tool-guard

## Executive Summary

This document outlines the complete plan to upgrade the bash-tool-guard codebase from Zig 0.15.x to Zig 0.16.0, following the official release notes and addressing all breaking changes.

## Current State Analysis

### Codebase Overview
- **Project**: bash-tool-guard
- **Current Minimum Zig Version**: 0.15.2 (in build.zig.zon)
- **Dependencies**: None (empty dependencies table)
- **Code Size**: ~15 source files, ~2000 lines of Zig code
- **Build System**: Standard build.zig with no external dependencies

### Zig Version Compatibility
- **Current**: Zig 0.15.x (minimum 0.15.2)
- **Target**: Zig 0.16.0
- **Compatibility Gap**: ~0.008 version difference (significant breaking changes)

### Code Patterns Used
1. **std.meta.activeTag** - Used in tests (8 occurrences)
2. **std.Io interface** - Used for I/O operations (stdout, stdin, file operations)
3. **std.json** - Used for JSON parsing
4. **std.fs** - Used for file system operations
5. **std.process** - Used for process management (already compatible with Init)
6. **std.mem** - Used for string operations

## Research Findings

### Breaking Changes Identified (from release notes)

#### 1. Language Syntax Changes ⚠️ HIGH PRIORITY
- **`@Type` builtin removed** - Not used in this codebase (safe)
- **std.meta.activeTag changes** - Used in tests, needs migration
- **Enum handling improvements** - Direct enum field access preferred

#### 2. Standard Library - std.Io ⚠️ CRITICAL PRIORITY
- **Major interface redesign** - Affects I/O throughout the codebase
- **Removed types**: GenericReader, AnyReader, FixedBufferStream
- **New interface**: std.Io as a first-class interface
- **Impact**: All I/O operations need migration

#### 3. Standard Library - std.fs ⚠️ HIGH PRIORITY
- **API updates to path functions**
- **New allocation-based file reading**
- **Access time made optional in File.Stat**
- **Windows path handling improvements**

#### 4. Standard Library - std.mem ⚠️ MEDIUM PRIORITY
- **Function renames**: "index of" → "find"
- **New cut functions**
- **More consistent naming**

#### 5. Standard Library - std.json ⚠️ MEDIUM PRIORITY
- **No major breaking changes**
- **API compatibility maintained**
- **May need minor adjustments**

#### 6. Build System ⚠️ MEDIUM PRIORITY
- **New package management features**
- **Local package fetching**
- **Test timeouts**
- **Better error reporting**

## Detailed Migration Plan

### Phase 1: Environment Setup (Estimated: 1 hour)

#### Task 1.1: Install Zig 0.16.0
```bash
# Install Zig 0.16.0 using your preferred method
# Example (macOS with Homebrew):
brew install zig@0.16

# Verify installation
zig version
# Should output: 0.16.0
```

#### Task 1.2: Update Project Files
```bash
# Update build.zig.zon to require Zig 0.16.0
# Change minimum_zig_version from "0.15.2" to "0.16.0"
```

#### Task 1.3: Verify Build Environment
```bash
# Clean any cached builds
rm -rf .zig-cache

# Test current build (should fail with Zig 0.16.0 if incompatible)
zig build test
```

**Success Criteria:**
- [ ] Zig 0.16.0 installed and verified
- [ ] build.zig.zon updated to minimum_zig_version "0.16.0"
- [ ] Build environment ready for migration

---

### Phase 2: Language and Core Library Updates (Estimated: 4 hours)

#### Task 2.1: Update std.meta.activeTag Usage

**Files Affected:**
- src/guard.zig (8 occurrences)
- src/pipeline.zig (3 occurrences)

**Current Code:**
```zig
try std.testing.expect(std.meta.activeTag(cls) == .command);
```

**Migration:**
```zig
try std.testing.expect(cls == .command);
```

**Steps:**
1. Search for `std.meta.activeTag` in all source files
2. Replace with direct enum comparison
3. Remove std.meta import if no longer needed

**Verification:**
- Run tests to ensure enum comparisons work correctly
- Check that all activeTag usages are updated

**Success Criteria:**
- [ ] All std.meta.activeTag usages replaced
- [ ] Tests pass with new enum comparison syntax

---

#### Task 2.2: Update std.Io Interface Usage ⚠️ CRITICAL

**Files Affected:**
- src/log.zig
- src/output.zig
- src/patterns.zig
- src/root.zig
- src/main.zig

**Current Code Pattern:**
```zig
// Old pattern (Zig 0.15)
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
const stdout = &stdout_writer.interface;

// Or for stdin
var stdin_rd = std.Io.File.stdin().reader(io, &rd_buf);
```

**New Code Pattern (Zig 0.16):**
```zig
// New pattern (Zig 0.16)
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer;

// Or for stdin
var stdin_rd = std.Io.File.stdin().reader(&rd_buf);
```

**Key Changes:**
- Remove `io` parameter from `writer()` and `reader()` calls
- The `io` interface is now handled differently in the new std.Io design
- Directly use the writer/reader interface instead of accessing `.interface`

**Steps:**
1. Update all `std.Io.File.stdout().writer(io, &buf)` calls
2. Update all `std.Io.File.stdin().reader(io, &buf)` calls
3. Update all file reader/writer operations
4. Review std.Io.File operations for other methods

**Files to Update:**
- `src/log.zig`: `std.Io.File` operations
- `src/output.zig`: `std.Io.File.stdout().writer()` calls
- `src/patterns.zig`: `std.Io.Dir.cwd().readFileAlloc()` and reader operations
- `src/root.zig`: `std.Io.File.stdout().writer()` calls
- `src/main.zig`: `std.Io.File.stdin().reader()` calls

**Verification:**
- Compile each file individually
- Run tests to ensure I/O operations work
- Test actual I/O functionality (stdout, file reading)

**Success Criteria:**
- [ ] All std.Io.File.writer() calls updated (remove io parameter)
- [ ] All std.Io.File.reader() calls updated (remove io parameter)
- [ ] All I/O operations compile and work correctly
- [ ] Tests pass with new I/O interface

---

#### Task 2.3: Update std.fs Operations

**Files Affected:**
- src/main.zig
- src/log.zig
- src/patterns.zig

**Current Code Pattern:**
```zig
// Old pattern (Zig 0.15)
const cwd = try std.process.getCwdAlloc(allocator);
const path = try std.fs.path.join(allocator, &.{ root_path, ".claude", fname });
const deny_file = try std.fs.path.join(allocator, &.{ home, ".local/etc/btg.deny" });
```

**New Code Pattern (Zig 0.16):**
```zig
// New pattern (Zig 0.16)
// std.process.getCwdAlloc remains the same
const cwd = try std.process.getCwdAlloc(allocator);

// std.fs.path.join remains the same (no breaking changes mentioned)
const path = try std.fs.path.join(allocator, &.{ root_path, ".claude", fname });
```

**Key Changes:**
- `std.fs.path.join` remains compatible
- `std.fs.cwd()` → `std.fs.Dir.cwd()` (check if needed)
- `readFileAlloc` usage may need updates

**Steps:**
1. Review all std.fs.path usage
2. Check for `std.fs.cwd()` vs `std.fs.Dir.cwd()`
3. Update file reading operations if using new allocation patterns

**Verification:**
- Test file system operations
- Verify path joining works correctly
- Check file reading/writing operations

**Success Criteria:**
- [ ] All std.fs.path operations work correctly
- [ ] File reading operations updated if needed
- [ ] Path operations compile and work

---

#### Task 2.4: Update std.json Usage

**Files Affected:**
- src/main.zig

**Current Code Pattern:**
```zig
// Old pattern (Zig 0.15)
const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
    std.process.exit(0);
```

**New Code Pattern (Zig 0.16):**
```zig
// New pattern (Zig 0.16)
// std.json.parseFromSlice remains compatible
const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
    std.process.exit(0);
```

**Key Changes:**
- No major breaking changes to std.json
- May need minor adjustments if any

**Steps:**
1. Test JSON parsing with Zig 0.16.0
2. Fix any compilation errors
3. Verify JSON parsing works correctly

**Verification:**
- Run tests that use JSON parsing
- Test actual JSON input processing

**Success Criteria:**
- [ ] std.json.parseFromSlice works correctly
- [ ] All JSON parsing operations compile and work

---

### Phase 3: Build System Updates (Estimated: 2 hours)

#### Task 3.1: Update build.zig

**Current Code Pattern:**
```zig
// Old pattern (Zig 0.15)
const mod = b.addModule("bash_tool_guard", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
});
```

**New Code Pattern (Zig 0.16):**
```zig
// New pattern (Zig 0.16)
// No major changes expected, but review for new features
const mod = b.addModule("bash_tool_guard", .{
    .root_source_file = .{ .path = "src/root.zig" },
    .target = target,
});
```

**Key Changes:**
- Build system APIs may have minor updates
- New package management features available
- Test timeout features can be added

**Steps:**
1. Review build.zig for any deprecated API usage
2. Update to new patterns if needed
3. Add test timeout configuration (optional)
4. Test build with `zig build test`

**Verification:**
- Build succeeds without errors
- All build steps work correctly
- Tests run successfully

**Success Criteria:**
- [ ] build.zig compiles without errors
- [ ] All build steps work correctly
- [ ] Tests run successfully

---

### Phase 4: Testing and Validation (Estimated: 3 hours)

#### Task 4.1: Run All Tests
```bash
# Clean build
rm -rf .zig-cache

# Run tests
zig build test
```

**Expected Issues:**
1. I/O interface changes will cause compilation errors
2. std.meta.activeTag changes will cause compilation errors
3. std.fs changes may cause minor issues

**Steps:**
1. Fix compilation errors as they appear
2. Run tests incrementally
3. Verify all tests pass

#### Task 4.2: Integration Testing
```bash
# Build the project
zig build

# Run the executable if applicable
# (bash-tool-guard may be a library or CLI tool)
```

**Verification:**
- Project builds successfully
- Executable runs without errors
- All functionality works as expected

**Success Criteria:**
- [ ] All unit tests pass
- [ ] Project builds successfully
- [ ] Integration tests pass
- [ ] No runtime errors

---

### Phase 5: Cleanup and Finalization (Estimated: 1 hour)

#### Task 5.1: Remove Deprecated Imports
- Review all imports
- Remove any no-longer-used imports
- Clean up unused code

#### Task 5.2: Update Documentation
- Update README.md if needed
- Add migration notes if this is a public library
- Update any version requirements

#### Task 5.3: Final Verification
```bash
# Clean build and test
rm -rf .zig-cache
zig build test

# Verify version
cat build.zig.zon | grep minimum_zig_version
```

**Success Criteria:**
- [ ] No deprecated API usage remains
- [ ] Documentation updated
- [ ] All tests pass
- [ ] Build is clean

---

## Risk Assessment and Mitigation

### High Risk Items

1. **std.Io Interface Changes**
   - **Risk**: All I/O operations will break
   - **Mitigation**: Update I/O interface first, test thoroughly
   - **Contingency**: Keep old code as fallback during migration

2. **std.meta.activeTag Changes**
   - **Risk**: Test failures due to enum comparison changes
   - **Mitigation**: Update all occurrences systematically
   - **Contingency**: Direct enum comparison is simpler, less error-prone

### Medium Risk Items

1. **std.fs API Changes**
   - **Risk**: File system operations may break
   - **Mitigation**: Test file operations thoroughly
   - **Contingency**: Use fallback patterns if needed

2. **Build System Changes**
   - **Risk**: Build may fail with new Zig version
   - **Mitigation**: Test build early, fix issues incrementally
   - **Contingency**: Keep old build.zig as backup

### Low Risk Items

1. **std.json Changes**
   - **Risk**: JSON parsing may have minor issues
   - **Mitigation**: Test JSON operations specifically
   - **Contingency**: Easy to fix if needed

2. **New Features**
   - **Risk**: Over-engineering with new features
   - **Mitigation**: Focus on compatibility first, features later

---

## Timeline and Resource Estimation

| Phase | Task | Estimated Time | Assigned To |
|-------|------|----------------|-------------|
| 1 | Environment Setup | 1 hour | Developer |
| 2.1 | std.meta.activeTag Updates | 2 hours | Developer |
| 2.2 | std.Io Interface Updates | 4 hours | Developer |
| 2.3 | std.fs Updates | 2 hours | Developer |
| 2.4 | std.json Updates | 1 hour | Developer |
| 3 | Build System Updates | 2 hours | Developer |
| 4 | Testing and Validation | 3 hours | Developer |
| 5 | Cleanup and Finalization | 1 hour | Developer |
| **Total** | | **16 hours** | |

**Resource Requirements:**
- Zig 0.16.0 installed
- Development environment ready
- Access to all source files
- Test environment

**Dependencies:**
- None (self-contained project)

---

## Success Metrics

### Compilation Metrics
- [ ] All source files compile without errors
- [ ] No deprecation warnings (or minimal)
- [ ] Build completes successfully
- [ ] No linker errors

### Functional Metrics
- [ ] All unit tests pass (100% pass rate)
- [ ] Integration tests pass
- [ ] I/O operations work correctly
- [ ] File system operations work correctly
- [ ] JSON parsing works correctly
- [ ] Process management works correctly

### Quality Metrics
- [ ] No deprecated API usage remains
- [ ] Code follows Zig 0.16 idioms
- [ ] Documentation updated
- [ ] Build system optimized for 0.16

---

## Rollback Plan

If issues arise during migration:

1. **Immediate Rollback**
   ```bash
   # Revert build.zig.zon to old version
   git checkout HEAD -- build.zig.zon
   
   # Clean and rebuild with old Zig version
   rm -rf .zig-cache
   zig build test
   ```

2. **Partial Rollback**
   - Keep old versions of specific files
   - Use git to revert individual changes
   - Test incrementally

3. **Issue Tracking**
   - Document all issues encountered
   - Create GitHub issues for tracking
   - Plan follow-up fixes if needed

---

## Post-Migration Recommendations

### Adopt New Features (Optional)
After successful migration, consider adopting:

1. **New std.Io Features**
   - Threaded I/O
   - Evented I/O
   - Better I/O error handling

2. **New std.fs Features**
   - Atomic file operations
   - Temporary file APIs
   - Memory mapping

3. **New Build System Features**
   - Local package fetching
   - Package overrides
   - Test timeouts

4. **New Language Features**
   - Direct enum comparison (already adopted)
   - New builtins for metaprogramming

### Performance Optimization
After migration:
- Profile the application
- Optimize I/O operations with new std.Io features
- Consider using new allocators if beneficial
- Review memory usage patterns

### Security Review
- Check file system access patterns
- Review process management
- Validate error handling
- Test with security-focused inputs

---

## Checklist for Implementation

### Pre-Migration
- [ ] Backup all source files
- [ ] Commit current state to git
- [ ] Install Zig 0.16.0
- [ ] Verify Zig installation
- [ ] Update build.zig.zon minimum version

### During Migration
- [ ] Update std.meta.activeTag usage
- [ ] Update std.Io interface usage
- [ ] Update std.fs operations
- [ ] Update std.json usage
- [ ] Update build.zig
- [ ] Fix compilation errors incrementally
- [ ] Test each change

### Post-Migration
- [ ] Run all tests
- [ ] Verify functionality
- [ ] Clean up deprecated code
- [ ] Update documentation
- [ ] Final verification

---

## References

1. **Zig 0.16 Release Notes**: https://ziglang.org/download/0.16.0/release-notes.html
2. **Zig 0.16 Standard Library Documentation**: https://ziglang.org/documentation/0.16.0/std/
3. **Zig 0.16 Language Reference**: https://ziglang.org/documentation/0.16.0/
4. **Migration Guide**: https://ziglang.org/download/0.16.0/release-notes.html#Migration

---

## Approval and Sign-off

**Migration Lead:** [Your Name]
**Date:** [Date]
**Approved By:** [Team Lead/Manager]

**Status:** ✅ Ready for Implementation

---

*Document Version: 1.0*
*Last Updated: 2026-04-22*
*Next Review: After migration completion*
