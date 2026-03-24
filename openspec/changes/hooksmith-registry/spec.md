# Spec: Hooksmith ID-Based Registry & Runner

## S1: `id` Field in YAML Rules

### Requirements
- `id` is a **required** field in every YAML rule file
- Format: lowercase kebab-case, matching `^[a-z0-9-]+$`
- Must be unique across the merged rule set (user + project scopes combined, post-merge)
- **Must equal the YAML filename without extension** (e.g., `id: bash-safety-guard` in `bash-safety-guard.yaml`)
- Position: conventionally first line after comments, before `event`

### Validation (build.sh)
- Missing `id` → `ERROR [filename]: missing required field 'id'`
- Invalid format → `ERROR [filename]: id 'My_Hook' must be lowercase kebab-case (a-z, 0-9, hyphens)`
- id != filename → `ERROR [filename]: id 'foo' does not match filename 'bar.yaml'`
- Duplicate → `ERROR [filename]: duplicate id 'bash-safety-guard' (already defined in <other-file>)`
- Note: uniqueness is enforced on the post-merge rule set (tmpdir), so two rules with different filenames but the same `id` across scopes are caught

### Example
```yaml
id: bash-safety-guard
event: PreToolUse
matcher: Bash
mechanism: script
script: ~/.claude/hooks/bash-safety-guard.sh
result: deny
fail_mode: closed
```

---

## S2: Shared Parser — `lib/parse.sh`

### Requirements
- Extract `parse_yaml()` and `get_val()` from `build.sh` into `lib/parse.sh`
- `build.sh` sources `lib/parse.sh` instead of defining these functions inline
- `run.sh` and `list.sh` also source `lib/parse.sh`
- No behavioral change to parsing — pure extraction

### Acceptance Criteria
- `build.sh` produces identical `hooks.json` output before and after extraction
- All three consumers (`build.sh`, `run.sh`, `list.sh`) can source the parser

---

## S3: Entry Point & Runner — `./hooksmith` + `lib/run.sh`

### Entry Point (`./hooksmith`)
CLI dispatcher at plugin root using `exec bash` (not `source`):
```bash
#!/bin/bash
PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  list)    shift; exec bash "${PLUGIN_ROOT}/lib/list.sh" "$@" ;;
  run)     shift; exec bash "${PLUGIN_ROOT}/lib/run.sh" "$@" ;;
  *)       echo "hooksmith: unknown command '${1:-}'" >&2; exit 1 ;;
esac
```

### Requirements
- Invocation: `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run <id>` (hook execution)
- Invocation: `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list [--json] [--scope ...]` (registry listing)
- Extensible: future subcommands slot into the case dispatcher
- `lib/run.sh` sources `lib/parse.sh` for YAML parsing
- Receives stdin from Claude Code (hook context JSON)

### Resolution Order
1. `.hooksmith/rules/<id>.yaml` (project scope — checked first)
2. `~/.config/hooksmith/rules/<id>.yaml` (user scope — fallback)
3. If not found → stderr warning, exit 0 (fail-open — no rule to read fail_mode from)

### Mechanism Dispatch

All dispatch uses **capture-then-emit** model (matching `fail-wrapper.sh` behavior):
- Stdout captured via `output=$(...  2>/dev/null)` — stderr from underlying scripts is suppressed
- On success: emit captured stdout
- On failure: apply fail_mode

**Regex:**
```bash
output=$(echo "$INPUT" | bash "${PLUGIN_ROOT}/lib/regex-match.sh" "$field" "$pattern" "$message" "$result" 2>/dev/null)
```

**Script:**
```bash
output=$(echo "$INPUT" | HOOKLIB="${PLUGIN_ROOT}/lib/hooklib.sh" bash "$script_path" 2>/dev/null)
```

**Prompt:**
- Not dispatched by `run.sh` — prompt rules are emitted directly in hooks.json as `type: "prompt"`. This is because Claude Code handles prompt hooks differently from command hooks.

### Fail Mode Handling
- `run.sh` absorbs `fail-wrapper.sh` behavior with capture-then-emit model
- On script/regex success: emit captured stdout
- On script/regex failure:
  - `fail_mode: open` (default) → exit 0 (allow, no output)
  - `fail_mode: closed` → emit deny JSON, exit 0

### Edge Cases
- Rule file not found for id → stderr warning, exit 0 (fail-open)
- Rule file has `enabled: false` → stderr warning, exit 0 (no-op)
- YAML file found but malformed/unparseable → stderr warning, exit 0 (fail-open — no fail_mode available)
- Script path in YAML not found → apply fail_mode behavior
- Timeout is NOT handled by `run.sh` — it's in hooks.json and enforced by Claude Code
- Build-time script existence check in `validate_rule()` is preserved (unchanged) for early error detection

---

## S4: List — `lib/list.sh`

### Requirements
- Invocation: `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith list [--json] [--scope user|project|all]`
- Also callable directly: `bash ${CLAUDE_PLUGIN_ROOT}/lib/list.sh [--json] [--scope user|project|all]`
- Sources `lib/parse.sh` for YAML parsing
- Reads rules from both scopes (user: `~/.config/hooksmith/rules/`, project: `.hooksmith/rules/`)
- Shows project overrides (when project rule has same filename as user rule)
- `--scope` filters output to user-only, project-only, or all (default: all)

