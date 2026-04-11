---
name: hooksmith
description: "This skill should be used when the user asks to 'create a hook rule', 'write a YAML rule', 'add a match rule', 'add a script rule', 'add a prompt rule', 'block a command', 'deny a tool', 'add a hook', 'configure hook behavior', 'list my hooks', 'show registered hooks', 'hooksmith list', 'hooksmith eval', 'hooksmith convert', 'hooksmith init', 'convert hooks to rules', 'migrate hooks', 'import hooks from settings', 'convert settings.json hooks', or is working with hooksmith YAML rule files. Provides the CLI interface, rule file format, result-event compatibility, and examples for match, run, and prompt mechanisms."
---

# Hooksmith

Manage Claude Code hooks declaratively via YAML rules. The `hooksmith` CLI evaluates rules live at runtime, lists what's registered, and generates the routing table.

## Architecture

Hooksmith is a **single-evaluator, multi-rule** system. Instead of one hook per rule, there's one universal evaluator that dynamically routes to the right rules at runtime.

### How it works

1. `hooks/hooks.json` registers `hooksmith eval` as a `type: "command"` hook for each event
2. When Claude Code fires an event, it calls `hooksmith eval` and pipes in a JSON payload
3. `eval.sh` checks the auto-indexing map (`.hooksmith/.map.json`) for matching rules
4. Each matching rule is loaded from YAML and evaluated via its mechanism (`match`, `run`, or `prompt`)
5. The first rule that triggers emits a JSON decision back to Claude Code

### Event payload

Claude Code pipes this JSON to stdin:

```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf /" },
  "cwd": "/Users/you/project"
}
```

### Registered events and auto-init

On every SessionStart, hooksmith automatically scans all rules, discovers which events they use, and regenerates `hooks.json` with exactly those events (plus SessionStart itself). This means:

- **Adding a rule for a new event** (e.g. `on: SubagentStop`) is automatic — next session, hooksmith registers it
- **No manual `hooksmith init` needed** in normal use
- Only events with active rules get registered, avoiding unnecessary shell invocations

### The `on` field

Every rule's `on` field has two parts:

```
on: <Event> [ToolMatcher]
```

- **Event** (required): must match `hook_event_name` exactly — `PreToolUse`, `Stop`, etc.
- **Tool matcher** (optional): regex tested against `tool_name` — `Bash`, `Write|Edit`, etc.

Examples:
- `on: PreToolUse Bash` — only when Claude is about to run Bash
- `on: PreToolUse Write|Edit` — before Write or Edit
- `on: UserPromptSubmit` — on every user message (no tool matcher)
- `on: Stop` — when Claude is about to end its turn

### Rule file locations

Rules are auto-discovered from two locations:

- **Project scope**: `.hooksmith/rules/<name>.yaml` or `.hooksmith/hooksmith.yaml`
- **User scope**: `~/.config/hooksmith/rules/<name>.yaml` or `~/.config/hooksmith/hooksmith.yaml`

No build step — drop a YAML file and it's live. The map auto-rebuilds when any rule file changes.

### Auto-indexing map

The map (`.hooksmith/.map.json`) is a lightweight routing index:

```json
[{"name": "block-rm", "file": ".hooksmith/rules/security/block-rm.yaml", "index": 0}]
```

It only stores name, file path, and rule array index. Actual rule content stays in YAML. The map auto-rebuilds when:
- Any rule file is newer than `.map.json`
- A rule file is added or deleted

## Creating a Hook — Guided Workflow

When the user asks to create, add, or write a hook rule, follow this flow:

### Step 1: Understand the intent

Read what the user wants to achieve. Extract:
- **What to watch**: which event and tool (e.g. "when Claude runs bash commands", "before writing files")
- **What to check**: the condition (e.g. "if the command contains rm -rf", "if the file is a .env file")
- **What to do**: the action (e.g. "block it", "ask for approval", "add context")

If the intent is vague, ask one focused question to clarify the condition or action before proceeding.

### Step 2: Recommend a mechanism

Pick the best mechanism based on the intent — don't ask the user to choose:

