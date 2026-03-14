# add-wrapper

Generate a `splitWrapper` case in `src/guard.zig` for a new transparent wrapper command.

## Usage

```
/add-wrapper <command-name>
```

Example: `/add-wrapper nice`

## What this skill does

1. Fetches the command's help text (`man <cmd>` or `<cmd> --help`)
2. Identifies which flags consume a value token vs are boolean, and how many positional args precede the sub-command
3. Generates a new `} else if (std.mem.eql(u8, first, "<cmd>")) {` case in `splitWrapper`
4. Adds 2–3 representative test cases in the `// --- splitWrapper ---` test section
5. Updates the doc comment listing supported wrappers
6. Runs `zig build test --summary all` to verify
7. If tests pass, reports the diff; if they fail, iterates

## Instructions

Extract the command name from the skill arguments. If none provided, ask the user.

### Step 1 — get help text

Run `man <cmd> 2>/dev/null | col -b | head -120` to get plain-text man page output.
If man returns nothing, run `<cmd> --help 2>&1 | head -80`.
If both fail, tell the user the command was not found.

### Step 2 — analyze the argument structure

From the help text, determine:

- **flag-only wrappers** (like `nohup`): no own args at all — just skip whitespace then expect sub-command
- **flags-then-command wrappers** (like `time`): skip any leading `-flag` tokens, then expect sub-command
- **flags-positionals-then-command wrappers** (like `timeout DURATION CMD`, `nice -n N CMD`): skip flags (some consuming a value), skip N positional args, then expect sub-command
- **flags-assignments-then-command wrappers** (like `env`): skip flags and `KEY=VAL` tokens, first plain token is sub-command

For flags that consume a separate value token, list each short and long form explicitly (e.g. `-s`, `--signal`). Only include flags where the value is NOT embedded with `=` — those are handled automatically.

### Step 3 — generate the Zig case

Follow the exact patterns from the existing cases in `src/guard.zig`. The four templates are:

**Template A — no own args (nohup style):**
```zig
} else if (std.mem.eql(u8, first, "COMMAND")) {
    // COMMAND CMD [ARG]... — no own args
    i = skipWs(seg, i);
    if (i >= seg.len) return null;
```

**Template B — flags only before sub-command (time style):**
```zig
} else if (std.mem.eql(u8, first, "COMMAND")) {
    // COMMAND [flags] CMD [ARG]... — skip optional flags
    while (true) {
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        if (seg[i] != '-') break;
        i = skipTok(seg, i);
    }
```

**Template C — flags + N positionals before sub-command (timeout/nice style):**
```zig
} else if (std.mem.eql(u8, first, "COMMAND")) {
    // COMMAND [OPTION] POS1 [POS2...] CMD [ARG]...
    while (true) {
        i = skipWs(seg, i);
        if (i >= seg.len) return null;
        if (seg[i] != '-') break;
        const tok_start = i;
        i = skipTok(seg, i);
        const tok = seg[tok_start..i];
        const takes_val = std.mem.indexOfScalar(u8, tok, '=') == null and
            (std.mem.eql(u8, tok, "-X") or
            std.mem.eql(u8, tok, "--long-flag"));
        if (takes_val) {
            i = skipWs(seg, i);
            i = skipTok(seg, i);
        }
    }
    // Skip N positional args
    // (repeat the block below N times)
    i = skipWs(seg, i);
    if (i >= seg.len) return null;
    i = skipTok(seg, i);
    // Now at sub-command
    i = skipWs(seg, i);
    if (i >= seg.len) return null;
```

**Template D — flags + KEY=VAL assignments before sub-command (env style):**
Use only if the command has a distinct assignment-token syntax. Refer directly to the existing `env` case.

### Step 4 — insert the case

Read `src/guard.zig`. Insert the new case immediately before the final `} else {` in `splitWrapper`. Do not reformat surrounding code.

Update the doc comment block above `splitWrapper` to add the new command in the supported-wrappers list.

### Step 5 — add tests

Add 2–3 test cases in the `// --- splitWrapper ---` section of `src/guard.zig`, after the last existing `splitWrapper` test. Follow the existing test style exactly:

```zig
test "splitWrapper: COMMAND basic split" {
    const result = splitWrapper("COMMAND [own-args] git status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("COMMAND [own-args]", result.?.wrapper_part);
    try std.testing.expectEqualStrings("git status", result.?.inner_part);
}

test "splitWrapper: COMMAND alone has no sub-command" {
    try std.testing.expect(splitWrapper("COMMAND") == null);
}
```

### Step 6 — build and test

Run: `cd /Users/jwatson/Documents/zig/bash-tool-guard && zig build test --summary all`

If tests fail, read the failure output, fix the generated code, and re-run. Iterate up to 3 times before reporting failure to the user.

### Step 7 — report

Show the user:
- A brief summary of the wrapper's argument structure as understood
- The generated Zig case (just the new `else if` block)
- Test results

Do not commit automatically. Ask the user if they want to commit.

Also remind the user to add a matching allow pattern to `~/.local/etc/btg.allow` if they want the new wrapper to be usable on the fast path. Example for `nice`:
```
^nice(\s+-n\s+\S+)?$
```
