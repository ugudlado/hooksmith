# Complete Field Reference

## Required Field: `id`

Every rule must have a unique `id`. It serves as the hook's stable identifier used by the runner (`hooksmith run <id>`), the registry listing (`hooksmith list`), and build validation.

```yaml
id: bash-safety-guard   # lowercase kebab-case only
```

**Rules:**
- Format: `^[a-z0-9-]+$` — lowercase letters, digits, and hyphens only
- Must match the YAML filename without extension: `id: bash-safety-guard` → file must be named `bash-safety-guard.yaml`
- Must be unique across all rules (user + project scopes combined)
- Build will error on missing, invalid format, filename mismatch, or duplicate

**Convention:** Use descriptive kebab-case names: `auto-format`, `process-kill-guard`, `spec-adherence-check`

---

## Event Types

All supported Claude Code hook events:

| Event | Description | Common use |
|-------|-------------|------------|
| `PreToolUse` | Before a tool executes | Block dangerous commands, require approval |
| `PostToolUse` | After a tool completes | Warn about results, inject context |
| `Stop` | Before Claude stops responding | Block premature stops, enforce checklists |
| `UserPromptSubmit` | When user sends a message | Inject context, enforce guidelines |
| `SessionStart` | When a session begins | Set up context, check environment |
| `SubagentStart` | When a subagent launches | Inject context for subagents |
| `SubagentStop` | When a subagent completes | Review subagent output |
| `PostCompact` | After context compression | Re-inject critical context |
| `Notification` | On notifications | Logging only (no results supported) |

## Matcher Field

The `matcher` field filters which tools trigger PreToolUse/PostToolUse hooks. Without a matcher, the hook runs for all tools.

```yaml
matcher: Bash              # Only Bash commands
matcher: Write|Edit        # Write or Edit operations
matcher: Read              # File reads
```

Common tool names: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `WebFetch`, `WebSearch`

## Field Values for Regex Rules

The `field` parameter in regex rules determines which JSON field to test:

| Field value | Extracts from | Use case |
|-------------|---------------|----------|
| `command` | `.tool_input.command` | Bash command text |
| `file_path` | `.tool_input.file_path` | File being read/written/edited |
| `content` | `.tool_input.content` or `.tool_input.new_string` | Content being written |
| `user_prompt` | `.user_prompt` | User's message (UserPromptSubmit) |
| `tool_name` | `.tool_name` | Name of the tool |
| `cwd` | `.cwd` | Current working directory |
| `<custom>` | `.tool_input.<custom>` then `.<custom>` | Any other field |

## Pattern Syntax

Patterns use bash extended regex (`=~` operator). Use POSIX classes (`[[:space:]]`, `[[:digit:]]`) instead of PCRE shortcuts (`\s`, `\d`) — bash does not support PCRE:

```yaml
# Character classes
pattern: 'rm[[:space:]]+-rf'              # [[:space:]] for whitespace
pattern: '\.(env|pem|key)$'      # Alternation and anchors
pattern: '^(sudo|su)[[:space:]]+'         # Start anchor

# Quantifiers
pattern: 'DROP[[:space:]]+TABLE'          # One or more whitespace
pattern: 'password[=:].*'        # Any characters after

# Special characters — single-quote the pattern in YAML
pattern: 'curl.*\|[[:space:]]*sh'         # Pipe to shell
pattern: 'chmod[[:space:]]+777'           # Numeric permissions
```

## Prompt Text

For prompt rules, the `prompt` field supports multi-line YAML:

```yaml
prompt: |
  Review this command: $TOOL_INPUT
  If dangerous, respond with deny JSON.
  Otherwise respond with: {}
```

Available variables (substituted by Claude Code at runtime):
- `$TOOL_INPUT` — The tool's input parameters
- `$TOOL_RESULT` — The tool's output (PostToolUse only)
- `$USER_PROMPT` — The user's message (UserPromptSubmit only)

## Fail Mode

Controls behavior when a script/regex rule crashes at runtime:

| Mode | On script error | Use when |
|------|-----------------|----------|
| `open` (default) | Allow the operation | Non-critical rules, warnings |
| `closed` | Deny the operation | Security-critical rules |

## Timeout

Default: 10 seconds. Prompt rules may need longer:

```yaml
timeout: 30    # For prompt rules with complex evaluation
timeout: 5     # For simple regex/script rules
```

## Advanced Patterns

### Disable a global rule per-project

Create a project rule with the same filename and `enabled: false`:

```yaml
# .hooksmith/rules/block-rm.yaml
# Overrides ~/.config/hooksmith/rules/block-rm.yaml
enabled: false
event: PreToolUse
mechanism: regex
field: command
pattern: 'unused'
result: deny
```

### Multiple patterns for different results

Split into separate rule files — one rule per file:

```
warn-git-force.yaml    # result: warn
block-git-reset.yaml   # result: deny
```

### Script rule with fail_mode: closed

For security-critical scripts that must deny on any error:

```yaml
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/security-check.sh
result: deny
fail_mode: closed
timeout: 15
```
