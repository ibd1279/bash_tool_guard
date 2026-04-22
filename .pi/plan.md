# Implementation Plan: Upgrade bash-tool-guard to Zig 0.16 Idioms

## Original Intent

"I want this code base to upgrade to zig 0.16 idioms. I want you to plan this intent using the subagents."

**Goal**: Audit and modernize the bash-tool-guard codebase to ensure it uses idiomatic Zig 0.16 patterns throughout all source files.

## Scope Decisions

- **In scope**:
  - Fix all 4 blocking compilation errors (main.zig, output.zig, patterns.zig/report.zig)
  - Audit all source files for std.Io vs std.fs consistency
  - Verify allocator passing patterns are consistent
  - Review ArrayList/ArrayListUnmanaged usage
  - Update inline comments to reflect 0.16 patterns
  - Ensure `zig build` and `zig build test` pass

- **Out of scope**:
  - Major refactoring beyond 0.16 idiom modernization
  - Adding new features or functionality
  - Rewriting existing logic with different algorithms

- **Deferred**:
  - Comprehensive test suite expansion (only ensure existing tests pass)
  - Documentation beyond inline code comments

---

## Glossary

**Key terms used throughout this plan**:

- **`std.Io`**: Zig 0.16's namespace for input/output operations. Replaces `std.fs.File` for stdin/stdout and file reading/writing. Examples: `std.Io.File.stdin()`, `std.Io.File.stdout()`, `std.Io.Dir.cwd()`.

- **`std.fs`**: Zig's filesystem namespace. Used for path manipulation (`std.fs.path.join()`) and filesystem operations. In 0.16, I/O operations moved to `std.Io` while path operations remain in `std.fs`.

- **Allocator (`std.mem.Allocator`)**: Zig's explicit memory management interface. All memory allocations require an allocator parameter. Functions that allocate memory must accept `allocator: std.mem.Allocator` as a parameter.

- **`ArrayList`**: Zig's dynamic array type. In 0.16, initialized with `.init(allocator)` and must be cleaned up with `.deinit()`. Example: `var list = ArrayList(u8).init(allocator); defer list.deinit();`

- **`ArrayListUnmanaged`**: Manual memory management version of ArrayList. Does not track its own allocator. Used when you need fine-grained control over memory (e.g., custom allocators, arena allocation). Requires explicit `deinit(allocator)` call.

- **`VibeFn`**: Function pointer type for AI safety checks. Defined as: `*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult`. Uses `anyerror!T` because the error type varies based on LLM implementation.

- **`anyerror!T`**: Error union with flexible error type. Used for function pointers and callbacks where the specific error set is not known at compile time. Prefer `!T` (inferred error set) for regular functions.

- **`!T`**: Inferred error set return type. Zig automatically determines possible errors from the function body. Preferred for most functions.

- **Named error set**: Explicitly defined error group. Example: `const MyError = error{OutOfMemory, InvalidInput};`. Used for public APIs to document expected errors.

- **Call site**: Location in code where a function is invoked. Example: In `foo(x, y)`, the line containing this call is the call site.

- **Function signature**: Function declaration including name, parameters, and return type. Example: `fn foo(x: i32, y: i32) !void`

- **`///` doc comment**: Documentation comment for functions/types. Appears in generated docs. Should describe purpose, parameters, and return value.

- **`//!` module comment**: Documentation comment for entire file/module. Placed at top of file.

- **Error union**: Zig's error handling type. `!T` means "returns T or an error". Handled with `try`, `catch`, or `if` expressions.

- **JSONL**: JSON Lines format. Each line is a valid JSON object. Used for logging in this project.

- **yazap**: Third-party Zig package for command-line argument parsing.

- **POSIX regex**: System regex library accessed via `@cImport("regex.h")`. Used for pattern matching in this project.

---

## Prerequisites

**Knowledge needed to follow this plan**:
- Basic Zig syntax (functions, types, error handling)
- How to run shell commands (`grep`, `zig build`)
- Understanding of allocators and memory management

