# Design: Hooksmith ID-Based Registry & Runner

## Overview

Transform hooksmith from a path-based build system to an id-based registry with runtime resolution. Every hook gets a unique lowercase id, hooks.json references ids instead of inline paths, and a runner script resolves everything at execution time.

## 1. YAML Rule Format — `id` Field

### Format
```yaml
id: bash-safety-guard
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/bash-safety-guard.sh
result: deny
fail_mode: closed
```

### Constraints
- **Required**: build.sh rejects rules without `id`
- **Lowercase**: `[a-z0-9-]` only (validated by build.sh)
- **Unique**: No two rules across user + project scopes can share an id. Project scope overrides user scope by filename, but ids must still be unique across the merged set
- **Convention**: Use descriptive kebab-case names (e.g., `bash-safety-guard`, `auto-format`, `smart-notify`)

## 2. Entry Point — `./hooksmith` + `lib/run.sh`

### Invocation
```
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run <id>
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list [--json]
```

`./hooksmith` is a CLI dispatcher at the plugin root. Each subcommand maps to a script in `lib/`:
```bash
#!/bin/bash
PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  list)    shift; exec bash "${PLUGIN_ROOT}/lib/list.sh" "$@" ;;
  run)     shift; exec bash "${PLUGIN_ROOT}/lib/run.sh" "$@" ;;
  *)       echo "hooksmith: unknown command '${1:-}'" >&2; exit 1 ;;
esac
```

Uses `exec bash` (not `source`) to avoid shell environment pollution and ensure each subcommand controls its own errexit/exit behavior. The `case` dispatcher is extensible — future subcommands (`new`, `enable`, `disable`, `convert`, `build`) slot in as additional cases mapping to `lib/<command>.sh`.

hooks.json uses the explicit form: `hooksmith run <id>`.

### Resolution Flow
```
hooksmith run <id>
  ├── Find rule: .hooksmith/rules/<id>.yaml → ~/.config/hooksmith/rules/<id>.yaml
  │   (id MUST equal filename without .yaml extension — enforced at build time)
  ├── Parse YAML (reuse parse_yaml/get_val via lib/parse.sh)
  ├── Read mechanism, fail_mode, script/field/pattern/prompt
  ├── Dispatch (stderr suppressed, stdout captured):
  │   ├── regex → regex-match.sh <field> <pattern> <message> <result>
  │   ├── script → HOOKLIB=... bash <script-path>
  │   └── prompt → (not used at runtime — prompt is in hooks.json directly)
  └── On success: emit captured stdout
  └── On failure: apply fail_mode (open → exit 0, closed → deny JSON)
```

### Design Choices
- **Project-first lookup**: `.hooksmith/rules/<id>.yaml` checked before `~/.config/hooksmith/rules/<id>.yaml`. This mirrors the override behavior in build.sh.
- **id == filename constraint**: `run.sh` looks up `<id>.yaml` directly rather than scanning all files. Build-time validation enforces that `id` matches the filename without extension.
- **Shared parsing**: Extract `parse_yaml` and `get_val` into a shared file (`lib/parse.sh`) so both `build.sh` and `run.sh` use the same parser.
- **Capture-then-emit stdout model**: Like `fail-wrapper.sh`, `run.sh` captures all stdout via `output=$(...)` and only emits on success. This prevents partial output reaching Claude Code on failure.
- **Stderr suppression**: `run.sh` suppresses stderr from underlying scripts (`2>/dev/null`) matching `fail-wrapper.sh` behavior. Only `run.sh`'s own diagnostic messages go to stderr.
- **fail_mode handling**: `run.sh` handles fail_mode directly instead of delegating to `fail-wrapper.sh`. `fail-wrapper.sh` remains for backward compatibility but is no longer used in generated hooks.
- **Fallback on parse/lookup errors**: If YAML file not found, malformed, or parse fails, default to fail-open (exit 0, stderr warning). There is no rule to read a `fail_mode` from, so open is the safe default.

### Prompt Mechanism — Special Case
Prompt-type rules cannot use `run.sh` because Claude Code expects `{"type":"prompt","prompt":"..."}` in hooks.json, not a command. For prompt rules, `build.sh` continues to emit the prompt JSON directly. Traceability for prompt rules is via `list.sh` and the YAML source files, not via hooks.json (JSON doesn't support comments, and extra fields may not be supported by Claude Code's hook schema).

