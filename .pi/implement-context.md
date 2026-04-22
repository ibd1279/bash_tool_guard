# Wave 1 Implementation Context

## Current Wave
**Wave 1 of 6**: Fix Blocking Compilation Errors

## Tasks to Execute
1. Fix `std.fs.File.stdin()` → `std.Io.File.stdin()` in src/main.zig:23
2. Fix `std.fs.File.stdout()` → `std.Io.File.stdout()` in src/output.zig (lines 4, 15, 29)
3. Remove unused `io: std.Io` parameters from output.zig functions (allow, deny, ask)
4. Update call sites in main.zig and report.zig to not pass `io` to output functions
5. Fix `loadPatterns()` signature mismatch: remove `io` argument from call site in report.zig:236

## Files to Modify
- `src/main.zig` - Fix stdin API and update output function call sites
- `src/output.zig` - Fix stdout API and remove unused io parameters
- `src/report.zig` - Update loadPatterns() and output function call sites

## Constraints
- Do NOT change function logic, only API calls and signatures
- Keep all existing error handling patterns
- Verify with `zig build` after changes

## Special Instructions
- For loadPatterns(): Choose Option A (remove io from call site) since patterns.zig doesn't use io parameter
- After all fixes, run `zig build` to verify compilation succeeds