**Setup**:
```bash
# Verify Zig 0.16.0 is installed
zig version  # Should show 0.16.0

# See current compilation errors
zig build    # Will fail with 4 errors

# Run tests after fixes
zig build test
```

## Codebase Context

**Key files**:
- `src/main.zig:23` — Main hook executable, uses `std.fs.File.stdin()` (needs fix)
- `src/output.zig:4,15,29` — JSON output utilities, uses `std.fs.File.stdout()` (needs fix)
- `src/patterns.zig:8` — Pattern loading declaration (signature mismatch)
- `src/report.zig:236` — Pattern loading call site (signature mismatch)
- `src/guard.zig` — Command parsing and sanitization
- `src/pipeline.zig` — Evaluation logic, VibeFn type definition
- `src/flags.zig` — Flag analysis
- `src/process_info.zig` — Process lookup via pgrep
- `src/vibe.zig` — AI safety check, spawns vibe process
- `src/log.zig` — JSONL logging
- `src/settings.zig` — Claude settings parsing
- `src/project.zig` — Git project detection
- `src/root.zig` — Module root
- `build.zig` — Build system configuration
- `build.zig.zon` — Package manifest (specifies Zig 0.16.0)

**Key symbols**:
- `std.Io`, `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`
- `std.ArrayList`, `std.ArrayListUnmanaged`
- `std.StringHashMap`
- `std.json.Value`, `std.json.parseFromSlice`
- `std.process.spawn`, `std.process.Init`
- `std.mem.Allocator`
- `std.fs.path`
- `VibeFn` type: `*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult`

**Technology**:
- Zig 0.16.0 (confirmed in build.zig.zon)
- POSIX regex via `@cImport("regex.h")`
- yazap package for argument parsing

---

## Milestones

### Milestone 1: Fix Blocking Compilation Errors

**Objective**: Resolve all 4 compilation errors that prevent the project from building.

**Compaction context**:
This milestone fixes 4 specific compilation errors in 3 files:
1. `src/main.zig:23` — Change `std.fs.File.stdin()` to `std.Io.File.stdin()`
2. `src/output.zig:4,15,29` — Change `std.fs.File.stdout()` to `std.Io.File.stdout()` and remove unused `io: std.Io` parameters from 3 functions
3. `src/patterns.zig:8` and `src/report.zig:236` — Fix `loadPatterns()` signature mismatch

Key files: `src/main.zig`, `src/output.zig`, `src/patterns.zig`, `src/report.zig`

**Understanding the 4 errors**:

1. **`std.fs.File.stdin()` error**: In Zig 0.16, stdin/stdout operations moved from `std.fs.File` to `std.Io.File`. The old API is deprecated.

2. **`std.fs.File.stdout()` error**: Same as above — stdout operations must use `std.Io.File.stdout()`.

3. **Unused `io: std.Io` parameters**: Three functions in output.zig accept an `io` parameter they don't use. This causes compiler warnings.

4. **Signature mismatch**: `loadPatterns()` is declared with 2 parameters but called with 3. The call site passes an extra `io` argument that the function doesn't expect.

**Steps**:
1. Read `src/main.zig` and locate line 23 with `std.fs.File.stdin()`
2. Change `std.fs.File.stdin()` to `std.Io.File.stdin()` in `src/main.zig:23`
   ```zig
   // Before:
   const stdin = std.fs.File.stdin();
   
   // After:
   const stdin = std.Io.File.stdin();
   ```
3. Read `src/output.zig` and locate lines 4, 15, and 29 with `std.fs.File.stdout()`
4. Change all three `std.fs.File.stdout()` calls to `std.Io.File.stdout()` in `src/output.zig`
   ```zig
   // Before:
   const stdout = std.fs.File.stdout();
   
   // After:
   const stdout = std.Io.File.stdout();
   ```
