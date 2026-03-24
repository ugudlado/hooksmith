---
name: hooksmith
description: "This skill should be used when the user asks to 'create a hook rule', 'write a YAML rule', 'add a regex rule', 'add a prompt rule', 'add a script rule', 'block a command', 'deny a tool', 'add a hook', 'configure hook behavior', 'list my hooks', 'show registered hooks', 'hooksmith list', 'hooksmith run', 'hooksmith convert', 'hooksmith build', 'convert hooks to rules', 'migrate hooks', 'import hooks from settings', 'convert settings.json hooks', or is working with hooksmith YAML rule files. Provides the CLI interface, rule file format, result-event compatibility, and examples for all three mechanisms."
---

# Hooksmith

Manage Claude Code hooks declaratively via YAML rules. The `hooksmith` CLI compiles rules to native hooks, lists what's registered, and executes hooks at runtime.

## Creating a Hook — Guided Workflow

When the user asks to create, add, or write a hook rule, follow this flow:

### Step 1: Understand the intent

Read what the user wants to achieve. Extract:
- **What to watch**: which event and tool (e.g. "when Claude runs bash commands", "before writing files")
- **What to check**: the condition (e.g. "if the command contains rm -rf", "if the file is a .env file")
- **What to do**: the action (e.g. "block it", "warn me", "ask for approval")

If the intent is vague, ask one focused question to clarify the condition or action before proceeding.

### Step 2: Recommend a mechanism

Pick the best mechanism based on the intent — don't ask the user to choose:

| Use `regex` when... | Use `prompt` when... | Use `script` when... |
|---------------------|----------------------|----------------------|
| Matching a pattern in a known field (command text, file path, content) | The condition requires judgment or natural language reasoning | Logic is complex, stateful, or needs shell utilities |
| Simple allow/block with no ambiguity | The user wants Claude to evaluate risk | The user already has a `.sh` script |
| Best performance, zero overhead | Acceptable latency (~1-2s), no script needed | Full control over output format |

**Default preference order: regex → prompt → script**. Only use script if regex/prompt genuinely can't express the logic.

Present your recommendation with a brief reason: *"I'll use regex here — the condition is a straightforward pattern match on the command field."*

### Step 3: Draft the rule and show it to the user

Generate the complete YAML and **show it before writing anything**:

```yaml
id: block-rm-rf
event: PreToolUse
matcher: Bash
mechanism: regex
field: command
pattern: 'rm[[:space:]]+-rf'
result: deny
message: "Blocked: rm -rf is not allowed."
```

Explain each field briefly. Ask the user to confirm or request changes:
- *"Does this look right? I can adjust the pattern, change the result to `ask` instead of `deny`, or make it project-scope instead of user-scope."*

Wait for explicit confirmation before proceeding.

### Step 4: Write, build, and confirm

Once the user approves:

1. **Write** the rule file — filename must match `id`:
   ```
   ~/.config/hooksmith/rules/<id>.yaml     # user scope (default)
   .hooksmith/rules/<id>.yaml              # project scope
   ```

2. **Build** immediately:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooksmith build
   ```

3. **Confirm** with `hooksmith list` — show the user their hook in the registry:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list
   ```

4. **Tell the user**: *"Done. The `<id>` hook is registered and will be active from the next session."*

## CLI Commands

```bash
hooksmith list [--json] [--scope user|project|all]   # Show registered hooks
hooksmith run <id>                                    # Execute hook by id
hooksmith convert [--apply] [--scope user|project]   # Migrate settings.json hooks to YAML
hooksmith build                                       # Rebuild hooks.json from YAML rules
```

All commands are invoked via `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith <command>`.

### hooksmith list

Show all registered hook rules:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list --scope user
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list --scope project
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list --json
```

Output columns: ID, EVENT, MATCHER, MECH, RESULT, SCOPE. Disabled rules show `[disabled]`.

### hooksmith convert

Migrate hooks from `settings.json` into YAML rule files:

```bash
# Preview (dry-run, default)
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith convert

# Write YAML files
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith convert --apply

# Convert project-level hooks
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith convert --scope project --apply
```

The converter auto-detects mechanism, infers result type from script output patterns, preserves `timeout`/`async`, won't overwrite existing files, and adds an `id` field derived from the script filename.

**Automatically skipped:** plugin hooks (`${CLAUDE_PLUGIN_ROOT}`), `type: http`/`agent`, scripts using `updatedInput`.

After converting: verify the rules, run `hooksmith build`, then remove converted entries from `settings.json`.

### hooksmith build

Rebuild `hooks.json` from all YAML rules:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/hooksmith build
```

Build validates every rule (required fields, event names, mechanism constraints, id format, id-filename match, uniqueness) and errors clearly on violations.

## Overview

Rules live in `~/.config/hooksmith/rules/` (user-level) or `.hooksmith/rules/` (project-level). Each rule is one YAML file. Project rules override user rules with the same filename.

Run `hooksmith build` after adding, removing, or restructuring rules. The build updates `hooks.json` — changes take effect on the **next** session.

## Rule Format

Every rule requires an `id` matching the filename (without `.yaml`):

