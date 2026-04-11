# hooksmith

A Claude Code plugin for declarative hook rules. Define behavior as YAML — hooksmith evaluates rules at runtime. No build step.

## How It Works

```
~/.config/hooksmith/hooks/*.yaml  ──→  hooksmith eval  ──→  JSON decision
```

One universal evaluator routes to the right rules at runtime. Claude Code fires an event, hooksmith checks matching rules, the first rule that triggers emits a decision.

| Mechanism | How it works | Best for |
|-----------|-------------|----------|
| `match`   | Tests a field against a POSIX ERE pattern | Simple pattern matching, zero overhead |
| `run`     | Executes a bash script (inline or file) | Complex logic, stateful checks |
| `prompt`  | Injects a prompt for Claude to reason about | Nuanced, context-dependent policies |

## Installation

Requires Claude Code v2.1.91+.

```bash
claude plugin add ugudlado/hooksmith
```

Or install locally:

```bash
git clone https://github.com/ugudlado/hooksmith.git
claude --plugin-dir /path/to/hooksmith
```

## Getting Started

### Creating your first rule

Drop a YAML file and it's live next session:

```yaml
# ~/.config/hooksmith/hooks/block-rm.yaml
rules:
  - name: block-rm
    on: PreToolUse Bash
    match: command =~ rm[[:space:]]+-rf[[:space:]]+(/|~|\$HOME)
    deny: "Blocked: destructive rm targeting system or home directory."
```

No build step needed. On SessionStart, hooksmith scans all rules, rebuilds its routing index, and registers the right events automatically.

### Migrating existing hooks

If you have hooks in `settings.json`, convert them to YAML:

```bash
# Preview what will be converted (dry-run)
hooksmith convert

# Write the YAML rule files
hooksmith convert --apply
```

Then remove the converted entries from `settings.json` — hooksmith owns them now.

## Starter Rules

Ready-to-use rules you can copy to `~/.config/hooksmith/hooks/`. Each rule is a standalone YAML file — pick what you need.

### Safety Guards

**Block dangerous bash commands** — catches `rm -rf /`, `sudo`, `chmod 777`, curl-pipe-sh:

```yaml
# ~/.config/hooksmith/hooks/bash-safety-guard.yaml
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    run: ~/.config/hooksmith/scripts/bash-safety-guard.sh
    deny: true
```

**Process kill guard** — only allows killing processes Claude started or processes inside the current repo:

```yaml
# ~/.config/hooksmith/hooks/process-kill-guard.yaml
rules:
  - name: process-kill-guard
    on: PreToolUse Bash
    run: ~/.config/hooksmith/scripts/process-kill-guard.sh
    deny: true
```

**Protected files** — asks for confirmation before editing lock files and manifests:

```yaml
# ~/.config/hooksmith/hooks/protected-files.yaml
rules:
  - name: protected-files
    on: PreToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/protected-files.sh
    ask: true
```

**Worktree boundary** — prevents writes outside the active git worktree:

```yaml
# ~/.config/hooksmith/hooks/worktree-boundary.yaml
rules:
  - name: worktree-boundary
    on: PreToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/worktree-boundary.sh
    deny: true
```

### Workflow Automation

**Autopilot redirect** — detects feature/bug requests and suggests `/develop`:

```yaml
# ~/.config/hooksmith/hooks/autopilot-redirect.yaml
rules:
  - name: autopilot-redirect
    on: UserPromptSubmit
    prompt: |
      Analyze this user message: $USER_PROMPT
      If it's clearly a FEATURE or BUG request, respond with a workflow hint.
      Otherwise respond with {}.
    context: true
```

**Loop detector** — blocks Claude from getting stuck in retry loops:

```yaml
# ~/.config/hooksmith/hooks/loop-detector.yaml
rules:
  - name: loop-detector
    on: Stop
    run: ~/.config/hooksmith/scripts/loop-detector.sh
    deny: true
```

### Session Lifecycle

**Git status at session start** — gives Claude branch and change awareness:

```yaml
# ~/.config/hooksmith/hooks/session-git-status.yaml
rules:
  - name: session-git-status
    on: SessionStart
    run: ~/.config/hooksmith/scripts/session-git-status.sh
    context: true
```

**Post-compact reminders** — re-injects critical context after compaction:

```yaml
# ~/.config/hooksmith/hooks/post-compact-reminders.yaml
rules:
  - name: post-compact-reminders
    on: PostCompact
    run: ~/.config/hooksmith/scripts/post-compact-reminders.sh
    context: true
```

### Development Tools

**Auto-format** — runs prettier/formatter after Write/Edit:

```yaml
# ~/.config/hooksmith/hooks/auto-format.yaml
rules:
  - name: auto-format
    on: PostToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/auto-format.sh
    context: true
```

**Smart notifications** — macOS alerts for permission prompts and idle:

```yaml
# ~/.config/hooksmith/hooks/smart-notify.yaml
rules:
  - name: smart-notify
    on: Notification
    run: ~/.config/hooksmith/scripts/smart-notify.sh
    context: true
```

> Scripts referenced above live in `~/.config/hooksmith/scripts/`. See `examples/` for self-contained rules that don't need external scripts.

## Packs

Packs are curated rule collections you can install from any git repo and update independently.

### Installing a pack

```bash
# From a git repo (whole repo as a pack)
hooksmith pack install owner/repo

# From a subdirectory of a git repo
hooksmith pack install ugudlado/hooksmith/packs/starter

# Full URL
hooksmith pack install https://github.com/owner/repo
```