5. In `src/output.zig`, identify the 3 functions with unused `io: std.Io` parameters (around lines 4, 15, 29)
6. Remove the unused `io: std.Io` parameters from those function signatures and update call sites
   ```zig
   // Before (in output.zig):
   pub fn allow(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !void { ... }
   
   // After (in output.zig):
   pub fn allow(allocator: std.mem.Allocator, command: []const u8) !void { ... }
   
   // Before (call site in main.zig or report.zig):
   try output.allow(io, allocator, command);
   
   // After (call site):
   try output.allow(allocator, command);
   ```
   **How to update call sites**: Search for all calls to `output.allow`, `output.deny`, and `output.ask`. Remove the `io` argument from each call.
7. Read `src/patterns.zig:8` to see the `loadPatterns()` function declaration
8. Read `src/report.zig:236` to see how `loadPatterns()` is called
9. **Decide on signature fix** — Choose ONE option:
   
   **Option A: Remove `io` from call site** (RECOMMENDED)
   - **When to choose**: The `loadPatterns()` function doesn't use the `io` parameter (no I/O operations in patterns.zig)
   - **How**: Remove the `io` argument from the call in report.zig:236
   ```zig
   // Before (report.zig:236):
   const patterns = try loadPatterns(io, allocator, allow_file);
   
   // After:
   const patterns = try loadPatterns(allocator, allow_file);
   ```
   
   **Option B: Add `io` to declaration**
   - **When to choose**: If patterns.zig needs I/O access for future expansion
   - **How**: Add `io: std.Io` parameter to loadPatterns() in patterns.zig:8
   ```zig
   // Before (patterns.zig:8):
   fn loadPatterns(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 { ... }
   
   // After:
   fn loadPatterns(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 { ... }
   ```
   
   **Recommendation**: Choose **Option A** (remove from call site) because patterns.zig only reads files using allocator-based APIs, not I/O handles.
10. Apply the signature fix consistently in both files
11. Run `zig build` to verify all compilation errors are resolved

**Troubleshooting**:
- **Error: "unused parameter"**: You removed the parameter from the function but forgot to update call sites. Search for all calls to the function.
- **Error: "expected X arguments, found Y"**: Signature mismatch not fully resolved. Check both declaration and all call sites.
- **Error: "std.fs.File has no member 'stdin'"**: You're still using the old API. Change to `std.Io.File.stdin()`.

**Verification**:
- `zig build` completes without errors
- No warnings about unused parameters
- Both `hook` and `report` executables are built successfully in `zig-out/bin/`

---

### Milestone 2: Audit std.Io vs std.fs Consistency Across All Source Files

**Objective**: Ensure all file I/O operations use consistent std.Io namespace patterns throughout the codebase.

**Compaction context**:
After fixing compilation errors, audit all source files to verify consistent use of std.Io namespace. The codebase currently uses `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`. Search for any remaining `std.fs.File.*` or `std.fs.Dir.*` usage that should be migrated to `std.Io.*` equivalents. Note: `std.fs.path.*` may remain as-is since path operations are separate from I/O.

Key files to audit: All files in `src/` directory
Key patterns: `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`, `std.fs.File`, `std.fs.Dir`, `std.fs.path`

**Understanding std.Io vs std.fs**:

In Zig 0.16:
- **`std.Io`** (Input/Output): Used for reading and writing data. Examples:
  - `std.Io.File.stdin()` — Read from standard input
  - `std.Io.File.stdout()` — Write to standard output
  - `std.Io.Dir.cwd()` — Get current working directory
  - `std.Io.Clock` — Time operations

- **`std.fs`** (Filesystem): Used for path manipulation and filesystem metadata. Examples:
  - `std.fs.path.join()` — Join path components (stays in std.fs)
  - `std.fs.path.dirname()` — Get directory from path (stays in std.fs)
  - File/directory metadata operations

**Rule of thumb**: If you're reading/writing data, use `std.Io.File`. If you're manipulating path strings, use `std.fs.path`.

