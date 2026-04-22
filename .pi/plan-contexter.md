# Context Window Review & Agent/Skill Assignment Analysis

## Context Window Review

### Context Survival Analysis

#### Milestone 1: Fix Blocking Compilation Errors

**Self-Contained**: Yes - Highly self-contained with clear, specific file/line targets

**Context Needed**:
- Exact file paths and line numbers (included in milestone)
- Specific API changes required (`std.fs.File` → `std.Io.File`)
- Signature mismatch details for `loadPatterns()` (included)
- Build verification steps (included)

**Risk if Compacted**: Low - All necessary context is explicitly stated in the milestone

**Recommended Agent**: `zig-code-generator` (general Zig modernization agent)
**Agent Rationale**: Straightforward file edits with clear patterns. No complex threading, memory management, or async operations that require specialized agents.

**Recommended Skills**: `zig-programming`
**Skill Rationale**: Ensures idiomatic Zig patterns are used and prevents introduction of deprecated APIs or unsafe patterns during the fixes.

---

#### Milestone 2: Audit std.Io vs std.fs Consistency Across All Source Files

**Self-Contained**: Yes - Clear scope with grep patterns and verification criteria

**Context Needed**:
- List of patterns to search for (`std.fs.File`, `std.fs.Dir`, `std.Io.File`, `std.Io.Dir`)
- Verification criteria (grep results should be empty for inconsistent patterns)
- Build verification steps (included)

**Risk if Compacted**: Low - The grep patterns and consistency rules are explicit and repeatable

**Recommended Agent**: `zig-code-generator`
**Agent Rationale**: Systematic search-and-replace across multiple files. No complex logic changes.

**Recommended Skills**: `zig-programming`
**Skill Rationale**: Ensures all std.Io vs std.fs decisions are consistent and idiomatic.

---

#### Milestone 3: Audit Allocator Passing and ArrayList Patterns

**Self-Contained**: Partial - Requires understanding of current ArrayListUnmanaged usage in report.zig

**Context Needed**:
- Current ArrayListUnmanaged usage patterns in report.zig (must be read from source)
- Explicit allocator passing patterns to verify (included in milestone)
- `.empty` initializer pattern (included)
- Verification criteria for init/deinit calls (included)

**Risk if Compacted**: Medium - Would need to re-read report.zig to understand current ArrayListUnmanaged usage

**Recommended Agent**: `zig-code-generator-small`
**Agent Rationale**: Memory management patterns require careful handling. ArrayListUnmanaged specifically needs review to determine if it's still the recommended pattern.

**Recommended Skills**: `zig-programming`, `zig-memory-safety`
**Skill Rationale**: Memory management is critical. The `zig-memory-safety` skill ensures no leaks or double-frees are introduced, and validates ArrayListUnmanaged usage is intentional.

---

#### Milestone 4: Audit Error Handling Patterns

**Self-Contained**: Partial - Requires understanding of VibeFn type and current error handling patterns

**Context Needed**:
- VibeFn type definition from src/pipeline.zig (referenced but not repeated)
- Patterns to verify (`!T` vs `anyerror!T`, `try` usage)
- Error set declaration patterns (included)
- Verification criteria (included)

**Risk if Compacted**: Medium - Would need to re-read src/pipeline.zig to understand VibeFn

**Recommended Agent**: `zig-code-generator-small`
**Agent Rationale**: Error handling patterns are straightforward but require understanding of function pointer types.

**Recommended Skills**: `zig-programming`
**Skill Rationale**: Ensures consistent error handling patterns and proper use of `anyerror!T` vs `!T`.

---

#### Milestone 5: Update Documentation and Inline Comments

**Self-Contained**: Yes - Clear documentation requirements and verification steps

**Context Needed**:
- List of comment patterns to update (included)
- Documentation requirements (included)
- Verification criteria (included)

**Risk if Compacted**: Low - Documentation patterns are explicit and repeatable