| Use `match` when... | Use `run` when... | Use `prompt` when... |
|---------------------|-------------------|----------------------|
| Matching a pattern in a known field (command text, file path, content) | Logic is complex, stateful, or needs shell utilities | The condition is nuanced or contextual |
| Simple allow/block with no ambiguity | The user already has a `.sh` script | You want Claude to reason about the action |
| Best performance, zero overhead | Full control over output format | Human-language policies (e.g. "review for security risks") |

**Default preference order: match → run → prompt**. Use prompt when the logic is best expressed in natural language.

### Step 3: Draft the rule and show it to the user

Generate the complete YAML and **show it before writing anything**:

```yaml
rules:
  - name: block-rm-rf
    on: PreToolUse Bash
    match: command =~ rm[[:space:]]+-rf
    deny: "Blocked: rm -rf is not allowed."
```

Ask the user to confirm or request changes.

### Step 4: Write and confirm

Once the user approves:

1. **Write** the rule file:
   ```
   ~/.config/hooksmith/rules/<name>.yaml     # user scope (default)
   .hooksmith/rules/<name>.yaml              # project scope
   ```

2. **Confirm** with `hooksmith list`.

3. **Tell the user**: *"Done. The `<name>` hook is registered and will be active from the next session."*

## CLI Commands

```bash
hooksmith eval       # Evaluate rules (called by hooks.json — not invoked directly)
hooksmith init       # Scan rules, regenerate hooks.json (runs automatically on SessionStart)
hooksmith list       # Show registered hooks [--json] [--scope user|project|all]
hooksmith convert    # Migrate settings.json hooks to YAML [--apply] [--scope user|project]
```

