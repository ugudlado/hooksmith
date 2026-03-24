# Discovery Brief: Hooksmith ID-Based Registry & Runner

## Problem Statement

Hooksmith currently bakes full script paths into hooks.json at build time. Each compiled hook command looks like:
```
HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/fail-wrapper.sh open bash ${HOME}/.claude/hooks/smart-notify.sh
```

This has three problems:
1. **No discoverability** — No way to list what hooks are registered without parsing hooks.json
2. **No identity** — Hooks have no stable name; they're identified only by filename/path
3. **Brittle coupling** — Build output encodes the full execution chain (hooklib, fail-wrapper, script path), so any change requires a rebuild

## Use Cases

### Happy Path

- **UC-1**: User runs `hooksmith list` and sees a table of all registered hooks with id, event, mechanism, result, and scope — enabling quick audit of what's active
- **UC-2**: User creates a new YAML rule with `id: my-guard`, runs `build.sh`, and hooks.json contains `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run my-guard` — clean, explicit command
- **UC-3**: User changes a script path in their YAML rule and the hook works immediately without rebuilding hooks.json — because `run.sh` resolves at runtime
- **UC-4**: User converts hooks from settings.json using `convert.sh` and the generated YAML files automatically include an `id` field derived from the script filename

### Error / Edge Cases

- **UC-E1**: User creates two rules with the same `id` — build.sh rejects with a clear duplicate error message
- **UC-E2**: User omits `id` from a YAML rule — build.sh rejects with "missing required field 'id'"
- **UC-E3**: User uses uppercase or underscores in `id` — build.sh rejects with format validation error
- **UC-E4**: At runtime, `run.sh` receives an id that doesn't match any YAML rule — fails open (exit 0, stderr warning)

## Scope

### In Scope
- Required `id` field in YAML rules with validation (format, uniqueness)
- `./hooksmith` CLI dispatcher at plugin root (subcommands: `run`, `list`)
- `lib/run.sh` unified runner resolving id → YAML → execution
- `lib/list.sh` registry listing command
- `lib/parse.sh` shared YAML parser (extracted from build.sh)
- `build.sh` changes to emit `hooksmith run <id>` commands
- `lib/convert.sh` updates to auto-generate id
- Example and documentation updates
- Migration of existing 19 YAML rules

### Out of Scope
- `hooksmith enable/disable <id>` commands (future feature)
- `hooksmith new <id>` scaffolding command (future feature)
- `hooksmith remove <id>` command (future feature)
- Web UI or interactive TUI for hook management
- Changes to Claude Code's hook execution model

## Technical Context

### Key Files
- `build.sh` (360 lines) — YAML → hooks.json compiler with `parse_yaml()` and `get_val()` functions
- `hooks/hooks.json` (195 lines) — compiled hook entries, currently 19 hooks across 12 events
- `lib/fail-wrapper.sh` (14 lines) — wraps hooks for fail_mode handling
- `lib/hooklib.sh` (48 lines) — shared helpers sourced by script-type hooks
- `lib/regex-match.sh` (27 lines) — generic regex field matcher
- `lib/convert.sh` (291 lines) — settings.json → YAML converter
- `lib/auto-build.sh` (48 lines) — SessionStart change detection

### Integration Points
- Claude Code hook execution: reads hooks.json, invokes commands with stdin JSON
- YAML rule files: `~/.config/hooksmith/rules/*.yaml` (user), `.hooksmith/rules/*.yaml` (project)
- Checksum tracking: `hooks/.rules-checksum` for auto-rebuild detection

### No External Libraries
Pure bash — no dependencies beyond coreutils, jq, and awk.

## What Already Exists

### Internal
- `build.sh` already has `parse_yaml()` and `get_val()` — these become the shared parser
- `fail-wrapper.sh` logic is simple enough to absorb into the runner
- `convert.sh` already derives filenames from script paths — extending to generate `id` is trivial

### External
- Claude Code hooks documentation: https://docs.anthropic.com/en/docs/claude-code/hooks — defines the hooks.json schema, `type: "command"` and `type: "prompt"` formats, async flag, timeout behavior. No existing id or registry concept in the platform itself.
- No existing hook management tools or registries found for Claude Code plugins — this is novel plugin infrastructure.

## Key Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| `id` field | **Required** | Enables proper registry, duplicate detection, stable identity |
| `id` format | **Lowercase kebab-case** | `^[a-z0-9-]+$` — consistent, URL-safe, shell-safe |
| Script path | **Explicit in YAML** | Users retain full control over script locations |
| Execution | **Runner-based** | `run.sh` reads YAML at runtime, resolves mechanism, executes |
| Entry point | **Actual script, not symlink** | `./hooksmith` at plugin root avoids symlink issues in git/worktrees |
| List scope | **YAML rules only** | Source of truth; compiled hooks.json is an output artifact |
| Shared parser | **Extracted to lib/parse.sh** | DRY — used by build.sh, run.sh, and list.sh |

## Architecture Impact

### Files Modified
- `build.sh` — Validate `id`, check uniqueness, emit `hooksmith run <id>` commands, source `lib/parse.sh`
- `lib/convert.sh` — Auto-generate `id` from script filename when converting hooks
- `examples/*.yaml` — Add `id` field
- `skills/hooksmith/SKILL.md` — Document `id` field and list command
- `skills/hooksmith/references/field-reference.md` — Add `id` to field docs

### Files Created
- `./hooksmith` — Thin dispatch script at plugin root
- `lib/run.sh` — Unified hook runner (resolves id → YAML → execute)
- `lib/list.sh` — Registry listing (reads YAML rules, displays table)
- `lib/parse.sh` — Shared YAML parser (extracted from build.sh)

### Key Insight: run.sh absorbs fail-wrapper and hooklib

The runner becomes the single entry point. It:
1. Finds the YAML rule by id (searches user + project scopes)
2. Reads mechanism, fail_mode, script path, etc.
3. Sets up environment (HOOKLIB for script rules)
4. Applies fail_mode wrapping
5. Dispatches to the correct executor (regex-match.sh, user script, or prompt)

This means hooks.json entries become uniform and short:
```json
{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run smart-notify","timeout":10}
```

Prompt-type rules still need special handling since they use `type: "prompt"` in hooks.json, not `type: "command"`. The runner approach applies to command-based mechanisms (regex, script). Prompt rules emit their JSON directly.

## Risk Assessment

- **Low risk**: All changes are within the hooksmith plugin; no external dependencies
- **Migration**: Existing 19 YAML rules need `id` field added. Can be scripted.
- **Backward compat**: Not needed — this is a pre-1.0 plugin, rules are user-authored
- **Runtime resolution**: Adds ~10ms per hook invocation for YAML parsing. Acceptable given hooks already have 5-60s timeouts.

## Build or Reuse?

**Build** — This is custom plugin infrastructure for the hooksmith plugin. No existing tools, libraries, or Claude Code features provide hook identity, registry listing, or id-based runtime resolution. The implementation is pure bash with no external dependencies. Building is the only viable approach.

## UI Direction

**N/A** — This feature is entirely CLI/script-based with no UI components.