**Recommended Agent**: `zig-code-generator`
**Agent Rationale**: Documentation updates are systematic and don't involve complex logic.

**Recommended Skills**: `zig-programming`
**Skill Rationale**: Ensures documentation references correct 0.16 APIs and patterns.

---

#### Milestone 6: Final Verification and Test Execution

**Self-Contained**: Yes - Clear verification steps and success criteria

**Context Needed**:
- Build and test commands (included)
- Success criteria (included)
- Rollback plan (included)

**Risk if Compacted**: Low - Verification is straightforward and repeatable

**Recommended Agent**: `zig-build-validator`
**Agent Rationale**: Final verification requires running build and tests, checking for warnings and errors.

**Recommended Skills**: `zig-programming`, `zig-testing`
**Skill Rationale**: Ensures proper test execution and validation of build output for deprecation warnings.

---

### Cross-Milestone Dependencies

- **Milestone 1 → Milestone 2**: File I/O pattern fixes must be complete before auditing consistency
  - **Risk**: If context compacted, agent might forget which files were modified
  - **Mitigation**: Add "Files modified in previous milestone:" section to Milestone 2 context
  - **Agent note**: Same agent can handle both, ensuring continuity

- **Milestone 2 → Milestone 3**: ArrayList usage patterns depend on understanding current state
  - **Risk**: If context compacted, agent would need to re-read report.zig
  - **Mitigation**: Include summary of report.zig's ArrayListUnmanaged usage in Milestone 3
  - **Agent note**: `zig-memory-safety` skill is critical here

- **Milestone 3 → Milestone 4**: Error handling patterns build on allocator patterns
  - **Risk**: Memory management decisions affect error handling
  - **Mitigation**: Include note about allocator patterns in Milestone 4 context
  - **Agent note**: Same agent can handle both with appropriate skills

- **Milestone 4 → Milestone 5**: Documentation updates depend on code changes
  - **Risk**: Documentation might reference old APIs if context is lost
  - **Mitigation**: Include list of changed APIs in Milestone 5 context
  - **Agent note**: Same agent can handle documentation updates

- **Milestone 5 → Milestone 6**: Final verification depends on all previous changes
  - **Risk**: None significant - verification is independent
  - **Mitigation**: None needed

---

### Critical Information to Preserve

1. **Original Intent**: Must survive to prevent scope drift
   - Current location: plan-context.md
   - **Preservation**: Include verbatim in each milestone's context section

2. **Scope Decisions**: Must survive to prevent re-litigating decisions
   - Current location: plan.md
   - **Preservation**: Include key scope decisions in each milestone's context

3. **File Paths and Symbols**: Must survive for accurate edits
   - Examples: `src/main.zig:23`, `src/output.zig:4,15,29`, `src/patterns.zig:8`, `src/report.zig:236`
   - **Preservation**: Include exact file paths and line numbers in each relevant milestone

4. **API Changes Required**: Must survive to prevent mistakes
   - Examples: `std.fs.File.stdin()` → `std.Io.File.stdin()`, `std.fs.File.stdout()` → `std.Io.File.stdout()`
   - **Preservation**: Include API change list in Milestone 1 context

5. **VibeFn Type Definition**: Critical for error handling review
   - Definition: `*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult`
   - **Preservation**: Include in Milestone 4 context

6. **ArrayListUnmanaged Usage in report.zig**: Critical for memory management review
   - **Preservation**: Include summary of current usage in Milestone 3 context

---

### Recommended Context Anchors

#### For All Milestones:

```
## Critical Context Anchors (Survive Compaction)

### Original Intent
I want this code base to upgrade to zig 0.16 idioms.

### Scope Decisions
- Fix all 4 blocking compilation errors
- Audit all source files for std.Io vs std.fs consistency
- Verify allocator passing patterns are consistent
- Review ArrayList/ArrayListUnmanaged usage
- Update inline comments to reflect 0.16 patterns

### Key Files and Symbols
- src/main.zig, src/output.zig, src/patterns.zig, src/report.zig (compilation errors)
- src/pipeline.zig (VibeFn type)
- src/report.zig (ArrayListUnmanaged usage)
- std.Io.File, std.Io.Dir, std.Io.Clock (0.16 I/O patterns)
- std.ArrayList, std.ArrayListUnmanaged (memory management)

### API Changes Required
- std.fs.File.stdin() → std.Io.File.stdin()
- std.fs.File.stdout() → std.Io.File.stdout()
- Remove unused io: std.Io parameters from output.zig functions
- Fix loadPatterns() signature mismatch
```

#### For Milestone 1 Context:

```
### Files Modified in This Milestone
- src/main.zig (line 23): std.fs.File.stdin() → std.Io.File.stdin()
- src/output.zig (lines 4, 15, 29): std.fs.File.stdout() → std.Io.File.stdout()
- src/output.zig (lines 4, 15, 29): Remove unused io: std.Io parameters
- src/patterns.zig (line 8) or src/report.zig (line 236): Fix loadPatterns() signature

### Verification Checklist
- [ ] zig build completes without errors
- [ ] No warnings about unused parameters
- [ ] Both hook and report executables built successfully
```

#### For Milestone 2 Context:

```
### Files to Audit
All files in src/ directory

### Search Patterns
- std.fs.File (should be std.Io.File)
- std.fs.Dir (should be std.Io.Dir)
- std.Io.File (correct)
- std.Io.Dir (correct)

### Verification Checklist
- [ ] grep -r "std\.fs\.File" src/ returns no results
- [ ] grep -r "std\.fs\.Dir" src/ returns no results
- [ ] zig build completes without errors
```

#### For Milestone 3 Context:

```
### Key Patterns to Verify
- Allocator passing: explicit `allocator: std.mem.Allocator` parameter
- ArrayList initialization: `.empty` initializer with explicit allocator
- ArrayListUnmanaged usage: intentional manual memory control

### report.zig ArrayListUnmanaged Usage (Read from source)
[Summary of current usage pattern]

### Verification Checklist
- [ ] All ArrayList instances use explicit allocator passing
- [ ] All ArrayList instances have matching init/deinit calls
- [ ] ArrayListUnmanaged usage is documented with justification
- [ ] zig build completes without errors
- [ ] No memory leak warnings
```

#### For Milestone 4 Context:

```
### VibeFn Type Definition
*const fn (std.Io, std.mem.Allocator, []const u8) anyerror!vibe_mod.VibeResult

### Error Handling Patterns to Verify
- Regular functions: `!T` return types (inferred error sets)
- Function pointers: `anyerror!T` for flexibility
- Error sets: named where appropriate
- Error propagation: `try` keyword

### Verification Checklist
- [ ] anyerror usage limited to function pointers and callbacks
- [ ] Named error sets used for public APIs
- [ ] Error propagation uses `try` consistently
- [ ] zig build completes without errors
```

#### For Milestone 5 Context:

```
### Documentation Requirements
- All public functions: `///` doc comments
- Module files: `//!` module-level documentation
- Comments: reference correct 0.16 APIs

### API Changes to Document
- std.Io.File instead of std.fs.File
- std.Io.Dir instead of std.fs.Dir
- Explicit allocator patterns

### Verification Checklist
- [ ] No comments reference deprecated APIs
- [ ] All public functions have `///` documentation
- [ ] Module files have `//!` documentation
- [ ] zig build completes without errors
```

#### For Milestone 6 Context:

```
### Verification Commands
- zig build
- zig build test
- Check for deprecation warnings

### Success Criteria
- [ ] zig build completes with exit code 0
- [ ] No warnings about deprecated APIs
- [ ] zig build test completes with exit code 0
- [ ] All tests pass
- [ ] Executables in zig-out/bin/