```yaml
id: bash-safety-guard       # must match filename bash-safety-guard.yaml
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/bash-safety-guard.sh
result: deny
fail_mode: closed
```

## Rule Mechanisms

Each rule uses exactly one mechanism.

### regex — Pattern matching

Tests a JSON field against a regex. No script needed.

```yaml
id: block-rm
event: PreToolUse
matcher: Bash
mechanism: regex
field: command
pattern: 'rm[[:space:]]+-rf[[:space:]]+(/|~|\$HOME)'
result: deny
message: "Blocked: destructive rm targeting system or home directory."
```

Required: `field`, `pattern` | Forbidden: `script`, `prompt`

Supported `field` values by event:

| Event | Available fields |
|-------|-----------------|
| `PreToolUse` / `PostToolUse` (Bash) | `command` |
| `PreToolUse` / `PostToolUse` (Write, Edit) | `file_path`, `content` |
| `PreToolUse` / `PostToolUse` (Read) | `file_path` |
| `PreToolUse` / `PostToolUse` (any tool) | `tool_name` |
| `UserPromptSubmit` | `user_prompt` |
| All events | `cwd` |

### script — Custom bash logic

Runs a user script. Script receives hook JSON on stdin, sources `$HOOKLIB` for helpers.

```yaml
id: process-kill-guard
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/process-kill-guard.sh
result: deny
fail_mode: closed
```

Required: `script` | Forbidden: `field`, `pattern`, `prompt`

### prompt — LLM evaluation

Embeds a prompt in `hooks.json` for native Claude Code evaluation. Zero script overhead.

```yaml
id: security-review
event: PreToolUse
matcher: Bash
mechanism: prompt
result: deny
prompt: |
  Review this bash command: $TOOL_INPUT
  If it could delete files or expose secrets, respond with:
  {"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "<reason>"}}
  Otherwise respond with: {}
```

Required: `prompt` | Forbidden: `script`, `field`, `pattern`

Available variables: `$ARGUMENTS`, `$TOOL_INPUT`, `$TOOL_RESULT` (PostToolUse), `$USER_PROMPT` (UserPromptSubmit).

## Field Reference

| Field       | Required    | Default | Description |
|-------------|-------------|---------|-------------|
| `id`        | Always      | —       | Unique id — lowercase kebab-case, must match filename |
| `event`     | Always      | —       | Hook event name |
| `mechanism` | Always      | —       | `regex`, `script`, or `prompt` |
| `result`    | Always      | —       | `deny`, `ask`, `warn`, or `context` |
| `matcher`   | No          | (none)  | Tool/type filter |
| `field`     | regex only  | —       | JSON field to match (`command`, `file_path`, `content`, `user_prompt`, `tool_name`, `cwd`) |
| `pattern`   | regex only  | —       | Extended regex (POSIX, not PCRE — use `[[:space:]]` not `\s`) |
| `script`    | script only | —       | Path to bash script (`~/` or absolute) |
| `prompt`    | prompt only | —       | LLM prompt text |
| `message`   | No          | Auto    | Output message |
| `fail_mode` | No          | `open`  | `open` (errors allow) or `closed` (errors deny) |
| `enabled`   | No          | `true`  | Set `false` to exclude from build |
| `timeout`   | No          | `10`    | Seconds |
| `async`     | No          | `false` | Background execution (command hooks only) |

## Result-Event Compatibility

| Result  | PreToolUse | PostToolUse | Stop | UserPromptSubmit | SubagentStop | Others |
|---------|-----------|------------|------|-----------------|-------------|--------|
| deny    | Yes       | Yes        | Yes  | Yes             | Yes         | No     |
| ask     | Yes       | No         | No   | No              | No          | No     |
| warn    | Yes       | Yes        | Yes  | Yes             | Yes         | Yes    |
| context | Yes       | Yes        | Yes  | Yes             | Yes         | Yes    |

## Hooklib Helpers (script rules)

```bash
source "$HOOKLIB"
read_input                    # Read stdin JSON into $INPUT
get_field <name>              # Extract field from input
deny "reason"                 # Block with message
ask "reason"                  # Request user approval
warn "message"                # Inject system message warning
context "text"                # Inject context for Claude
block_stop "reason"           # Block a Stop event
log "message"                 # Debug to stderr
```

## Supported Events

| Event | Prompt | Description |
|-------|--------|-------------|
| `PreToolUse` | Yes | Before tool execution |
| `PostToolUse` | Yes | After successful tool execution |
| `Stop` | Yes | Before Claude stops responding |
| `UserPromptSubmit` | Yes | When user sends a message |
| `SubagentStop` | Yes | When a subagent completes |
| `SessionStart` | No | New session begins |
| `SessionEnd` | No | Session terminates |
| `PostCompact` | No | After context compaction |
| `Notification` | Yes | On notifications |
| `WorktreeCreate` | No | Creating a worktree |
| `WorktreeRemove` | No | Removing a worktree |

Full event list in `references/field-reference.md`.

## Additional Resources

- **`references/field-reference.md`** — Complete field docs, pattern syntax, advanced patterns
- **`examples/`** — Working examples for each mechanism
