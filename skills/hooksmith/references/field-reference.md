# Complete Field Reference

## Required Fields

### `name`

Every rule must have a unique name. It serves as the hook's stable identifier in the map index and `hooksmith list` output.

```yaml
rules:
  - name: bash-safety-guard   # lowercase kebab-case
```

**Rules:**
- Format: lowercase letters, digits, and hyphens
- Must be unique across all rules (user + project scopes combined)
- Convention: descriptive kebab-case — `auto-format`, `process-kill-guard`, `spec-adherence-check`

### `on`

Specifies the event and optional tool matcher:

```yaml
on: PreToolUse Bash           # Event + tool matcher
on: PreToolUse Write|Edit     # Alternation in matcher
on: Stop                      # Event only (no matcher)
on: UserPromptSubmit          # Event only
```

- **Event** (required): must match `hook_event_name` exactly
- **Tool matcher** (optional): regex tested against `tool_name`

---

## Event Types

| Event | Description | Common use |
|-------|-------------|------------|
| `PreToolUse` | Before a tool executes | Block dangerous commands, require approval |
| `PostToolUse` | After a tool completes | Auto-format, track processes, inject warnings |
| `PostToolUseFailure` | After a tool fails | Error analysis, retry guidance |
| `PermissionRequest` | When a permission check occurs | Custom permission logic |
| `Stop` | Before Claude stops responding | Block premature stops, enforce checklists |
| `StopFailure` | Stop was blocked and failed | Retry or escalate |
| `UserPromptSubmit` | User submits a message | Inject context, workflow routing |
| `SessionStart` | Session begins | Git status, environment setup |
| `SessionEnd` | Session ends | Reflection, cleanup |
| `SubagentStart` | Subagent spawned | Inject spec context for subagents |
| `SubagentStop` | Subagent about to finish | Review subagent output |
| `TeammateIdle` | Teammate has no work | Reassign or notify |
| `TaskCompleted` | A task finishes | Logging, next-step triggers |
| `Notification` | Notification fired | macOS alerts, logging |
| `PreCompact` | Before context compaction | Save critical state |
| `PostCompact` | After context compaction | Re-inject reminders |
| `ConfigChange` | Settings changed | Validation, sync |
| `InstructionsLoaded` | CLAUDE.md loaded | Augment instructions |
| `WorktreeCreate` | Git worktree created | Setup worktree context |
| `WorktreeRemove` | Git worktree removed | Cleanup |
| `Elicitation` | Elicitation requested | Custom elicitation logic |
| `ElicitationResult` | Elicitation completed | Process elicitation results |

---

## Tool Matcher

The tool matcher (second part of `on`) filters which tools trigger PreToolUse/PostToolUse hooks. Without a matcher, the hook runs for all tools.

```yaml
on: PreToolUse Bash              # Only Bash commands
on: PreToolUse Write|Edit        # Write or Edit operations
on: PostToolUse Bash             # After Bash completes
```

Common tool names: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `WebFetch`, `WebSearch`

---

## Mechanism Fields (pick one)

### `match` — Pattern matching

```yaml
match: command =~ rm[[:space:]]+-rf
```

Syntax: `<field> =~ <pattern>` using POSIX ERE (bash `=~` operator).

### `run` — Custom bash logic

Inline script or external file path:

```yaml
run: |
  source "$HOOKLIB"
  read_input
  cmd=$(get_field command)
  [[ "$cmd" =~ ^sudo ]] && echo "Root access not allowed"

run: ~/.config/hooksmith/scripts/bash-safety-guard.sh
```

### `prompt` — LLM-evaluated rules

```yaml
prompt: "Review this command for security risks."
```

---

## Match Field Values

The field name in `match` rules determines which JSON value to test:

| Field value | Extracts from | Use case |
|-------------|---------------|----------|
| `command` | `.tool_input.command` | Bash command text |
| `file_path` | `.tool_input.file_path` | File being read/written/edited |
| `content` | `.tool_input.content` or `.tool_input.new_string` | Content being written |
| `user_prompt` | `.user_prompt` | User's message (UserPromptSubmit) |
| `tool_name` | `.tool_name` | Name of the tool |
| `cwd` | `.cwd` | Current working directory |
| `<custom>` | `.tool_input.<custom>` then `.<custom>` | Any other field |

---

## Action Fields (pick one)

| Action | Effect | Compatible events |
|--------|--------|-------------------|
| `deny: "<reason>"` | Block the tool use | PreToolUse, PostToolUse, Stop, UserPromptSubmit, SubagentStop |
| `deny: true` | Block; script stdout becomes the reason | For `run` rules |
| `ask: "<reason>"` | Prompt user for approval | PreToolUse only |
| `ask: true` | Ask; script stdout becomes the reason | For `run` rules |
| `context: "<text>"` | Inject additional context for Claude | All events |
| `context: true` | Inject; script stdout becomes context | For `run` rules |

---

## Pattern Syntax (POSIX ERE)

Use POSIX character classes — bash does not support PCRE shortcuts like `\s` or `\d`:

```yaml
# Character classes
match: command =~ rm[[:space:]]+-rf              # whitespace
match: file_path =~ \.(env|pem|key)$             # alternation + anchor
match: command =~ ^(sudo|su)[[:space:]]+          # start anchor

# Quantifiers
match: command =~ DROP[[:space:]]+TABLE           # one or more whitespace
match: command =~ password[=:].*                  # any characters after

# Special characters — single-quote the pattern in YAML
match: command =~ curl.*\|[[:space:]]*sh          # pipe to shell
match: command =~ chmod[[:space:]]+777            # numeric permissions
```

---

## Optional Fields

| Field     | Default | Description |
|-----------|---------|-------------|
| `enabled` | `true`  | Set `false` to disable without removing |

---

## Advanced Patterns

### Disable a global rule per-project

Create a project rule file with the same name and `enabled: false`:

```yaml
# .hooksmith/rules/bash-safety-guard.yaml
# Overrides ~/.config/hooksmith/rules/bash-safety-guard.yaml
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    match: command =~ unused
    deny: "unused"
    enabled: false
```

### Multiple rules in one file

Group related rules in the same `rules:` array:

```yaml
rules:
  - name: block-rm-rf
    on: PreToolUse Bash
    match: command =~ rm[[:space:]]+-rf[[:space:]]+(/|~)
    deny: "Blocked: destructive rm"

  - name: block-sudo
    on: PreToolUse Bash
    match: command =~ ^sudo[[:space:]]
    deny: "Blocked: sudo not allowed"
```