### Rollback Plan
- git commit before each milestone
- git checkout HEAD -- src/ to restore files
```

---

### Agent & Skill Assignments Summary

| Milestone | Agent | Skills | Rationale |
|-----------|-------|--------|----------|
| 1 | zig-code-generator | zig-programming | Straightforward file edits with clear patterns. No complex operations. |
| 2 | zig-code-generator | zig-programming | Systematic search-and-replace across multiple files. |
| 3 | zig-code-generator-small | zig-programming, zig-memory-safety | Memory management patterns require careful handling. ArrayListUnmanaged needs validation. |
| 4 | zig-code-generator-small | zig-programming | Error handling patterns are straightforward but require understanding of function pointers. |
| 5 | zig-code-generator | zig-programming | Documentation updates are systematic and don't involve complex logic. |
| 6 | zig-build-validator | zig-programming, zig-testing | Final verification requires running build/tests and checking for warnings/errors. |

---

### Plan Splitting Recommendation

**Should split**: No - The plan is well-structured into 6 milestones that are mostly self-contained.

**Estimated tokens per milestone**: ~1.5k-2k tokens each (well within context limits)

**Recommendation**: Keep as single plan with the context anchors above added to each milestone. The milestones are naturally sequential and build on each other, making splitting counterproductive.

---

### Critical Context Gaps

1. **report.zig ArrayListUnmanaged usage details**: Not included in plan-context.md
   - **Impact**: Milestone 3 cannot properly validate ArrayListUnmanaged usage without reading the source
   - **Mitigation**: Add summary of report.zig's ArrayListUnmanaged usage to Milestone 3 context

2. **src/pipeline.zig VibeFn type definition**: Not included in plan-context.md
   - **Impact**: Milestone 4 cannot properly validate error handling patterns without understanding VibeFn
   - **Mitigation**: Add VibeFn type definition to Milestone 4 context

3. **Zig 0.16 specific API changes**: Only mentioned generally in plan-context.md
   - **Impact**: Agents might not know exact API changes needed
   - **Mitigation**: Include specific API change list in Milestone 1 context

4. **Build system configuration**: Not mentioned in either plan file
   - **Impact**: Agents might not know build.zig or build.zig.zon details
   - **Mitigation**: Add brief build system overview to all milestones

5. **Test framework details**: Mentioned but not detailed
   - **Impact**: Agents might not know how to run tests or what to verify
   - **Mitigation**: Add test execution details to Milestone 6 context

---

### Additional Recommendations

1. **Agent Continuity**: Use the same agent across all milestones where possible (zig-code-generator for milestones 1, 2, 5; zig-code-generator-small for 3, 4). This ensures context continuity and prevents relearning.

2. **Skill Invocation Timing**:
   - Invoke `zig-memory-safety` skill only for Milestone 3 (memory management focus)
   - Invoke `zig-testing` skill only for Milestone 6 (test execution focus)
   - Use `zig-programming` skill for all milestones to ensure idiomatic patterns

3. **Context Refresh Points**:
   - After Milestone 1: Refresh to ensure file modifications are complete
   - After Milestone 3: Refresh to ensure memory management patterns are validated
   - After Milestone 5: Refresh to ensure documentation is complete

4. **Verification Gates**: Each milestone should have explicit verification steps that produce artifacts (build output, test results) that can be checked before proceeding.

5. **Error Handling**: The rollback plan is solid, but consider adding "git status" checks before each milestone to ensure clean working directory.

---

### Success Criteria for Context Survival

For the plan to survive context compaction and refreshes, the following MUST be preserved in each milestone's working context:

1. ✅ Original intent (verbatim)
2. ✅ Scope decisions (key points)
3. ✅ File paths and line numbers for modifications
4. ✅ API change lists
5. ✅ Verification checklists
6. ✅ Critical symbols (VibeFn, ArrayListUnmanaged)
7. ✅ Agent and skill assignments

If these are preserved, each milestone can execute independently with minimal risk of context loss.
