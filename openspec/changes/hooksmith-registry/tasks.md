# Tasks: hooksmith-registry

## Phase 1: Foundation (parser extraction + id validation)

### T1: Extract shared parser into `lib/parse.sh`
- Move `parse_yaml()` and `get_val()` from `build.sh` into `lib/parse.sh`
- Update `build.sh` to source `lib/parse.sh`
- Verify: `build.sh` produces identical hooks.json output

### T2: Add `id` validation to `build.sh`
- Add `id` to required fields check in `validate_rule()`
- Add format validation: `^[a-z0-9-]+$`
- Add id-filename match validation: `id` must equal `basename(file, .yaml)`
- Add uniqueness check: track seen ids in post-merge tmpdir loop, error on duplicate (catches cross-scope same-id different-filename)
- Verify: build fails on missing/invalid/mismatched/duplicate ids

## Phase 2: Runner

### T3: Create `./hooksmith` dispatcher + `lib/run.sh` runner
- Create `./hooksmith` as dispatcher at plugin root using `exec bash` (not `source`):
  - `hooksmith run <id>` → exec lib/run.sh
  - `hooksmith list [--json] [--scope ...]` → exec lib/list.sh
  - Unknown subcommand → stderr error, exit 1
- Create `lib/run.sh` with full runner logic:
  - Source `lib/parse.sh`
  - Accept `<id>` as argument
  - Look up rule by `<id>.yaml`: project scope first, then user scope
  - Parse YAML, dispatch by mechanism (regex → regex-match.sh, script → user script)
  - Use capture-then-emit stdout model: `output=$(...  2>/dev/null)`, emit only on success
  - Suppress stderr from underlying scripts (matching fail-wrapper.sh behavior)
  - Handle fail_mode (open → exit 0, closed → deny JSON)
  - On lookup/parse errors: fail-open (exit 0, stderr warning)
  - Set HOOKLIB env var for script rules
- Verify: `bash hooksmith <valid-id>` dispatches correctly with stdin passthrough; `bash hooksmith <unknown-id>` exits 0 with stderr warning

### T4: Update `build.sh` to emit `hooksmith run <id>` commands
- Change `generate_entry()`: regex and script mechanisms emit `bash ${CLAUDE_PLUGIN_ROOT}/hooksmith run <id>`
- Prompt mechanism unchanged (direct JSON)
- `async` flag still added to hook entry
- Build-time script existence check in `validate_rule()` preserved (unchanged)
- Verify: rebuilt hooks.json uses hooksmith commands

## Phase 3: List + convert

### T5: Create `lib/list.sh` — registry listing
- Source `lib/parse.sh`
- Read rules from both scopes
- Display table with: id, event, matcher, mechanism, result, scope, enabled
- Support `--json` flag for structured output
- Support `--scope user|project|all` flag (default: all)
- Sort by event then id
- Show `[disabled]` marker for disabled rules, `[error]` for parse errors

### T6: Update `lib/convert.sh` to generate `id` field
- Derive id from script filename (e.g., `bash-safety-guard.sh` → `bash-safety-guard`)
- For rules without a script: derive from event-matcher lowercased with hyphens
- Insert `id:` as first line in generated YAML
- Validate generated id format matches `^[a-z0-9-]+$`

## Phase 4: Docs + examples + migration

### T7: Add `id` to all example YAML files
- Update `examples/*.yaml` with appropriate id values
- Update `skills/hooksmith/examples/*.yaml`

### T8: Update documentation
- `skills/hooksmith/SKILL.md`: add id field docs, list command section, hooksmith dispatcher usage
- `skills/hooksmith/references/field-reference.md`: add id field reference (required, format, filename constraint)
- Update all YAML examples in docs to include id

### T9: Migrate existing user rules
- Add `id` field (derived from filename) to all 19 YAML rules in `~/.config/hooksmith/rules/`
- Rebuild hooks.json to verify
- Note: first SessionStart after migration triggers auto-rebuild (expected)
