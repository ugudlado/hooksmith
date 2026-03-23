# Discovery Brief — Lean Hook Engine

## Concept

A Claude Code plugin that compiles declarative YAML rule files into native `hooks.json` entries. Each rule defines a trigger (hook event), mechanism (regex, script, or prompt), and result (deny, ask, warn, context). A build step generates hooks.json — no runtime dispatcher, no middleware.

## Personas

- **Developer**: Writes hook rules as YAML files, expects reliable enforcement
- **Claude (agent)**: Receives enforcement/context from generated hooks
- **Other users**: Install the plugin, write their own rules without bash expertise

## Use Cases

- UC-1: **Bash script rules** — YAML rule with `mechanism: script` generates native `"type": "command"` hook entry
- UC-2: **LLM prompt rules** — YAML rule with `mechanism: prompt` generates native `"type": "prompt"` hook entry (true LLM evaluation)
- UC-3: **Regex rules** — YAML rule with `mechanism: regex` generates command hook calling thin regex-match.sh
- UC-4: **Shared hooklib** — hooklib.sh with deny/warn/ask/context/get_field helpers, sourced by script rules via $HOOKLIB
- UC-E1: **Script failure** — `fail_mode: open|closed` per rule, handled by fail-wrapper.sh
- UC-E2: **Ordering** — rules sorted alphabetically by filename within each event+matcher group

## Scope

**In scope:**
- Plugin scaffold (plugin.json, hooks.json, build.sh)
- Build script that reads YAML rules → generates hooks.json (idempotent, full regeneration)
- Three runtime components: regex-match.sh, fail-wrapper.sh, hooklib.sh (~95 lines total)
- Two rule scopes: user-level (~/.claude/hooks/rules/) and project-level (.claude/hooks/rules/)
- /lean-hooks build and /lean-hooks list commands
- Build-time validation (mutual exclusivity of mechanism fields, result-event compatibility)
- Migration guide for existing hooks

**Out of scope:**
- Python handlers
- Runtime rule loading (no restart = rebuild required)
- Complex condition operators (AND/OR)
- Conversation analysis agent
- Marketplace publishing (for now)

## Key Decisions

- Separate repo (not tied to any project)
- Build-step model (not runtime dispatch) — enables true native prompt hooks
- YAML rule files (not markdown with frontmatter) — simpler parsing
- One rule = one hook entry in hooks.json (no aggregation middleware)
- jq as the only external dependency
- Bash 3.2 compatible (no associative arrays in runtime components)
- Project rules override user rules by filename

## UI Direction

N/A — no UI components