All commands are invoked as bare commands (the plugin's `bin/` directory is on PATH).

### hooksmith list

Output columns: NAME, EVENT, MATCHER, TYPE, ACTION, SCOPE. Disabled rules show `[disabled]`.

### hooksmith convert

Migrates command hooks from `settings.json` into YAML rule files.

**Automatically skipped:** plugin hooks, `type: http`/`agent`, `type: prompt`, scripts using `updatedInput`.

### hooksmith init

Scans all rule files, discovers which events they use, and generates `hooks.json` with exactly those events plus SessionStart. Runs automatically on every SessionStart — you rarely need to run this manually.

## Rule Format

Every rule lives inside a `rules:` array:

```yaml
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    run: ~/.claude/hooks/bash-safety-guard.sh
    deny: true
```

## Rule Mechanisms

### match — Pattern matching

```yaml
rules:
  - name: block-rm
    on: PreToolUse Bash
    match: command =~ rm[[:space:]]+-rf[[:space:]]+(/|~|\$HOME)
    deny: "Blocked: destructive rm targeting system or home directory."
```

Syntax: `match: <field> =~ <pattern>` (POSIX ERE — use `[[:space:]]` not `\s`)

Available fields for matching:
- `command` — Bash command text (`tool_input.command`)
- `file_path` — file path for Write/Edit/Read (`tool_input.file_path`)
- `content` — file content or new_string (`tool_input.content` or `tool_input.new_string`)
- `user_prompt` — the user's message (UserPromptSubmit events)
- `tool_name` — name of the tool being used
- Any other field — looked up in `tool_input` then top-level

### run — Custom bash logic

Inline script:

```yaml
rules:
  - name: sudo-guard
    on: PreToolUse Bash
    run: |
      source "$HOOKLIB"
      read_input
      cmd=$(get_field command)
      [[ "$cmd" =~ ^sudo ]] && echo "Root access not allowed"
    deny: true
```

External script file:

```yaml
rules:
  - name: port-scan-guard
    on: PreToolUse Bash
    run: ~/.claude/hooks/port-scan-guard.sh
    deny: true
```

When `deny: true`, the script's stdout becomes the reason. No output = allow.

### prompt — LLM-evaluated rules

```yaml
rules:
  - name: security-review
    on: PreToolUse Bash
    prompt: "Review this bash command for security risks. Deny if it modifies system files, accesses credentials, or runs with elevated privileges."
    ask: true
```

The prompt text + tool input are injected into Claude's context via the command hook output. Claude then reasons about whether to allow/deny. This is the most flexible mechanism — use it when the condition is too nuanced for regex or a script.

Prompt rules always fire when the event matches (no condition to test). The action (`deny`, `ask`, `context`) determines how Claude treats the injected prompt.

Non-blocking context injection:

```yaml
rules:
  - name: code-style-advisor
    on: PreToolUse Write|Edit
    prompt: "Check if this edit follows project conventions: consistent naming, no magic numbers, functions under 30 lines."
    context: true
```

## Action Types

| Action | Effect | Compatible events |
|--------|--------|-------------------|
| `deny: "<reason>"` | Block the tool use | PreToolUse, PostToolUse, Stop, UserPromptSubmit, SubagentStop |
| `ask: "<reason>"` | Prompt user for approval | PreToolUse only |
| `context: "<text>"` | Inject additional context for Claude | All events |

## Field Reference

| Field     | Required | Default | Description |
|-----------|----------|---------|-------------|
| `name`    | Yes      | —       | Unique rule name |
| `on`      | Yes      | —       | Event and optional tool matcher: `Event [Matcher]` |
| `match`   | One of   | —       | Pattern: `field =~ pattern` |
| `run`     | One of   | —       | Script path or inline bash |
| `prompt`  | One of   | —       | LLM prompt text — Claude reasons about the action |
| `deny`    | One of   | —       | Block action with reason (or `true` for run/prompt rules) |
| `ask`     | One of   | —       | Ask action with reason (PreToolUse only) |
| `context` | One of   | —       | Inject context with message |
| `enabled` | No       | `true`  | Set `false` to disable without removing |

## Hooklib Helpers (run rules)

Available in `run` scripts via `source "$HOOKLIB"`:

```bash
source "$HOOKLIB"
read_input                    # Read stdin JSON into $INPUT
get_field <name>              # Extract field from input (command, file_path, content, user_prompt, tool_name, cwd, or any field)
deny "reason"                 # Block with message
ask "reason"                  # Request user approval
context "text"                # Inject context for Claude
block_stop "reason"           # Block a Stop event
log "message"                 # Debug to stderr
```

## All Supported Events

| Event | Description |
|-------|-------------|
| PreToolUse | Before executing a tool |
| PostToolUse | After a tool finishes |
| PostToolUseFailure | After a tool fails |
| PermissionRequest | When a permission check occurs |
| Stop | Claude is about to end its turn |
| StopFailure | Stop was blocked and failed |
| UserPromptSubmit | User submits a message |
| SessionStart | Session begins |
| SessionEnd | Session ends |
| SubagentStart | Subagent spawned |
| SubagentStop | Subagent about to finish |
| TeammateIdle | Teammate has no work |
| TaskCompleted | A task finishes |
| Notification | Notification fired |
| PreCompact | Before context compaction |
| PostCompact | After context compaction |
| ConfigChange | Settings changed |
| InstructionsLoaded | CLAUDE.md loaded |
| WorktreeCreate | Git worktree created |
| WorktreeRemove | Git worktree removed |
| Elicitation | Elicitation requested |
| ElicitationResult | Elicitation completed |

Events are auto-registered based on your rules. SessionStart is always registered for auto-init. Just use any event in a rule's `on` field and it will be active next session.

## Additional Resources

### Reference Files

For detailed field documentation and real-world patterns, consult:
- **`references/field-reference.md`** — Complete field reference: all events, match fields, action types, pattern syntax, advanced patterns
- **`references/patterns.md`** — 15 production rule patterns organized by category: safety guards, workflow automation, session lifecycle, subagent management, dev tools. Includes a pattern selection guide.

### Example Files

Working examples in `examples/`:
- **`examples/regex-rule.yaml`** — Match mechanism (pattern-based deny)
- **`examples/script-rule.yaml`** — Run mechanism (external script + deny: true)
- **`examples/prompt-rule.yaml`** — Prompt mechanism (LLM-evaluated ask)