### Default Output (table)
```
HOOKSMITH RULES
──────────────────────────────────────────────────────────────────────────────────
ID                          EVENT             MATCHER       MECH    RESULT  SCOPE
bash-safety-guard           PreToolUse        Bash          script  deny    user
process-kill-guard          PreToolUse        Bash          script  deny    user
auto-format                 PostToolUse       Write|Edit    script  warn    user
smart-notify                Notification      —             script  warn    user
disabled-example            PreToolUse        Bash          regex   deny    user   [disabled]
──────────────────────────────────────────────────────────────────────────────────
19 rules (17 user, 2 project) · 1 disabled
```

### JSON Output (`--json`)
```json
[
  {
    "id": "bash-safety-guard",
    "event": "PreToolUse",
    "matcher": "Bash",
    "mechanism": "script",
    "result": "deny",
    "fail_mode": "closed",
    "scope": "user",
    "enabled": true,
    "file": "~/.config/hooksmith/rules/bash-safety-guard.yaml"
  }
]
```

### Sorting
- Primary: event name (alphabetical)
- Secondary: id (alphabetical)

### Edge Cases
- No rules found → `No hooksmith rules found. Create rules in ~/.config/hooksmith/rules/ or .hooksmith/rules/`
- Rules with parse errors → show with `[error]` marker, log error to stderr

---

## S5: Build Changes — `build.sh`

### New Validations (added to `validate_rule()`)
1. `id` required — same pattern as existing required field checks
2. `id` format — regex check `^[a-z0-9-]+$`
3. `id` uniqueness — tracked in an associative-like structure during rule processing

### New Command Generation

For regex and script mechanisms, generate:
```json
{
  "type": "command",
  "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run <id>",
  "timeout": <timeout>
}
```

For prompt mechanism (unchanged):
```json
{
  "type": "prompt",
  "prompt": "<prompt-text>",
  "timeout": <timeout>
}
```

### `generate_entry()` Simplification
- The function shrinks significantly — no more mechanism-specific command construction for regex/script
- Only prompt retains its current generation logic
- `async` flag still appended when `async: true`

---

## S6: convert.sh Updates

### ID Generation
- Derive `id` from script filename: `~/.claude/hooks/bash-safety-guard.sh` → `bash-safety-guard`
- For rules without a script: derive from `event-matcher` lowercased with hyphens
- Validate generated id matches `^[a-z0-9-]+$`
- Add `id:` as first non-comment line in generated YAML

---

## S7: Example & Documentation Updates

### Examples (`examples/*.yaml`)
- Add `id:` field to all example YAML files

### Skill Documentation (`skills/hooksmith/SKILL.md`)
- Add `id` to required fields section
- Document `list.sh` usage and output
- Update all YAML examples to include `id`
- Add "Listing Rules" section

### Field Reference (`skills/hooksmith/references/field-reference.md`)
- Add `id` field documentation (required, format, uniqueness)
- Update examples

---

## S8: Migration — Existing YAML Rules

### Approach
- The 19 existing rules in `~/.config/hooksmith/rules/` need `id` added
- Since filenames already follow kebab-case convention, `id` = filename without extension
- A migration script inserts `id:` before the first line of each file:
  ```bash
  for f in ~/.config/hooksmith/rules/*.yaml; do
    name=$(basename "$f" .yaml)
    # Prepend id line (works on macOS BSD sed and GNU sed)
    printf "id: %s\n" "$name" | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  ```
- After migration, run `build.sh` to verify all rules compile
- Note: the first SessionStart after migration will trigger auto-build (checksum changed) — this is expected

### Note
This is a one-time user action, not automated by the plugin. The build error message guides users to add the `id` field.

---

## Diagrams

- [Architecture](diagrams/architecture.mmd)
- [Execution Flow](diagrams/flow.mmd)

---

## Review Summary

### Critical — Resolved
- [codex][claude-arch] `./hooksmith` must use `exec bash` not `source` → Fixed: dispatcher uses `exec bash`
- [codex][claude-arch] `run.sh` lookup assumes id==filename but never stated → Fixed: S1 now requires id==filename, build validates
- [codex] `hooksmith list` not reachable via `./hooksmith` → Fixed: dispatcher routes `list` subcommand
- [claude-arch] `run.sh` must replicate fail-wrapper.sh stderr suppression + capture model → Fixed: S3 specifies capture-then-emit with `2>/dev/null`
- [claude-arch] Uniqueness check scope unclear → Fixed: T2 specifies post-merge tmpdir loop

### Suggestions — Resolved
- [codex][claude-arch] Runtime behavior for malformed YAML unspecified → Fixed: S3 edge cases include parse errors (fail-open)
- [codex] `--scope` flag inconsistent between design/spec → Fixed: S4 includes `--scope`
- [codex] Prompt traceability via JSON comments infeasible → Fixed: removed from design, traceability via list.sh only
- [claude-arch] Migration script BSD sed bug → Fixed: S8 uses portable `printf | cat` approach
- [claude-arch] Matcher column missing from list table → Fixed: S4 table includes MATCHER column

### Suggestions — Acknowledged (no spec change needed)
- [claude-arch] Build-time script existence check preserved → Confirmed in S3 edge cases + T4
- [claude-arch] Auto-rebuild after migration expected → Noted in T9

### Nitpicks — Acknowledged
- [claude-arch] Entry point file has no `.sh` extension — intentional (CLI-style naming)
- [claude-arch] T3 verification criterion added
