---
name: add-command-flags
description: Generate flag-safety rules in src/flags.zig for a command
type: skill
---

# add-command-flags

Generate flag-safety rules in `src/flags.zig` for a command (or subcommand).

## Usage

```
/add-command-flags <command>
/add-command-flags "git push"
```

The argument is either a bare command (`find`) or a quoted "command subcommand" pair (`"git push"`).

## What this skill does

1. Fetches the command's help text from `man` or `--help`
2. Classifies flags as **dangerous** (escalate to vibe) or **safe** (allow fast-path)
3. Generates a `CmdDef` entry and inserts it into `RULES` in `src/flags.zig`
4. Adds focused tests in `src/flags.zig`
5. Runs `zig build test --summary all`
6. Iterates on failures (up to 3 times), then reports

## Instructions

Parse the argument. If it contains a space (e.g. `"git push"`), the first word is the command and the second is the subcommand. If no argument is given, ask the user.

---

### Step 1 — get help text

For a bare command (e.g. `find`):
```
man <cmd> 2>/dev/null | col -b | head -150
```
If man returns nothing:
```
<cmd> --help 2>&1 | head -100
```

For a "command subcommand" pair (e.g. `git push`):
```
man git-push 2>/dev/null | col -b | head -150
```
If that returns nothing, try `git push --help 2>&1 | head -100` or `git help push 2>/dev/null | col -b | head -150`.

If nothing works, tell the user the command was not found.

---

### Step 2 — classify flags

From the help text, identify:

**Dangerous flags** (`.escalate`) — flags that execute arbitrary code, delete/overwrite files,
modify network/system state in ways that are hard to reverse, or bypass safety checks. Examples:
- `find`: `-exec`, `-execdir`, `-delete`, `-ok`, `-okdir`
- `git push`: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, `--mirror`, `--delete`
- `rsync`: `--delete`, `--delete-before`, `--remove-source-files`

**Safe flags** (`.allow`) — flags that make the invocation explicitly read-only, a dry-run, or
otherwise non-destructive. Examples:
- `git push --dry-run`, `-n`
- `rsync --dry-run`, `-n`

**Everything else** is `.pass` (no rule needed — omit from the list).

Keep the list minimal: only include flags where classification adds real value. Don't enumerate
every boolean flag that happens to be benign.

For the `default` verdict when no flag matches:
- Use `.pass` in almost all cases (no opinion → fall to allow list or vibe)
- Use `.escalate` only if the command is dangerous by default even with no flags (rare)

---

### Step 3 — determine structure

**Bare command with no subcommand awareness** (like `find`):
```zig
.{
    .name = "find",
    .subcmds = &.{},
    .cmd_rules = &.{
        .{ .flag = "-exec",    .verdict = .escalate },
        .{ .flag = "-execdir", .verdict = .escalate },
        .{ .flag = "-delete",  .verdict = .escalate },
        .{ .flag = "-ok",      .verdict = .escalate },
        .{ .flag = "-okdir",   .verdict = .escalate },
    },
    .cmd_default = .pass,
},
```

**Command + subcommand** (like `git push`). If the command entry already exists in RULES,
add a new entry to its `.subcmds` slice instead of creating a duplicate top-level entry.
If it doesn't exist yet:
```zig
.{
    .name = "git",
    .subcmds = &.{
        .{
            .subcmd = "push",
            .rules = &.{
                .{ .flag = "--dry-run",            .verdict = .allow },
                .{ .flag = "-n",                   .verdict = .allow },
                .{ .flag = "--force",              .verdict = .escalate },
                .{ .flag = "-f",                   .verdict = .escalate },
                .{ .flag = "--force-with-lease",   .verdict = .escalate },
                .{ .flag = "--force-if-includes",  .verdict = .escalate },
                .{ .flag = "--mirror",             .verdict = .escalate },
                .{ .flag = "--delete",             .verdict = .escalate },
            },
            .default = .pass,
        },
    },
    .cmd_rules = &.{},
    .cmd_default = .pass,
},
```

---

### Step 4 — insert into RULES

Read `src/flags.zig`. Find the `RULES` array. The comment `// entries inserted here by /add-command-flags` marks the insertion point.

**If the command does NOT already have an entry:** insert the new `CmdDef` before the comment line.

**If the command ALREADY has an entry and you're adding a subcommand:**
- Find the existing entry for that command
- Add the new `SubcmdDef` to its `.subcmds` slice
- Do NOT create a duplicate top-level entry

Use the Edit tool for the insertion. Do not reformat surrounding code.

---

### Step 5 — add tests

Add test cases immediately after the last existing test block in `src/flags.zig`.
Follow the existing test style. Include:

- One test for a dangerous flag → `.escalate`
- One test verifying the trigger field contains the flag name (for escalate cases)
- One test for a safe flag → `.allow` (if applicable)
- One test for a neutral flag → `.pass`
- One test for the command with no flags at all → `.pass` (or `.escalate` if cmd_default is .escalate)

Example pattern:
```zig
test "flags: find -exec escalates" {
    const result = check("find . -exec rm {} ;");
    try std.testing.expect(result.verdict == .escalate);
    try std.testing.expectEqualStrings("-exec", result.trigger);
}

test "flags: find -delete escalates" {
    const result = check("find . -name '*.log' -delete");
    try std.testing.expect(result.verdict == .escalate);
}

test "flags: find -name passes" {
    const result = check("find . -name '*.txt'");
    try std.testing.expect(result.verdict == .pass);
}

test "flags: find with no flags passes" {
    const result = check("find .");
    try std.testing.expect(result.verdict == .pass);
}
```

---

### Step 6 — build and test

```
cd /Users/jwatson/Documents/zig/bash-tool-guard && zig build test --summary all
```

If tests fail, read the error, fix the code, and retry up to 3 times.

---

### Step 7 — report

Show:
- Which flags were classified as dangerous / safe / omitted
- The generated `CmdDef` (the new entry only)
- Test count and pass/fail

Do **not** commit automatically. Ask the user if they want to commit.
