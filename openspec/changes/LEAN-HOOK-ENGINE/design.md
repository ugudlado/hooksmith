# Design: Lean Hook Engine v2

## Context

Claude Code hooks are registered in a static `hooks.json` loaded at session start. The previous design used per-event dispatcher scripts that loaded rule files at runtime -- essentially reimplementing hookify in bash. This design takes a fundamentally different approach: a build step that compiles YAML rules directly into native hooks.json entries. No middleware. Each rule IS a hook.

### Key Insight

The previous design treated `"type": "prompt"` as impossible for dynamic rules because hooks.json is static. But if we accept a build step, the prompt text IS in hooks.json before session start. We get true native prompt hooks for free.

## Goals / Non-Goals

### Goals

- Each rule maps 1:1 to a native hooks.json entry
- True `"type": "prompt"` support for LLM-evaluated rules
- Build-time validation catches errors before session start
- hooklib.sh for script authors
- Under 200 lines of bash for the entire engine

### Non-Goals

- Dynamic rule reload without restart
- Condition combinators (AND/OR) -- use script mechanism
- Multi-event rules -- use two YAML files
- GUI for rule management

## Selected Approach: Build-Step Compilation

Evaluated three approaches. Selected the build-step model for its simplicity and native hook support.

| Approach | Native prompt? | Dynamic reload? | Complexity | Verdict |
|----------|---------------|-----------------|------------|---------|
| Runtime dispatcher | No (faked via systemMessage) | Yes | High (~400 LOC dispatch engine) | Rejected |
| Build step | Yes | No (rebuild + restart) | Low (~150 LOC build script) | Selected |
| Hybrid (auto-rebuild on SessionStart) | Partially (stale by one session) | Sort of | Medium | Rejected (dishonest about timing) |

## File Layout

```
lean-hook-engine/                    # Plugin repo
  .claude-plugin/
    plugin.json                      # Plugin manifest
  hooks/
    hooks.json                       # GENERATED -- do not hand-edit
  lib/
    hooklib.sh                       # Shared helpers for script rules
    regex-match.sh                   # Generic regex matcher for regex rules
    fail-wrapper.sh                  # Wraps scripts to handle fail_mode
  build.sh                           # The build script
  commands/
    lean-hooks.md                    # /lean-hooks command (build, list)

~/.claude/hooks/rules/               # User-level (global) rules
  block-rm.yaml                      # Applies to all projects
  warn-sensitive-paths.yaml
  review-security.yaml

<project-root>/.claude/hooks/rules/  # Project-level rules
  worktree-boundary.yaml             # Only for this project
  task-gate.yaml
```

## Rule File Format

Plain YAML. One file per rule.

### Minimal example (regex)

```yaml
# ~/.claude/hooks/rules/block-rm.yaml
event: PreToolUse
matcher: Bash
mechanism: regex
field: command
pattern: 'rm\s+-rf\s+(/|~|\$HOME)'
result: deny
message: "Blocked: destructive rm targeting system or home directory."
```

### Script example

```yaml
# ~/.claude/hooks/rules/process-kill-guard.yaml
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/process-kill-guard.sh
result: deny
fail_mode: closed
```

### Prompt example

```yaml
# ~/.claude/hooks/rules/security-review.yaml
event: PreToolUse
matcher: Bash
mechanism: prompt
result: deny
prompt: |
  You are a security reviewer. Examine this bash command: $TOOL_INPUT
  If the command could delete important files, expose secrets, or modify
  system configuration, respond with: {"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "Security concern: <reason>"}}
  Otherwise respond with: {}
```

### All fields

| Field       | Required | Default | Description |
|-------------|----------|---------|-------------|
| `event`     | Yes      | --      | Hook event name |
| `mechanism` | Yes      | --      | `regex`, `script`, or `prompt` |
| `result`    | Yes      | --      | `deny`, `ask`, `warn`, or `context` |
| `matcher`   | No       | (none)  | Tool name filter for PreToolUse/PostToolUse |
| `field`     | regex    | --      | JSON field to match: `command`, `file_path`, `content`, etc. |
| `pattern`   | regex    | --      | Extended regex (bash `=~` syntax) |
| `script`    | script   | --      | Path to bash script (absolute or `~/` prefix) |
| `prompt`    | prompt   | --      | Prompt text for LLM evaluation |
| `message`   | regex    | --      | Message text for deny/ask/warn/context output |
| `fail_mode` | No       | `open`  | `open` (errors allow) or `closed` (errors deny) |
| `enabled`   | No       | `true`  | `false` to exclude from build |
| `timeout`   | No       | `10`    | Hook timeout in seconds |

## Build Script: How It Works

`build.sh` is approximately 120 lines of bash. It does four things:

### 1. Read rules