**Steps**:
1. Search all source files for `std.fs.File` usage: `grep -r "std\.fs\.File" src/`
2. Search all source files for `std.fs.Dir` usage: `grep -r "std\.fs\.Dir" src/`
3. Search all source files for `std.Io` usage: `grep -r "std\.Io" src/`
4. For each `std.fs.File` or `std.fs.Dir` found, determine if it should be `std.Io.File` or `std.Io.Dir`
   ```zig
   // Before (old pattern):
   const file = try std.fs.File.open(.{ .path = path, .mode = .read_only });
   
   // After (0.16 pattern):
   const file = try std.Io.Dir.cwd().openFile(path, .{});
   
   // OR for reading entire file:
   const contents = try std.Io.Dir.cwd().readFileAlloc(allocator, path, .unlimited);
   ```
5. Update any inconsistent patterns to use `std.Io` namespace
6. Verify `std.fs.path` usage is appropriate (path operations are typically correct as-is)
7. Check reader/writer interface patterns for consistency across files
8. Verify that `std.Io.Clock` is used consistently for time operations
9. Run `zig build` after each file change to catch any issues early

**Troubleshooting**:
- **Error: "std.Io.Dir has no member 'openFile'"**: Check Zig version — this API changed in 0.16. Use `std.Io.Dir.cwd().openFile(path, .{})`.
- **Error: "expected std.Io.File, found std.fs.File"**: You have a type mismatch. Ensure all I/O operations use std.Io consistently.
- **grep finds std.fs.path**: This is CORRECT. Path operations stay in std.fs.

**Verification**:
- `grep -r "std\.fs\.File" src/` returns no results (or only legitimate path operations)
- `grep -r "std\.fs\.Dir" src/` returns no results (or only legitimate path operations)
- `zig build` completes without errors
- All file I/O uses consistent `std.Io.File`, `std.Io.Dir` patterns

---

### Milestone 3: Audit Allocator Passing and ArrayList Patterns

**Objective**: Verify allocator passing is explicit and consistent, and review ArrayList/ArrayListUnmanaged usage.

**Compaction context**:
Audit memory management patterns across all source files. Key concerns:
1. Allocator passing should be explicit (passed as `allocator: std.mem.Allocator` parameter)
2. `std.ArrayList` should use `.init(allocator)` with explicit allocator (not `.empty`)
3. `std.ArrayListUnmanaged` in report.zig should be reviewed — keep if manual control is needed, otherwise consider migrating to explicit allocator passing with ArrayList

