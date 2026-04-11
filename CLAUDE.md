# Hooksmith

Declarative YAML hook rules for Claude Code. Pure bash, no compile step.

## Commands

```bash
bash tests/run-tests.sh        # Run all tests (100 tests, custom runner)
hooksmith list                  # Show registered rules
hooksmith init                  # Regenerate hooks.json from rules
hooksmith pack <subcommand>     # Manage rule packs (install/update/remove/list)
hooksmith eval                  # Evaluate rules (called by hooks.json, not directly)
```

## Architecture

```
bin/
└── hooksmith              — CLI dispatcher (on PATH via plugin bin/)
lib/
├── eval.sh                — Rule evaluator (event-keyed map routing)
├── core/
│   ├── config.sh          — Paths, rule discovery, debug logging
│   ├── hooklib.sh         — Helpers for run scripts (read_input, get_field, deny, ask, context)
│   └── map.sh             — Auto-indexing map builder (.hooksmith/.map.json)
└── cli/
    ├── init.sh            — Scan rules → rebuild map + hooks.json events
    ├── list.sh            — List registered rules
    ├── convert.sh         — Migrate settings.json hooks to YAML
    └── pack.sh            — Pack management (install/update/remove/list)
hooks/
└── hooks.json             — Static routing table (hooksmith eval for each event)
skills/
└── hooksmith/             — Skill for creating rules via Claude
.claude-plugin/
└── plugin.json            — Plugin manifest (version, metadata)
examples/                  — Example rules for each mechanism
packs/
└── starter/               — Starter pack (installable via hooksmith pack install)
```

## Eval Pipeline

1. Claude Code fires event → calls `hooksmith eval` via hooks.json
2. eval.sh reads stdin JSON, extracts `hook_event_name` + `tool_name`
3. Looks up event in .hooksmith/.map.json (event-keyed index)
4. Filters by tool matcher regex, evaluates matching rules
5. First rule that triggers emits JSON decision (deny/ask/context)

## Key Conventions

- Pure bash — only external dep is `jq`
- `set -uo pipefail` in all scripts
- POSIX ERE for regex (use `[[:space:]]` not `\s`)
- Map auto-rebuilds when any rule file is newer than .map.json
- hooks.json is a static file — registers `hooksmith eval` for all events
- Rule files: YAML with `rules:` array, discovered from .hooksmith/hooks/, ~/.config/hooksmith/hooks/, and ~/.config/hooksmith/packs/*/
- Rule precedence: project > user > pack (name-based dedup, first wins)
- Pack scripts use relative paths from the rule file's directory
- CLI dispatcher lives in `bin/hooksmith` — Claude Code adds `bin/` to PATH automatically

## Testing

- Custom test runner at tests/run-tests.sh (no framework)
- Fixtures in tests/fixtures/ — JSON payloads piped to eval
- Tests verify eval decisions (allow/deny/ask/context) for each mechanism
- Run with sandbox disabled — tests need filesystem access

## Gotchas

- MAP_FILE location falls back to TMPDIR if ~/.config/hooksmith is not writable (sandbox compat)
- Pack rules with same name as user/project rules are silently overridden (not evaluated)
- Packs store origin info in .packinfo for `hooksmith pack update` to work
- hooks.json registers all events (static file) — map determines which have active rules
- `deny: true` in run rules means script stdout becomes the deny reason
- Plugin version lives in .claude-plugin/plugin.json (bump on release)
- Requires Claude Code v2.1.91+ (plugin `bin/` support)