```bash
RULES_DIR="${RULES_DIR:-$HOME/.claude/hooks/rules}"
for rule_file in "$RULES_DIR"/*.yaml; do
  # Parse with awk (no yq dependency -- simple key: value parsing)
  ...
done
```

The build step reads from both scopes and merges:

```bash
USER_RULES_DIR="${USER_RULES_DIR:-$HOME/.claude/hooks/rules}"
PROJECT_RULES_DIR="${PROJECT_RULES_DIR:-.claude/hooks/rules}"

# User rules first, then project rules override by filename
declare -A rules_map
for rule_file in "$USER_RULES_DIR"/*.yaml 2>/dev/null; do
  name=$(basename "$rule_file")
  rules_map["$name"]="$rule_file"
done
for rule_file in "$PROJECT_RULES_DIR"/*.yaml 2>/dev/null; do
  name=$(basename "$rule_file")
  rules_map["$name"]="$rule_file"  # overrides user-level
done
```

Project rules with the same filename as a user rule **replace** the user rule entirely (not merge fields). This lets projects disable a global rule by creating a file with `enabled: false`.

YAML parsing is deliberately minimal. Rules use flat key-value pairs only (no nesting, no arrays). A 15-line awk script handles this:

```bash
parse_yaml() {
  awk -F': ' '
    /^#/ { next }
    /^[a-z_]+:/ {
      key = $1
      val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
      # Strip quotes
      gsub(/^["'"'"']|["'"'"']$/, "", val)
      print key "=" val
    }
  ' "$1"
}
```

For multi-line fields (`prompt: |`), a slightly extended parser reads continuation lines.

### 2. Validate

For each rule, check:
- Required fields present (`event`, `mechanism`, `result`)
- Mechanism-specific fields present (`field`+`pattern` for regex, `script` for script, `prompt` for prompt)
- Result-event compatibility (deny only on PreToolUse/Stop, ask only on PreToolUse, etc.)
- **Mutual exclusivity**: exactly one mechanism's fields present. `regex` requires `field`+`pattern` (no `script`/`prompt`). `script` requires `script` (no `pattern`/`prompt`). `prompt` requires `prompt` (no `script`/`pattern`). Conflicting fields = error.
- Script file exists (for script mechanism)
- Prompt-type only on events that support it (PreToolUse, Stop, UserPromptSubmit, SubagentStop)
- Regex pattern compiles (test with `[[ "" =~ $pattern ]]` in a subshell)

Validation errors are printed to stderr. Invalid rules are skipped (not fatal).

### 3. Generate hooks.json

The build script writes a JSON file. For each valid rule, it generates the appropriate entry:

**Regex rule** generates:

```json
{
  "type": "command",
  "command": "bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh open bash ${CLAUDE_PLUGIN_ROOT}/lib/regex-match.sh command 'rm\\s+-rf' 'Blocked: destructive rm'",
  "timeout": 10
}
```

**Script rule** generates:

```json
{
  "type": "command",
  "command": "HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh closed bash /Users/spidey/.claude/hooks/process-kill-guard.sh",
  "timeout": 10
}
```

**Prompt rule** generates:

```json
{
  "type": "prompt",
  "prompt": "You are a security reviewer. Examine this bash command: $TOOL_INPUT ...",
  "timeout": 30
}
```

Rules are grouped by event and matcher. Multiple rules for the same event+matcher appear as multiple entries in the `hooks` array.

### 4. Write output

```bash
# Write to plugin's hooks directory
OUTPUT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")}/hooks/hooks.json"
echo "$json" | jq '.' > "$OUTPUT"
echo "Generated $OUTPUT with $count rules"
```

## Component Details

### regex-match.sh (~20 lines)

The generic regex matcher. Receives field name, pattern, and message as arguments. Reads hook JSON from stdin, extracts the field, tests the pattern.

```bash
#!/bin/bash
set -euo pipefail
FIELD="$1"
PATTERN="$2"
MESSAGE="${3:-Blocked by regex rule}"
RESULT="${4:-deny}"

INPUT=$(cat)
VALUE=$(echo "$INPUT" | jq -r ".tool_input.$FIELD // .$FIELD // empty")

if [[ "$VALUE" =~ $PATTERN ]]; then
  case "$RESULT" in
    deny)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    ask)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}' ;;
    warn)
      jq -n --arg m "$MESSAGE" '{systemMessage:$m}' ;;
    context)
      jq -n --arg c "$MESSAGE" '{hookSpecificOutput:{additionalContext:$c}}' ;;
  esac
fi
exit 0
```

No framework. No rule loading. Just: extract, match, output.

### fail-wrapper.sh (~15 lines)

Wraps any command to handle `fail_mode`:

```bash
#!/bin/bash
FAIL_MODE="$1"; shift

if output=$("$@" 2>/dev/null); then
  [[ -n "$output" ]] && echo "$output"
else
  if [[ "$FAIL_MODE" == "closed" ]]; then
    jq -n '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:"Hook script failed (fail_mode: closed)"}}'
  fi
  # fail_mode: open -- exit 0 silently
fi
exit 0
```

### hooklib.sh (~60 lines)

Same API as before, but simpler -- no dispatch awareness needed:

```bash
#!/bin/bash
# Source this in script rules: source "$HOOKLIB"

deny() {
  jq -n --arg r "${1:-Blocked by hook rule}" \
    '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

ask() {
  jq -n --arg r "${1:-Manual approval required}" \
    '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

warn() {
  jq -n --arg m "${1:-Warning from hook rule}" '{systemMessage:$m}'
  exit 0
}

context() {
  jq -n --arg c "$1" '{hookSpecificOutput:{additionalContext:$c}}'
  exit 0
}

block_stop() {
  jq -n --arg r "${1:-Blocked}" '{decision:"block",reason:$r}'
  exit 0
}

read_input() { INPUT=$(cat); export INPUT; }

get_field() {
  local field="$1" json="${INPUT:-$(cat)}"
  case "$field" in
    command)     echo "$json" | jq -r '.tool_input.command // empty' ;;
    file_path)   echo "$json" | jq -r '.tool_input.file_path // empty' ;;
    content)     echo "$json" | jq -r '.tool_input.content // .tool_input.new_string // empty' ;;
    user_prompt) echo "$json" | jq -r '.user_prompt // empty' ;;
    tool_name)   echo "$json" | jq -r '.tool_name // empty' ;;
    cwd)         echo "$json" | jq -r '.cwd // empty' ;;
    *)           echo "$json" | jq -r ".tool_input.$field // .$field // empty" ;;
  esac
}

log() { echo "[lean-hook-engine] $*" >&2; }
```

