# bash-tool-guard

A Claude Code `PreToolUse` hook that intercepts every Bash tool call before it
executes and applies a three-stage safety pipeline:

1. **Deny** — regex patterns in `~/.local/etc/btg.deny` block commands
   immediately (e.g. `curl .* \| bash`).
2. **Allow fast-path** — ERE patterns in `~/.local/etc/btg.allow`, plus
   per-project `Bash(...)` entries in `.claude/settings{,.local}.json`, let safe
   commands through without any AI involvement.
3. **Vibe slow-path** — anything that passes both filters is sent to
   [`vibe`](https://github.com/mistralai/mistral-vibe) for a one-shot LLM judgement.
   The model responds with `safe` or `ask: <reason>`, and the hook returns the
   appropriate Claude Code permission decision.

Commands that escape all three stages produce an `ask` decision — Claude Code
pauses and shows the reason to the user.

## Prerequisites

- Zig 0.15.x
- [`vibe`](https://github.com/mistralai/mistral-vibe) on `$PATH` (slow-path only)
- macOS or Linux

## Building

```sh
zig build
# Binaries land in zig-out/bin/
```

## Installation

Register the hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/zig-out/bin/bash_tool_guard"
          }
        ]
      }
    ]
  }
}
```

### Pattern files

The quickest way to bootstrap pattern files is:

```sh
btg init
```

This creates `~/.local/etc/btg.allow` and `~/.local/etc/btg.deny` with
starter patterns (existing files are left untouched).

Alternatively, create the directories manually:

```sh
mkdir -p ~/.local/etc ~/.local/var
```

**`~/.local/etc/btg.allow`** — ERE patterns, one per line; `#` comments
and blank lines ignored. Each pattern is matched against the full expanded
command (after wrapper stripping).

```
^git\b
^zig\b
^npm\b
```

The escape sequences `\b`, `\s`, `\S`, `\w`, `\W`, `\d`, `\D` are expanded
to portable POSIX ERE equivalents before compilation, so patterns using them
work on both Linux and macOS.

**`~/.local/etc/btg.deny`** — same format; matched against the command
with quotes stripped.

```
curl.*\|.*bash
rm\s+-rf\s+/
```

### Per-project allow lists

`Bash(cmd *)` entries in `.claude/settings.json` or `.claude/settings.local.json`
under `permissions.allow` are loaded automatically when the hook runs from inside
that project. The `btg suggest` command populates these from
your ask history (see below).

## Report tool

`btg` provides several diagnostics and maintenance commands.
Run with no arguments to print all views.

```
btg [ask] [stale-allow] [suggest] [flush] [init] [allow <pat>] [deny <pat>]
```

| Command | Description |
|---------|-------------|
| `ask` | Commands vibe-evaluated most often, not in any allow list. Annotated with `[ask: N]` when some hits were blocked, `[project]` if all occurrences came from one repo. |
| `stale-allow` | Allow patterns in `~/.local/etc/btg.allow` with zero recorded invocations. Safe to remove. |
| `suggest` | Write `Bash(cmd *)` entries for every command seen in the vibe log for the current project into `.claude/settings.local.json`. Idempotent. |
| `flush` | Delete all log files under `~/.local/var/`. |
| `init` | Create `~/.local/etc/btg.allow` and `btg.deny` with starter patterns (skips files that already exist). |
| `allow <pattern>` | Append an ERE pattern to `~/.local/etc/btg.allow`. |
| `deny <pattern>` | Append an ERE pattern to `~/.local/etc/btg.deny`. |

### Example: populate a project allow list

```sh
cd ~/my-project
btg suggest
# Wrote 4 new entries to /home/you/my-project/.claude/settings.local.json:
#   Bash(cargo *)
#   Bash(just *)
#   Bash(make *)
#   Bash(rustfmt *)
```

Run again after adding entries — it reports `No new entries to add.`

## Decision pipeline detail

For each Bash tool call the guard:

1. Splits the command into `;` / `&&` / `||` / `|` segments.
2. Classifies each segment: pure shell structure (if/for/while/fi/done/variable
   assignment) is skipped; real commands proceed.
3. Expands wrapper prefixes (`nohup`, `sudo`, `env`, `timeout`, `xargs`, etc.)
   to surface the real executable.
4. Checks the deny list (full segment, after quote-stripping).
5. Checks allow lists against each expanded segment. If every segment matches,
   the command is fast-pathed and logged to `btg.allow.log.jsonl`.
6. Flag-level analysis runs on commands like `find` (`-exec`, `-delete`) and
   `git push` (`--force`, `--mirror`) to escalate dangerous invocations that
   would otherwise match a broad `^git\b` allow pattern.
7. Commands with `$( )` substitutions or unsafe output redirects (`>`, `>>`)
   skip the allow fast-path entirely.
8. Everything else goes to vibe. Result is logged to `btg.vibe.log.jsonl`
   with `reason` set to `"vibe: safe"` or the ask explanation. If vibe fails
   to spawn or does not respond within 30 seconds, the result is
   `ask: vibe unavailable` — the command failed the allow list and still needs
   review.

## Extending

### Add a new allow pattern

Append a line to `~/.local/etc/btg.allow`:

```
^jq\b
```

Or use the `suggest` command for project-specific commands.

### Add flag-level rules for a new command

Use the `/add-command-flags` Claude Code slash command (`.claude/commands/add-command-flags.md`).

### Add a new wrapper

Use the `/add-wrapper` slash command (`.claude/commands/add-wrapper.md`).

## Logs

All logs live under `~/.local/var/`:

| File | Content |
|------|---------|
| `btg.allow.log.jsonl` | Commands matched by allow list (fast-path) |
| `btg.vibe.log.jsonl` | All vibe-evaluated commands; `reason` is `"vibe: safe"` or the ask explanation |

Each line is a JSON object: `{"cmd":"...","reason":"...","ts":"...","project":"..."}`.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