Key files: `src/report.zig` (uses ArrayListUnmanaged), all other src/*.zig files
Key patterns: `std.ArrayList`, `std.ArrayListUnmanaged`, `std.mem.Allocator`, `.init(allocator)`

**Understanding allocator patterns**:

In Zig, memory management is explicit:
```zig
// Correct pattern for ArrayList:
const allocator = std.heap.page_allocator;
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();  // Always call deinit() to free memory

try list.append('a');

// Correct pattern for ArrayListUnmanaged:
var unmanaged_list = std.ArrayListUnmanaged(u8){};
defer unmanaged_list.deinit(allocator);  // Must pass allocator to deinit

try unmanaged_list.append(allocator, 'a');
```

**When to use ArrayListUnmanaged**:
- You need fine-grained control over when memory is allocated
- You're using custom allocators or arena allocation
- You need to move the ArrayList without copying
- You're building complex data structures with shared ownership

**When to use regular ArrayList**:
- Simple cases where automatic memory management is preferred
- You want clearer ownership semantics
- You don't need manual control

**Steps**:
1. Read `src/report.zig` to understand current ArrayListUnmanaged usage patterns
2. Search for all `ArrayListUnmanaged` usage: `grep -r "ArrayListUnmanaged" src/`
3. For each ArrayListUnmanaged, verify it has a legitimate use case (manual memory control needed)
   - **Check**: Is there a `deinit(allocator)` call for every ArrayListUnmanaged?
   - **Check**: Is manual control actually needed, or would regular ArrayList work?
   - **If keeping**: Add comment explaining why: `// Using Unmanaged for manual control over memory lifetime`
4. Search for ArrayList usage patterns: `grep -r "ArrayList" src/`
5. Verify all ArrayList instances use `.init(allocator)` pattern:
   ```zig
   // Before (incorrect):
   var list = std.ArrayList(u8){};
   
   // After (correct):
   var list = std.ArrayList(u8).init(allocator);
   defer list.deinit();
   ```
6. Verify allocator is explicitly passed to ArrayList operations (`.init(allocator)`, `.deinit()`)
7. Check for any implicit allocator usage or missing deinit calls
   - Search for `std.heap.page_allocator` — these should use passed allocators instead
   - Search for `ArrayList` without matching `deinit()` — add `defer` statements
8. Update any inconsistent allocator passing patterns
9. Add comments where ArrayListUnmanaged is intentionally used for manual control
   ```zig
   // Using ArrayListUnmanaged because we need to control when memory
   // is freed (during iterative pattern file processing)
   var patterns = std.ArrayListUnmanaged([]const u8){};
   ```
10. Run `zig build` to verify changes compile correctly

**Troubleshooting**:
- **Error: "ArrayList.init requires allocator"**: You're using `{}` initializer. Change to `.init(allocator)`.
- **Warning: "leaking memory"**: Missing `deinit()` call. Add `defer list.deinit()` after initialization.
- **Error: "ArrayListUnmanaged.deinit requires allocator"**: Unmanaged lists need allocator passed to deinit.

**Verification**:
- All ArrayList instances use explicit allocator passing (`.init(allocator)`)
- All ArrayList instances have matching init/deinit calls
- ArrayListUnmanaged usage is documented with comments explaining why manual control is needed
- `zig build` completes without errors
- No memory leak warnings from Zig compiler

**Test for memory leaks**:
```bash
# Run tests with leak detection
zig build test

# Check for any allocator-related warnings in build output
zig build 2>&1 | grep -i leak
```

---

### Milestone 4: Audit Error Handling Patterns

**Objective**: Ensure error handling uses consistent error union patterns throughout the codebase.

**Compaction context**:
Review error handling across all source files. Key patterns to verify:
1. Regular functions should use `!T` return types (inferred error sets)
2. Function pointers (like VibeFn) may need `anyerror!T` for flexibility
3. Error sets should be named where appropriate for better documentation
4. Error propagation should use `try` consistently
5. Bare `catch {}` should be reviewed — add logging or justification

Key files: All `src/*.zig` files, especially `src/pipeline.zig` (defines VibeFn)
Key patterns: `!T`, `anyerror!T`, `try`, `catch`, error set declarations

**Understanding error handling patterns**:

```zig
// Inferred error set (preferred for most functions):
fn readFile(path: []const u8) ![]const u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, .unlimited);
}

// Named error set (for public APIs):
const ParseError = error{InvalidFormat, OutOfMemory};
fn parseInput(input: []const u8) ParseError!Config {
    // ...
}

// anyerror!T (only for function pointers/callbacks):
const CallbackFn = *const fn (data: []const u8) anyerror!void;
// Used when error type varies based on implementation
```

**VibeFn type** (from src/pipeline.zig):
```zig
*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult
```
Uses `anyerror!T` because different LLM implementations may return different errors.

**Steps**:
1. Read `src/pipeline.zig` to understand VibeFn type definition
2. Search for `anyerror` usage: `grep -r "anyerror" src/`
3. Verify `anyerror!T` is only used where necessary (function pointers, callbacks)
   - **If found in regular functions**: Change to `!T` or define named error set
   - **If in VibeFn or similar**: Keep as-is (flexibility needed)
4. Search for error set declarations: `grep -r "error{" src/`
5. Add named error sets where they improve API documentation
   ```zig
   // Before:
   fn loadConfig(path: []const u8) !Config { ... }
   
   // After (with named error set):
   const ConfigError = error{FileNotFound, ParseError, OutOfMemory};
   fn loadConfig(path: []const u8) ConfigError!Config { ... }
   ```
6. Verify consistent use of `try` for error propagation
7. Check for any bare `catch {}` without proper error handling
   ```zig
   // Before (silent failure):
   log.appendEntry(...) catch {};
   
   // After (with logging):
   log.appendEntry(...) catch |err| {
       std.debug.print("Warning: log write failed: {}\n", .{err});
   };
   ```
8. Update inline comments to document error conditions where helpful
   ```zig
   /// Returns error.FileNotFound if pattern file doesn't exist
   /// Returns error.ParseError if pattern file contains invalid regex
   fn loadPatterns(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 { ... }
   ```
9. Run `zig build` to verify changes compile correctly

**Troubleshooting**:
- **Error: "error set is too large"**: You're using `anyerror!T` in too many places. Define specific error sets.
- **Warning: "unused error"**: You're catching an error but not handling it. Add logging or remove the catch.
- **Error: "expected error union, found T"**: Function returns error but caller doesn't handle it. Add `try` or `catch`.

**Verification**:
- `anyerror` usage is limited to function pointer types and callbacks (like VibeFn)
- Named error sets are used for public APIs where appropriate
- Error propagation is consistent with `try` keyword
- Bare `catch {}` is either removed or has explanatory comment
- `zig build` completes without errors

---

### Milestone 5: Update Documentation and Inline Comments

**Objective**: Update inline comments and documentation to reflect Zig 0.16 patterns.

**Compaction context**:
Review and update all inline comments to reference correct 0.16 APIs and patterns. This includes:
1. Comments referencing old std.fs.File patterns should mention std.Io.File
2. Comments about allocator patterns should reflect 0.16 conventions
3. Add function documentation where missing
4. Update any outdated API references

Key files: All `src/*.zig` files
Key patterns: `///` doc comments, `//!` module comments, inline `//` comments

**Documentation standards**:

```zig
//! Module-level documentation (at top of file)
//! This module handles JSON output for hook decisions.

/// Function documentation (above function)
/// Writes an allow decision to stdout in JSON format.
///
/// Parameters:
///   allocator - Memory allocator for temporary buffers
///   command - The command that was allowed
///
/// Returns:
///   error.WriteFailure if stdout is unavailable
pub fn allow(allocator: std.mem.Allocator, command: []const u8) !void { ... }

// Inline comment (explains implementation detail)
// Using ArrayListUnmanaged here because we need to control
// when memory is freed during iterative pattern processing
```

**Steps**:
1. Search for comments referencing file I/O: `grep -r "//.*File" src/`
2. Update any comments mentioning `std.fs.File` to reference `std.Io.File` where appropriate
   ```zig
   // Before:
   // Read from stdin using std.fs.File
   
   // After:
   // Read from stdin using std.Io.File
   ```
3. Search for comments about memory management: `grep -r "//.*alloc" src/`
4. Update allocator-related comments to reflect 0.16 patterns
   ```zig
   // Before:
   // Allocate with default allocator
   
   // After:
   // Allocate with explicit allocator (0.16 pattern)
   ```
5. Add `///` doc comments to public functions that lack documentation
   - All `pub fn` functions need `///` comments
   - Describe purpose, parameters, return value, and error conditions
6. Add `//!` module-level comments to files that lack them
   - Place at very top of file
   - Describe module's purpose and main types/functions
7. Review `src/root.zig` for module documentation
8. Verify comments accurately describe current behavior after all changes
9. Run `zig build` to ensure no issues introduced

**Files requiring complete documentation**:
- `src/main.zig` — Main entry point and hook lifecycle
- `src/report.zig` — Report tool CLI commands
- `src/output.zig` — JSON output formatting
- `src/patterns.zig` — Pattern loading and matching
- `src/pipeline.zig` — Safety pipeline and VibeFn
- `src/guard.zig` — Command sanitization
- `src/vibe.zig` — LLM safety check
- `src/log.zig` — JSONL logging
- `src/settings.zig` — Settings file parsing
- `src/project.zig` — Git project detection

**Troubleshooting**:
- **Build fails after adding comments**: Check for syntax errors in comments (unmatched braces, etc.)
- **Comments don't match code**: Update comments to reflect actual implementation after changes

**Verification**:
- No comments reference deprecated APIs (std.fs.File for I/O)
- All public functions (`pub fn`) have `///` documentation comments
- All module files have `//!` module-level documentation at top
- `zig build` completes without errors

---

### Milestone 6: Final Verification and Test Execution

**Objective**: Run complete build and test suite to verify all modernization is complete.

**Compaction context**:
Final verification milestone. Run all build and test commands to ensure the codebase compiles cleanly and all tests pass. This is the gate for considering the modernization complete.

Key commands: `zig build`, `zig build test`
Success criteria: No errors, no deprecation warnings, all tests pass

**Steps**:
1. Run `zig build` and capture output
   ```bash
   zig build 2>&1 | tee build-output.txt
   ```
2. Verify both `hook` and `report` executables are built
   ```bash
   ls -la zig-out/bin/
   # Should show: hook, report
   ```
3. Check for any warnings in build output (deprecation, unused, etc.)
   ```bash
   grep -i "warning\|deprecated\|unused" build-output.txt
   # Should return no results
   ```
4. Run `zig build test` and capture output
   ```bash
   zig build test 2>&1 | tee test-output.txt
   ```
5. Verify all tests pass
   ```bash
   grep -E "PASS|FAIL" test-output.txt
   # All tests should show PASS
   ```
6. If any tests fail, investigate and fix
   - Read test failure output
   - Check if failure is due to modernization change or pre-existing issue
   - Fix and re-run tests
7. Run `zig build` one final time to confirm clean build
8. **Manual integration testing**:
   ```bash
   # Test hook executable with sample input
   echo '{"content": {"toolUse": {"input": {"command": "ls -la"}}}}' | zig-out/bin/hook
   
   # Test report CLI
   zig-out/bin/report --help
   
   # Test pattern loading
   zig-out/bin/report patterns
   ```
9. Document any remaining warnings or issues for future work

**Integration test recommendations** (from tester review):

Add these tests to verify component interactions:

```zig
// tests/integration_test.zig

test "hook reads from stdin and writes to stdout" {
    // Test stdin/stdout I/O pattern after std.Io migration
    const input = "{\"content\": {\"toolUse\": {\"input\": {\"command\": \"ls\"}}}}";
    // Verify hook parses input and produces valid JSON output
}

test "loadPatterns signature is consistent" {
    // Test that loadPatterns() can be called without io parameter
    const patterns = try loadPatterns(allocator, "test.allow");
    try std.testing.expect(patterns.len > 0);
}

test "pattern matching works correctly" {
    // Test pattern matching after modernization
    const test_patterns = [_][]const u8{"^git\\b", "^npm\\b"};
    try std.testing.expect(try patterns.matchesAny(allocator, &test_patterns, "git commit"));
    try std.testing.expect(!try patterns.matchesAny(allocator, &test_patterns, "rm -rf /"));
}

test "ArrayList memory management is correct" {
    // Test for memory leaks in ArrayList usage
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create and destroy ArrayLists
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.append('a');
    
    // If this test passes without leak detection errors, memory management is correct
}
```

**Troubleshooting**:
- **Build fails**: Check error message for file/line. Revert recent changes if needed.
- **Tests fail**: Check if failure is due to modernization or pre-existing. Use `git diff` to identify changes.
- **Memory leak detected**: Check for missing `deinit()` calls on ArrayList or other allocator-aware types.
- **Executable not found**: Run `zig build` first to generate executables in `zig-out/bin/`.

**Verification**:
- `zig build` completes with exit code 0
- No warnings about deprecated APIs
- `zig build test` completes with exit code 0
- All tests pass
- Executables are produced in `zig-out/bin/` (hook, report)
- Manual integration tests pass (hook reads stdin, report CLI works)

---

## Testing Strategy

**Test framework**: Zig's built-in test framework (`test` blocks)

**Coverage targets**:
- All existing tests must pass after modernization
- No new test failures introduced by pattern changes
- Critical paths (command parsing, pattern matching, logging) should have test coverage

**Key integration points**:
1. `src/main.zig` — stdin/stdout I/O patterns
2. `src/patterns.zig` — Pattern loading and matching
3. `src/report.zig` — CLI argument handling and file operations
4. `src/pipeline.zig` — VibeFn callback interface
5. `src/log.zig` — JSONL logging operations

**Test commands**:
```bash
zig build test          # Run all tests
zig build               # Verify clean build
zig-out/bin/hook        # Manual test of hook executable
zig-out/bin/report help # Manual test of report CLI
```

---

## Documentation Requirements

**Inline documentation**:
- All public functions must have `///` doc comments
- Module files should have `//!` module-level documentation
- Comments must reference correct Zig 0.16 APIs (std.Io.File, not std.fs.File)

**Where docs live**:
- Inline in source files (`src/*.zig`)
- `src/root.zig` for module-level documentation

**Migration notes** (for future reference):
- Document the std.Io vs std.fs decision in comments
- Note any ArrayListUnmanaged usage with justification
- Document any `anyerror!T` usage with explanation

---

## Rollback Plan

If issues arise during modernization:

1. **Before each milestone**: Commit current state with `git commit`
   ```bash
   git add -A
   git commit -m "Before Milestone X: [description]"
   ```

2. **If compilation fails**: Revert the specific file changes causing issues
   ```bash
   # See what changed
   git diff
   
   # Revert specific file
   git checkout HEAD -- src/main.zig
   
   # Or revert all source files
   git checkout HEAD -- src/
   ```

3. **If tests fail**: Check if failure is due to pattern change or logic error
   ```bash
   # See test output
   zig build test
   
   # Check recent changes
   git diff HEAD~1 src/
   ```

4. **Full rollback command**: `git checkout HEAD -- src/` to restore all source files

5. **Checkpoint tags**: Create git tags after each milestone for easy rollback
   ```bash
   git tag -a milestone-1-complete -m "Milestone 1: Fixed compilation errors"
   git tag -a milestone-2-complete -m "Milestone 2: std.Io consistency audit"
   ```

---

## Success Criteria Checklist

### Compilation (Milestone 1)
- [ ] All 4 compilation errors are fixed
- [ ] `zig build` completes without errors or warnings
- [ ] Both `hook` and `report` executables built in `zig-out/bin/`

### Code Quality (Milestones 2-4)
- [ ] All source files use consistent std.Io patterns
- [ ] No Zig compiler warnings about deprecated APIs
- [ ] All ArrayList instances use explicit allocator passing
- [ ] All ArrayList instances have matching init/deinit calls
- [ ] ArrayListUnmanaged usage is documented with justification
- [ ] Error handling uses consistent patterns (`!T` for functions, `anyerror!T` only for callbacks)

### Documentation (Milestone 5)
- [ ] Inline comments reflect 0.16 patterns
- [ ] All public functions have `///` documentation
- [ ] All module files have `//!` module comments
- [ ] No comments reference deprecated APIs

### Testing (Milestone 6)
- [ ] `zig build test` passes
- [ ] Test coverage maintained or improved
- [ ] Manual integration tests pass (hook stdin, report CLI)

### Security (from pessimist review)
- [ ] All bare `catch {}` reviewed and either removed or justified with comments
- [ ] Input validation verified for JSON parsing
- [ ] Memory leak detection passes (no leaks in normal operation)
