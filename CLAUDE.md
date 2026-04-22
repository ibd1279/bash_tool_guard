# bash-tool-guard

Claude Code PreToolUse/PostToolUse hooks for Bash command safety gating.

## Quick Commands

```sh
zig build        # Build to zig-out/bin/
zig build test   # Run 235 tests
btg              # Report tool (ask, stale-allow, suggest, flush, init)
```

## Architecture

**Three-stage decision pipeline:**
1. **Deny** - `~/.local/etc/btg.deny` patterns block immediately
2. **Allow** - `~/.local/etc/btg.allow` + per-project `Bash(*)` fast-path (zero AI)
3. **Vibe** - LLM safety check for everything else (`safe` or `ask: <reason>`)

**Key invariants:**
- Deny beats allow
- Wrappers (sudo, timeout, env, nohup) are transparent — inner command is checked
- Shell structure (if/then/fi, for/do/done, variable assignments) is skipped
- Commands with `$(...)` or `>`, `>>` redirects bypass allow fast-path
- Vibe unavailable → `ask: vibe unavailable`

## Adding Rules

```sh
# Add allow pattern
btg allow '^mycmd\b'

# Add deny pattern  
btg deny 'dangerous.*pattern'

# Populate project allow list from history
btg suggest
```

Or use Claude Code slash commands: `/add-command-flags`, `/add-wrapper`

## Log Files

```
~/.local/etc/btg.allow       # Global allow patterns (ERE)
~/.local/etc/btg.deny        # Global deny patterns (ERE)
~/.local/var/btg.allow.log.jsonl   # Fast-path commands
~/.local/var/btg.vibe.log.jsonl    # Vibe-evaluated commands
~/.local/var/btg.post.log.jsonl    # Successfully executed commands
```

## Hook Installation

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/bash_tool_guard"}]}],
    "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/bash_tool_guard"}]}]
  }
}
```