### Managing packs

```bash
hooksmith pack list              # Show installed packs
hooksmith pack update [name]     # Update one or all packs
hooksmith pack remove <name>     # Remove an installed pack
```

### Overriding pack rules

Pack rules have the lowest precedence. Override any pack rule by creating a rule with the **same name** at user or project level:

```yaml
# Override: change bash-safety-guard from deny to ask
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    run: scripts/bash-safety-guard.sh
    ask: true  # ask instead of deny
```

To disable a pack rule entirely for a specific project:

```yaml
# .hooksmith/hooks/overrides.yaml
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    match: command =~ .
    deny: "unused"
    enabled: false
```

### Starter pack

The hooksmith repo includes a starter pack with safety rules:

```bash
hooksmith pack install ugudlado/hooksmith/packs/starter
```

Includes: `bash-safety-guard`, `process-kill-guard`, `protected-files`, `worktree-boundary`.

## CLI

The plugin's `bin/` directory is added to PATH automatically — all commands are bare:

```bash
hooksmith list [--json] [--scope user|project|all]   # Show registered rules
hooksmith init                                        # Regenerate hooks.json from rules
hooksmith convert [--apply] [--scope user|project]    # Migrate settings.json hooks to YAML
hooksmith pack <install|update|remove|list>            # Manage rule packs
hooksmith eval                                        # Evaluate rules (called by hooks.json, not directly)
```

## Rule Scopes

Rules are discovered from three tiers (highest precedence first):

1. **Project-level** (`.hooksmith/hooks/`): Applies to that project only
2. **User-level** (`~/.config/hooksmith/hooks/`): Applies to all projects
3. **Packs** (`~/.config/hooksmith/packs/*/`): Installed rule collections

When multiple rules share the same `name`, the highest-precedence one wins. A project rule with `enabled: false` and a matching name disables the lower-tier rule.

## Rule Format

Every rule lives inside a `rules:` array:

```yaml
rules:
  - name: my-rule          # Required — unique rule name
    on: PreToolUse Bash    # Event and optional tool matcher
    match: command =~ pat  # Mechanism: match, run, or prompt
    deny: "Reason"         # Action: deny, ask, or context
```

### The `on` field

```
on: <Event> [ToolMatcher]
```

- **Event** (required): `PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`, `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PostCompact`, `Notification`, etc.
- **Tool matcher** (optional): regex against `tool_name` — `Bash`, `Write|Edit`, etc.

### Mechanisms

**match** — Pattern matching:

```yaml
rules:
  - name: block-rm
    on: PreToolUse Bash
    match: command =~ rm[[:space:]]+-rf[[:space:]]+(/|~|\$HOME)
    deny: "Blocked: destructive rm targeting system or home directory."
```

Available fields: `command`, `file_path`, `content`, `user_prompt`, `tool_name`, or any `tool_input` key.

**run** — Custom bash logic:

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

When `deny: true`, the script's stdout becomes the deny reason. No output = allow.

**prompt** — LLM-evaluated:

```yaml
rules:
  - name: security-review
    on: PreToolUse Bash
    prompt: "Review this bash command for security risks. Deny if it modifies system files, accesses credentials, or runs with elevated privileges."
    ask: true
```

### Actions

| Action | Effect | Compatible events |
|--------|--------|-------------------|
| `deny: "reason"` | Block the action | PreToolUse, PostToolUse, Stop, UserPromptSubmit, SubagentStop |
| `ask: "reason"` | Prompt user for approval | PreToolUse only |
| `context: "text"` | Inject context for Claude | All events |

### All fields

| Field     | Required | Default | Description |
|-----------|----------|---------|-------------|
| `name`    | Yes      | —       | Unique rule name |
| `on`      | Yes      | —       | Event and optional tool matcher |
| `match`   | One of   | —       | Pattern: `field =~ pattern` (POSIX ERE) |
| `run`     | One of   | —       | Script path or inline bash |
| `prompt`  | One of   | —       | LLM prompt text |
| `deny`    | One of   | —       | Block with reason (or `true` for run/prompt) |
| `ask`     | One of   | —       | Ask for approval (PreToolUse only) |
| `context` | One of   | —       | Inject context message |
| `enabled` | No       | `true`  | Set `false` to disable without removing |

## Hooklib Helpers

Available in `run` scripts via `source "$HOOKLIB"`:

```bash
read_input                    # Read stdin JSON into $INPUT
get_field <name>              # Extract field (command, file_path, content, user_prompt, tool_name, cwd)
deny "reason"                 # Block with message
ask "reason"                  # Request user approval
context "text"                # Inject context for Claude
log "message"                 # Debug to stderr
```

## Testing

```bash
bash tests/run-tests.sh
```

Pure bash test runner, no dependencies. Covers all mechanisms and decision types.

## Dependencies

- `jq`
- `bash` 3.2+
- Claude Code v2.1.91+

## Examples

See `examples/` for working rules covering all three mechanisms.

Ask Claude to "create a hook rule" — the `hooksmith` skill provides guided rule creation.

---

## References

### Claude Code Hooks

- [Hooks reference](https://code.claude.com/docs/en/hooks) — Full event list, JSON payload shapes, decision fields
- [Automate workflows with hooks](https://code.claude.com/docs/en/hooks-guide) — Hook patterns and use cases
- [Plugins reference](https://code.claude.com/docs/en/plugins-reference) — Plugin structure, `bin/` on PATH, `hooks.json` loading
