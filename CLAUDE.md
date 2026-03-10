# bash-tool-guard — development guide

## Build and test

```sh
zig build
zig build test
```

Binaries land in `zig-out/bin/`. No external dependencies except `libc` (linked
via `build.zig`) and the `yazap` argument-parsing package (fetched by the build
system).

## Source layout

| File | Role |
|------|------|
| `src/main.zig` | PreToolUse hook entry point. Reads stdin JSON, runs the pipeline, writes Claude Code output. |
| `src/post_tool.zig` | PostToolUse hook entry point. Logs clean executed commands to `btg.post.log.jsonl`. |
| `src/pipeline.zig` | Three-stage deny/allow/vibe engine (`evaluate`) + PostToolUse classifier (`classifyForPost`). |
| `src/settings.zig` | Shared helpers: `bashPatternToEre`, `loadClaudeAllowPats` — used by both hook binaries. |
| `src/guard.zig` | Command parsing: segment splitting, quote stripping, wrapper expansion, redirect/substitution detection, heredoc stripping. |
| `src/flags.zig` | Per-command flag rules (`find -exec`, `git push --force`, …). Add new rules here or use `/add-command-flags`. |
| `src/patterns.zig` | ERE pattern loading and matching via POSIX `regexec`. |
| `src/vibe.zig` | Slow-path: spawns `vibe -p <prompt>` and parses its one-line response. |
| `src/log.zig` | JSONL append logging to `~/.local/var/btg.*.log.jsonl`. |
| `src/output.zig` | Writes the Claude Code `hookSpecificOutput` JSON to stdout. |
| `src/project.zig` | `findProjectRoot`: walks up from CWD looking for `.git`, stays under `$HOME`. |
| `src/report.zig` | `btg` binary: `ask`, `stale-allow`, `suggest`, `flush` views. |
| `src/process_info.zig` | Reads `/proc/self/status` (Linux) or `sysctl` (macOS) for parent process info. |
| `src/tests.zig` | Test root — imports all modules so their `test` blocks are compiled. |

## Key invariants

- **Zero AI on the fast path.** If every command segment matches the allow list,
  the hook exits immediately with `allow` and logs to `btg.allow.log.jsonl`.
  Vibe is never spawned.
- **Deny before allow.** The deny list is checked first; a deny match exits
  immediately regardless of allow patterns.
- **Wrappers are transparent.** `sudo zig build`, `nohup npm start`, and
  `env FOO=1 cargo test` all bucket the real executable, not the wrapper.
- **Shell structure is skipped.** `if`/`then`/`fi`, `for`/`do`/`done`,
  variable assignments like `FOO=bar`, and test builtins (`[`, `[[`, `test`)
  are never matched against allow patterns.
- **Substitution and unsafe redirects bypass the allow fast-path.** Commands
  with `$(...)`, backticks, or output redirects (`>`, `>>`) go straight to vibe.
- **Vibe fails to ask.** If `vibe` fails to spawn or times out (30 s), the
  result is `ask: vibe unavailable` — the command already failed the allow list
  and still needs review.

## Decision flow

```
stdin JSON
  │
  ├─ deny list hit?  ──yes──> deny + exit
  │
  ├─ all segments in allow list AND no substitution AND no unsafe redirect?
  │    └─ flag-level escalation check (find -exec, git push --force, …)
  │         ├─ escalated ──────────────────────────────────────────> ask
  │         └─ clean ──────────────────────────────────────────────> allow_fast
  │
  └─ vibe slow path
       ├─ "safe" ──────────────────────────────────────────────────> allow_vibe
       └─ "ask: <reason>" ─────────────────────────────────────────> ask
```

## Adding flag rules

Use the `/add-command-flags` slash command.  It edits `src/flags.zig` and adds
a new `CmdDef` entry (or a subcommand entry to an existing one) following the
established pattern.

## Adding wrapper support

Use the `/add-wrapper` slash command. It edits the wrapper table in
`src/guard.zig`.

## Log format

Every log entry is a single-line JSON object:

```json
{"cmd":"zig build test","reason":"vibe: safe","ts":"2025-01-15T10:30:00Z","project":"/home/you/my-project"}
```

The `project` field is omitted for entries logged before project detection was
added.

## report tool

`btg` shares `src/project.zig` and `src/guard.zig` with the
hook but has its own `main()` in `src/report.zig`. Run with no arguments for all
views; pass one or more selector words (`ask`, `stale-allow`, `suggest`, `flush`,
`init`, `allow <pattern>`, `deny <pattern>`) to run specific views.

The `suggest` command reads `btg.post.log.jsonl` (commands that executed
successfully and have no red flags) and writes `Bash(cmd *)` entries to
`.claude/settings.local.json` in the current project, merging with any that
already exist.

## Pattern file locations

```
~/.local/etc/btg.allow    # global allow patterns (ERE, one per line)
~/.local/etc/btg.deny     # global deny patterns  (ERE, one per line)
~/.local/var/btg.allow.log.jsonl
~/.local/var/btg.vibe.log.jsonl
~/.local/var/btg.post.log.jsonl
```
