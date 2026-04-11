# Real-World Rule Patterns

Production patterns organized by category. Each pattern shows the YAML rule and explains the design choice.

---

## Safety Guards

### Bash safety guard — block dangerous commands via script

```yaml
rules:
  - name: bash-safety-guard
    on: PreToolUse Bash
    run: ~/.config/hooksmith/scripts/bash-safety-guard.sh
    deny: true
```

**Pattern**: External script + `deny: true`. The script checks multiple dangerous patterns (rm -rf, sudo, chmod 777, curl-pipe-sh, etc.) and prints a reason if any match. No output = allow.

**When to use**: When the deny logic has many branches or needs shell utilities (grep, awk, jq). A single `match` rule can only test one pattern.

### Process kill guard — verify PID ownership before allowing kill

```yaml
rules:
  - name: process-kill-guard
    on: PreToolUse Bash
    run: ~/.config/hooksmith/scripts/process-kill-guard.sh
    deny: true
```

**Pattern**: Stateful script that checks a PID registry. Allows kills only if the PID was started by Claude or belongs to the current repo.

**When to use**: When the decision depends on external state (files, running processes, git status) not available in the hook input JSON.

### Protected files — ask before editing lock files and manifests

```yaml
rules:
  - name: protected-files
    on: PreToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/protected-files.sh
    ask: true
```

**Pattern**: Script + `ask: true`. Instead of hard-blocking, the script checks if the target file matches protected patterns (package-lock.json, yarn.lock, plugin.json, etc.) and asks the user to confirm. No output = allow silently.

**When to use**: When edits should be reviewed but not outright denied.

### Worktree boundary — prevent writes outside active worktree

```yaml
rules:
  - name: worktree-boundary
    on: PreToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/worktree-boundary.sh
    deny: true
```

**Pattern**: Script checks if the target `file_path` is inside the current git worktree root. Denies cross-worktree writes to prevent accidental changes to the wrong branch.

**When to use**: Multi-worktree setups where isolation between features matters.

---

## Workflow Automation

### Autopilot redirect — route features/bugs to a workflow

```yaml
rules:
  - name: autopilot-redirect
    on: UserPromptSubmit
    prompt: |
      Analyze this user message: $USER_PROMPT
      If FEATURE or BUG, respond with workflow hint JSON.
      Otherwise respond with {}.
    context: true
```

**Pattern**: Prompt rule on UserPromptSubmit. Claude analyzes the user's message and injects a workflow suggestion as additional context. The `context: true` action means it's non-blocking — Claude sees the hint but the user isn't interrupted.

**When to use**: Soft routing — suggest a workflow without forcing it.

### Spec adherence check — verify commits match the spec

```yaml
rules:
  - name: spec-adherence-check
    on: PreToolUse Bash
    run: ~/.config/hooksmith/scripts/spec-adherence-check.sh
    context: true
```

**Pattern**: Script detects `git commit` commands in feature worktrees, reads the spec, and injects a reminder to check the commit aligns with the plan. Uses `context: true` to advise without blocking.

**When to use**: Inject guardrails into existing workflows without interrupting them.

### Loop detector — block repetitive tool-call loops

```yaml
rules:
  - name: loop-detector
    on: Stop
    run: ~/.config/hooksmith/scripts/loop-detector.sh
    deny: true
```

**Pattern**: Stop event + `deny: true`. When Claude is about to end its turn, the script checks if the recent tool calls show a repetitive pattern. If looping is detected, it blocks the stop and forces Claude to break the cycle.

**When to use**: Prevent Claude from getting stuck in retry loops.

---

## Session Lifecycle

### Git status at session start

```yaml
rules:
  - name: session-git-status
    on: SessionStart
    run: ~/.config/hooksmith/scripts/session-git-status.sh
    context: true
```

**Pattern**: SessionStart + context injection. The script runs `git status`, `git log --oneline -5`, and branch info, then formats it as context for Claude. Gives Claude situational awareness from the first message.

### Session reflection at end

```yaml
rules:
  - name: session-reflect
    on: SessionEnd
    run: ~/.config/hooksmith/scripts/session-reflect.sh
    context: true
```

**Pattern**: SessionEnd + context injection. Analyzes the session transcript to extract learnings before the session closes.

### Post-compact reminders

```yaml
rules:
  - name: post-compact-reminders
    on: PostCompact
    run: ~/.config/hooksmith/scripts/post-compact-reminders.sh
    context: true
```

**Pattern**: PostCompact fires after Claude Code compresses context. Critical reminders that would be lost in compaction are re-injected.

**When to use**: Any context that must survive compaction (active task details, critical constraints, workflow state).

---

## Subagent Management

### Inject spec context into subagents

```yaml
rules:
  - name: subagent-task-context
    on: SubagentStart
    run: ~/.config/hooksmith/scripts/subagent-task-context.sh
    context: true
```

**Pattern**: SubagentStart + context. When a subagent spawns, inject relevant spec/task context so it has the same situational awareness as the parent.

### Review subagent output

```yaml
rules:
  - name: subagent-gate
    on: SubagentStop
    run: ~/.config/hooksmith/scripts/subagent-gate.sh
    context: true
```

**Pattern**: SubagentStop + context. Reviews what the subagent produced and injects a summary or warnings for the parent agent.

---

## Development Tools

### Auto-format after writes

```yaml
rules:
  - name: auto-format
    on: PostToolUse Write|Edit
    run: ~/.config/hooksmith/scripts/auto-format.sh
    context: true
```

**Pattern**: PostToolUse on Write|Edit. After Claude writes or edits a file, run a formatter (prettier, black, gofmt) automatically. The script detects file type and runs the appropriate formatter.

### Track dev server processes

```yaml
rules:
  - name: dev-server-register
    on: PostToolUse Bash
    run: ~/.config/hooksmith/scripts/dev-server-register.sh
    context: true
```

**Pattern**: PostToolUse on Bash. After a Bash command completes, check if it started a dev server and register the PID. Works with `process-kill-guard` to track which processes Claude started.

### Smart notifications

```yaml
rules:
  - name: smart-notify
    on: Notification
    run: ~/.config/hooksmith/scripts/smart-notify.sh
    context: true
```

**Pattern**: Notification event. Sends macOS notifications (via osascript) for permission prompts and idle states so the user doesn't have to watch the terminal.

---

## Pattern Selection Guide

| Scenario | Mechanism | Action | Why |
|----------|-----------|--------|-----|
| Block a specific command pattern | `match` | `deny` | Fast, no script overhead |
| Block based on complex logic or state | `run` | `deny: true` | Script can check files, processes, git |
| Ask user to confirm sensitive edits | `run` | `ask: true` | Script decides when to ask |
| Inject context without blocking | `run` or `prompt` | `context: true` | Non-blocking guidance |
| Route based on natural language | `prompt` | `context: true` | Claude reasons about the message |
| Hard block with Claude reasoning | `prompt` | `deny: true` | Claude decides whether to block |
| Track state after tool use | `run` on PostToolUse | `context: true` | React to completed actions |
| Lifecycle hooks (start/end/compact) | `run` on session events | `context: true` | Setup/teardown/recovery |
