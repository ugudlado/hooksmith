# hooksmith

A Claude Code plugin that compiles declarative YAML rule files into native `hooks.json` entries. Define hook behavior as simple YAML rules — the plugin automatically rebuilds when rules change.

## How It Works

```
~/.config/hooksmith/rules/*.yaml    →    hooksmith build    →    hooks.json
```

Each YAML rule becomes a native hook entry:

| Mechanism | hooks.json type | Runtime behavior |
|-----------|----------------|------------------|
| `regex`   | `type: command` | Thin bash wrapper tests a field against a pattern |
| `script`  | `type: command` | Your bash script runs directly |
| `prompt`  | `type: prompt`  | LLM evaluates the prompt natively — zero script overhead |

## Installation

```bash
claude plugin add ugudlado/hooksmith
```

Or install locally:

```bash
git clone https://github.com/ugudlado/hooksmith.git
claude --plugin-dir /path/to/hooksmith
```

## CLI

```bash
hooksmith list [--json] [--scope user|project|all]   # Show registered rules
hooksmith run <id>                                    # Execute a rule by id
hooksmith build                                       # Rebuild hooks.json from rules
hooksmith start                                       # SessionStart: rebuild if rules changed
hooksmith convert [--apply] [--scope user|project]   # Migrate settings.json hooks to YAML
```

## Getting Started

### Migrating existing hooks

If you already have hooks in `settings.json`, convert them to YAML rules first:

```bash
# Preview what will be converted (dry-run)
hooksmith convert

# Write the YAML rule files
hooksmith convert --apply

# Build hooks.json and activate immediately
hooksmith build
/reload-plugins
```

Then remove the converted entries from `settings.json` — hooksmith owns them now.

### Creating your first rule

1. Create a rule file (filename must match `id`):

```yaml
# ~/.config/hooksmith/rules/block-rm.yaml
id: block-rm
event: PreToolUse
matcher: Bash
mechanism: regex
field: command
pattern: 'rm[[:space:]]+-rf[[:space:]]+(/|~|\$HOME)'
result: deny
message: "Blocked: destructive rm targeting system or home directory."
```

2. Build and activate:

```bash
hooksmith build
/reload-plugins
```

> **Auto-build:** `hooksmith start` runs at each session start and rebuilds `hooks.json` only when rules have changed.

## Rule Scopes

- **User-level** (`~/.config/hooksmith/rules/`): Applies to all projects
- **Project-level** (`.hooksmith/rules/`): Applies to that project only

Project rules override user rules with the same filename.

## Rule Format

Every rule requires an `id` field matching the filename (without `.yaml`):

```yaml
id: my-rule            # Required — must match filename my-rule.yaml
event: PreToolUse      # Hook event
matcher: Bash          # Tool filter (optional)
mechanism: regex       # regex, script, or prompt
field: command         # Field to test (regex only)
pattern: 'dangerous'   # Regex pattern (regex only)
result: deny           # deny, ask, warn, or context
message: "Blocked."    # Output message (optional)
fail_mode: open        # open (default) or closed
enabled: true          # false to exclude from build
timeout: 10            # Seconds
```

### Mechanisms

| Use `regex` when... | Use `script` when... | Use `prompt` when... |
|---------------------|----------------------|----------------------|
| Matching a pattern in a known field | Logic is complex or stateful | Condition requires judgment |
| Zero overhead | You have an existing `.sh` script | Natural language evaluation |

### Result types

| Result | Effect |
|--------|--------|
| `deny` | Block the action |
| `ask` | Prompt user for approval |
| `warn` | Inject a warning into context |
| `context` | Inject information into context |

## Testing

```bash
bash tests/run-tests.sh
```

Covers CLI commands, deny/ask/allow behaviors across multiple hooks. Zero dependencies — pure bash.

## Dependencies

- `jq`
- `bash` 3.2+

## Examples

See `examples/` for sample rules covering all three mechanisms.

Ask Claude to "create a hook rule" or "add a regex rule" — the `hooksmith` skill provides the full field reference, result-event compatibility table, and guided rule creation workflow.

---

## Related & References

### Claude Code Hooks

- [Hooks reference](https://code.claude.com/docs/en/hooks) — Full event list, JSON payload shapes, decision fields by event
- [Automate workflows with hooks](https://code.claude.com/docs/en/hooks-guide) — Guide to hook patterns and use cases
- [Plugins reference](https://code.claude.com/docs/en/plugins-reference) — Plugin structure, `hooks.json` loading, `/reload-plugins`

### Hookify (Official Anthropic Plugin)

- [Hookify](https://claude.com/plugins/hookify) — Official Anthropic hook management plugin
- [Hookify on GitHub](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/hookify)
- [Writing Hookify rules](https://lobehub.com/skills/anthropics-claude-code-writing-rules)