### Generated hooks.json structure

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh open bash ${CLAUDE_PLUGIN_ROOT}/lib/regex-match.sh command 'rm\\s+-rf\\s+(/|~|\\$HOME)' 'Blocked: destructive rm' deny",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh closed bash ~/.claude/hooks/process-kill-guard.sh",
            "timeout": 10
          },
          {
            "type": "prompt",
            "prompt": "You are a security reviewer. Examine: $TOOL_INPUT. If dangerous, deny.",
            "timeout": 30
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh open bash ${CLAUDE_PLUGIN_ROOT}/lib/regex-match.sh file_path '\\.(env|ssh|pem)$' 'Protected file' deny",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ~/.claude/hooks/session-git-status.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Data Flow

### Regex rule invocation

```
Claude Code triggers PreToolUse(Bash, "rm -rf /tmp")
  |
  v
hooks.json entry: type=command, command="bash .../fail-wrapper.sh open bash .../regex-match.sh command 'rm\s+-rf' 'Blocked' deny"
  |
  v
fail-wrapper.sh runs regex-match.sh with args
  |
  v
regex-match.sh: reads stdin, extracts .tool_input.command, tests =~ pattern
  |
  +-- match: outputs {"hookSpecificOutput":{"permissionDecision":"deny",...}}
  +-- no match: exits 0 silently
  |
  v
Claude Code blocks the command
```

### Prompt rule invocation

```
Claude Code triggers PreToolUse(Bash, "curl ... | sh")
  |
  v
hooks.json entry: type=prompt, prompt="Review this command: $TOOL_INPUT ..."
  |
  v
Claude Code substitutes $TOOL_INPUT and sends to LLM
  |
  v
LLM evaluates and returns deny/allow JSON
  |
  v
Claude Code processes the LLM's decision natively
```

No bash script runs at all for prompt rules. Zero overhead.

### Script rule invocation

```
Claude Code triggers PreToolUse(Bash, "kill -9 1234")
  |
  v
hooks.json entry: type=command, HOOKLIB=.../hooklib.sh bash .../fail-wrapper.sh closed bash ~/hooks/process-kill-guard.sh
  |
  v
fail-wrapper.sh runs process-kill-guard.sh
  |
  +-- script sources $HOOKLIB, calls deny() or exits 0
  +-- if script crashes: fail_mode=closed -> deny; fail_mode=open -> allow
  |
  v
Claude Code processes the result
```

## Build Script: hooks.json Generation Logic

The build script groups rules by `(event, matcher)` pairs. Rules with the same event and matcher go into the same hooks.json matcher group. Rules are sorted alphabetically within each group.

```
For each rule file (sorted alphabetically):
  1. Parse YAML
  2. Skip if enabled: false
  3. Validate fields
  4. Compute group key = event + "|" + matcher
  5. Append to group's hooks array

For each group:
  1. Create hooks.json entry with matcher (if present)
  2. Write hooks array in order
```

This means:
- `block-rm.yaml` (PreToolUse, Bash, regex) and `kill-guard.yaml` (PreToolUse, Bash, script) share a matcher group
- `protected-files.yaml` (PreToolUse, Write|Edit, regex) is in a separate matcher group
- `session-git-status.yaml` (SessionStart, no matcher, script) is in its own event group

## hooklib.sh Discovery Problem

When a script-type rule does `source "$HOOKLIB"`, it needs to find hooklib.sh. The plugin is installed at `~/.claude/plugins/cache/<hash>/lean-hook-engine/`. The user's script has no way to know this path.

**Solution**: The generated hooks.json `command` field sets `HOOKLIB` as an environment variable:

```json
"command": "HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh ..."
```

`${CLAUDE_PLUGIN_ROOT}` is resolved by Claude Code at hook load time. The script simply does `source "$HOOKLIB"`.

## Error Handling

All errors are caught at build time or fail-safe at runtime:

| Error | When | Behavior |
|-------|------|----------|
| Missing required YAML field | Build | Skip rule, print error |
| Invalid result-event combo | Build | Skip rule, print error |
| Script file not found | Build | Skip rule, print error |
| Regex doesn't compile | Build | Skip rule, print error |
| Script crashes at runtime | Runtime | fail_mode: open -> allow, closed -> deny |
| jq missing at runtime | Runtime | Script fails, fail-wrapper catches it |
| No rules directory | Build | Print warning, generate empty hooks.json |

## Migration Path

### Phase 1: Regex hooks (direct YAML conversion)

| Existing script | New YAML rule | Lines saved |
|----------------|---------------|-------------|
| bash-safety-guard.sh (git patterns) | `git-safety.yaml` | ~15 -> 7 |
| bash-safety-guard.sh (system cmds) | `system-safety.yaml` | ~10 -> 7 |
| bash-safety-guard.sh (curl pipe) | `pipe-safety.yaml` | ~5 -> 7 |
| protected-files.sh | `protected-files.yaml` | ~30 -> 7 |

Note: bash-safety-guard.sh contains multiple patterns with different results (deny vs warn). Each becomes a separate YAML rule. The combined YAML is more lines than the monolith, but each rule is independently manageable, testable, and disablable.

### Phase 2: Script hooks (wrap existing scripts)

| Existing script | New YAML rule |
|----------------|---------------|
| process-kill-guard.sh | `process-kill-guard.yaml` (mechanism: script) |
| worktree-boundary.sh | `worktree-boundary.yaml` (mechanism: script) |
| task-gate.sh | `task-gate.yaml` (mechanism: script) |
| session-git-status.sh | `session-git-status.yaml` (mechanism: script) |
| loop-detector.sh | `loop-detector.yaml` (mechanism: script) |

These scripts stay as-is. The YAML rule provides metadata and the build step wires them into hooks.json.

### Phase 3: Prompt hooks (new capability)

| Use case | New YAML rule |
|----------|---------------|
| Security review for bash commands | `security-review.yaml` (mechanism: prompt) |
| Post-compact task reminders | `post-compact-reminders.yaml` (mechanism: prompt) |

These replace hand-written context injection scripts with native LLM evaluation.

## Constraints

- **jq required**: Only external dependency.
- **bash 3.2 compatible**: Avoids associative arrays. Uses indexed arrays and simple string operations.
- **`${CLAUDE_PLUGIN_ROOT}` variable**: Assumed to be resolved by Claude Code when loading hooks.json. [ASSUMPTION: Confirmed by Claude Code plugin docs.]
- **Rules directory outside plugin**: Rules live in `~/.claude/hooks/rules/`, not inside the plugin cache (which is ephemeral and managed by Claude Code).

## Trade-offs

1. **No dynamic reload**: Rules require rebuild + restart. Accepted because: (a) rules change infrequently, (b) enables native prompt hooks, (c) eliminates runtime parsing overhead entirely.
2. **One rule per file**: Cannot combine deny+warn patterns in one file. Accepted for single-responsibility clarity. The bash-safety-guard monolith splits into ~6 small YAML files.
3. **No cross-rule aggregation**: If two regex rules both deny on the same event, both run independently. Claude Code handles the aggregation natively (deny wins). This is simpler than the previous design's manual priority system.
4. **YAML parsing is minimal**: No support for nested structures or arrays. Rules are flat key-value pairs. Complex logic belongs in script-type rules, not in YAML configuration.

## Open Questions

1. **Does `${CLAUDE_PLUGIN_ROOT}` work in the `command` field of hooks.json?** The Claude Code plugin documentation suggests it does. If not, the build script must resolve the absolute path at build time instead. [ASSUMPTION: It works.]
2. **Can multiple hooks in the same matcher group have different types (command + prompt)?** The hooks.json schema shows a `hooks` array -- we assume mixed types are allowed. If not, prompt rules need their own matcher group.