## 3. List — `lib/list.sh`

### Invocation
```
bash ${CLAUDE_PLUGIN_ROOT}/lib/list.sh [--scope user|project|all] [--json]
```

### Output (default: table)
```
HOOKSMITH RULES
───────────────────────────────────────────────────────────
ID                     EVENT            MECH    RESULT  SCOPE
bash-safety-guard      PreToolUse       script  deny    user
auto-format            PostToolUse      script  warn    user
smart-notify           Notification     script  warn    user
protected-files        PreToolUse       script  warn    user
───────────────────────────────────────────────────────────
19 rules (19 user, 0 project)
```

### Design Choices
- Reads YAML files directly (not hooks.json) — source of truth
- Shows: id, event, matcher (if set), mechanism, result, fail_mode (if non-default), scope (user/project), enabled status
- `--json` flag outputs JSON array for programmatic use
- Disabled rules shown with `[disabled]` marker
- Sorted by event, then id

## 4. Build Changes — `build.sh`

### New Validations
1. **id required**: Error if missing
2. **id format**: Must match `^[a-z0-9-]+$`
3. **id uniqueness**: Error if duplicate ids found across merged rules

### New Command Generation

**Before (current):**
```json
{
  "type": "command",
  "command": "HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh open bash ${HOME}/.claude/hooks/smart-notify.sh",
  "timeout": 10
}
```

**After (new):**
```json
{
  "type": "command",
  "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run smart-notify",
  "timeout": 10
}
```

For prompt rules:
```json
{
  "type": "prompt",
  "prompt": "Review this code change for security issues...",
  "timeout": 10
}
```
(Prompt rules are unchanged in hooks.json — they don't go through run.sh)

### async flag
If the YAML rule has `async: true`, the hook entry still gets `"async": true` in hooks.json. This is a hooks.json-level feature, not something run.sh handles.

## 5. Shared Parser — `lib/parse.sh`

Extract `parse_yaml()` and `get_val()` from `build.sh` into `lib/parse.sh` so both `build.sh` and `run.sh` source the same code. This avoids duplication and ensures parsing consistency.

```bash
# lib/parse.sh
parse_yaml() { ... }  # moved from build.sh
get_val() { ... }      # moved from build.sh
```

Consumers source it relative to their own location:
```bash
source "${SCRIPT_DIR}/lib/parse.sh"  # build.sh (SCRIPT_DIR = plugin root)
source "${SCRIPT_DIR}/parse.sh"      # lib/run.sh, lib/list.sh (SCRIPT_DIR = lib/)
```

## 6. convert.sh Updates

When converting hooks from settings.json, auto-generate the `id` field:
- Derive from the script filename: `~/.claude/hooks/bash-safety-guard.sh` → `id: bash-safety-guard`
- For regex rules without a script: derive from `event-matcher-field` (e.g., `pretooluse-bash-command`)
- Lowercase, strip extension, replace non-alphanumeric with hyphens

## 7. Migration Path

Existing 19 YAML rules in `~/.config/hooksmith/rules/` need `id` added. Options:
1. **Script**: Write a one-liner that adds `id: <filename-without-ext>` to each YAML file
2. **Manual**: Since filenames already match the desired id, it's trivial
3. **Graceful degradation**: build.sh could auto-derive id from filename if missing, with a deprecation warning. This eases migration but goes against the "id is required" decision.

**Recommendation**: Option 1 (scripted migration) + build.sh hard error on missing id. Clean break.

## 8. File Dependency Graph

```
YAML rules (user/project)
    │
    ├── build.sh ──→ hooks.json (references ./hooksmith run <id>)
    │     │
    │     └── sources lib/parse.sh
    │
    ├── run.sh ──→ resolves id → YAML → executes hook
    │     │
    │     ├── sources lib/parse.sh
    │     ├── calls lib/regex-match.sh (for regex rules)
    │     └── calls user scripts (for script rules)
    │
    └── list.sh ──→ reads YAML rules, displays table
          │
          └── sources lib/parse.sh
```
