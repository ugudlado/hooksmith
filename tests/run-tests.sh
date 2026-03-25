#!/bin/bash
# run-tests.sh — Hooksmith test runner
# Usage: bash tests/run-tests.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"
HOOKSMITH="${REPO_ROOT}/hooksmith"

# Override rule dirs to user rules for all tests
export USER_RULES_DIR="${HOME}/.config/hooksmith/rules"
export PROJECT_RULES_DIR="/dev/null"  # disable project scope in tests

# ── Test state ──
PASS=0
FAIL=0
ERRORS=()

# ── Helpers ──

# Run a hook via hooksmith run, piping a fixture file as stdin
# Usage: run_hook <id> <fixture_file>
# Returns: stdout of the hook
run_hook() {
  local id="$1" fixture="$2"
  bash "$HOOKSMITH" run "$id" < "$fixture"
}

# ── TODO: Implement assertions below ──
#
# These are the core of the test framework. Each should:
#   - Print "  PASS: <label>" or "  FAIL: <label> — <reason>"
#   - Increment $PASS or $FAIL
#   - Append to $ERRORS on failure
#
# Constraints to consider:
#   - Hook output is JSON (use jq to extract fields)
#   - A passing hook may output nothing (exit 0, empty stdout)
#   - A denying hook outputs JSON with permissionDecision: "deny"
#   - An asking hook outputs JSON with permissionDecision: "ask"
#   - assert_denied and assert_allowed are the most-used assertions

_pass() {
  echo "  PASS: $1"
  PASS=$(( PASS + 1 ))
}

_fail() {
  echo "  FAIL: $1 — $2"
  FAIL=$(( FAIL + 1 ))
  ERRORS+=("$1 — $2")
}

_decision() {
  echo "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

assert_denied() {
  local label="$1" output="$2"
  local decision; decision=$(_decision "$output")
  if [[ "$decision" == "deny" ]]; then
    _pass "$label"
  else
    _fail "$label" "expected deny, got '${decision:-empty}'"
  fi
}

assert_allowed() {
  local label="$1" output="$2"
  local decision; decision=$(_decision "$output")
  if [[ "$decision" == "deny" || "$decision" == "ask" ]]; then
    _fail "$label" "expected allow, got '$decision'"
  else
    _pass "$label"
  fi
}

assert_asks() {
  local label="$1" output="$2"
  local decision; decision=$(_decision "$output")
  if [[ "$decision" == "ask" ]]; then
    _pass "$label"
  else
    _fail "$label" "expected ask, got '${decision:-empty}'"
  fi
}

assert_contains() {
  local label="$1" output="$2" pattern="$3"
  if echo "$output" | grep -q "$pattern"; then
    _pass "$label"
  else
    _fail "$label" "expected output to contain '$pattern'"
  fi
}

assert_exit_ok() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    _pass "$label"
  else
    _fail "$label" "expected exit 0, got $exit_code"
  fi
}

assert_context() {
  local label="$1" output="$2" key="${3:-additionalContext}"
  local val; val=$(echo "$output" | jq -r ".hookSpecificOutput.${key} // empty" 2>/dev/null)
  if [[ -n "$val" ]]; then
    _pass "$label"
  else
    _fail "$label" "expected hookSpecificOutput.${key} to be present"
  fi
}

# Run a hook in a worktree context by temporarily changing CWD
run_hook_in_worktree() {
  local id="$1" fixture="$2" worktree="$3"
  (cd "$worktree" && bash "$HOOKSMITH" run "$id" < "$fixture")
}

# ── Test suites ──

test_cli() {
  echo "CLI"

  local out exit_code

  out=$(bash "$HOOKSMITH" list 2>/dev/null); exit_code=$?
  assert_exit_ok "list exits 0" "$exit_code"
  assert_contains "list shows rules" "$out" "HOOKSMITH RULES"

  out=$(bash "$HOOKSMITH" list --json 2>/dev/null); exit_code=$?
  assert_exit_ok "list --json exits 0" "$exit_code"
  assert_contains "list --json is valid json" "$(echo "$out" | jq -e . 2>/dev/null && echo valid)" "valid"

  out=$(bash "$HOOKSMITH" run nonexistent-id < /dev/null 2>/dev/null); exit_code=$?
  assert_exit_ok "run unknown id exits 0 (fail-open)" "$exit_code"

  out=$(bash "$HOOKSMITH" 2>&1 || true)
  assert_contains "no args shows usage" "$out" "Commands:"
}

test_bash_safety_guard() {
  echo "bash-safety-guard"
  local out

  out=$(run_hook bash-safety-guard "$FIXTURES/bash-git-push.json" 2>/dev/null)
  assert_denied "git push is denied" "$out"

  out=$(run_hook bash-safety-guard "$FIXTURES/bash-safe.json" 2>/dev/null)
  assert_allowed "ls -la is allowed" "$out"
}

test_protected_files() {
  echo "protected-files"
  local out

  out=$(run_hook protected-files "$FIXTURES/write-lockfile.json" 2>/dev/null)
  assert_asks "pnpm-lock.yaml triggers ask" "$out"

  out=$(run_hook protected-files "$FIXTURES/write-plugin-json.json" 2>/dev/null)
  assert_asks "plugin.json triggers ask" "$out"

  out=$(run_hook protected-files "$FIXTURES/write-safe.json" 2>/dev/null)
  assert_allowed "normal file is allowed" "$out"
}

test_deny_behaviors() {
  echo "deny behaviors"
  local out

  # bash-safety-guard — various deny patterns
  out=$(run_hook bash-safety-guard "$FIXTURES/bash-git-push.json" 2>/dev/null)
  assert_denied "git push denied" "$out"

  # process-kill-guard — killing unregistered PID
  out=$(run_hook process-kill-guard "$FIXTURES/bash-kill-unregistered.json" 2>/dev/null)
  assert_denied "kill unregistered PID denied" "$out"

  # worktree-boundary — write outside active worktree
  local fake_wt; fake_wt=$(mktemp -d "${TMPDIR:-/tmp}/feature_worktrees/MY-FEAT.XXXX" 2>/dev/null || mktemp -d)
  mkdir -p "$fake_wt"
  out=$(cd "$fake_wt" && bash "$HOOKSMITH" run worktree-boundary < "$FIXTURES/write-outside-worktree.json" 2>/dev/null)
  assert_denied "write outside worktree denied" "$out"
  rm -rf "$fake_wt"
}

test_ask_behaviors() {
  echo "ask behaviors"
  local out

  out=$(run_hook protected-files "$FIXTURES/write-lockfile.json" 2>/dev/null)
  assert_asks "pnpm-lock.yaml asks" "$out"

  out=$(run_hook protected-files "$FIXTURES/write-plugin-json.json" 2>/dev/null)
  assert_asks "plugin.json asks" "$out"
}

test_allow_behaviors() {
  echo "allow behaviors"
  local out

  # Safe bash — no deny, no ask
  out=$(run_hook bash-safety-guard "$FIXTURES/bash-safe.json" 2>/dev/null)
  assert_allowed "safe bash command allowed" "$out"

  # Normal file write — no deny, no ask
  out=$(run_hook protected-files "$FIXTURES/write-safe.json" 2>/dev/null)
  assert_allowed "safe file write allowed" "$out"

  # worktree-boundary — write inside worktree is allowed
  local fake_wt; fake_wt=$(mktemp -d)
  mkdir -p "$fake_wt"
  out=$(cd "$fake_wt" && bash "$HOOKSMITH" run worktree-boundary < "$FIXTURES/write-safe.json" 2>/dev/null)
  assert_allowed "write outside worktree context (no worktree) allowed" "$out"
  rm -rf "$fake_wt"

  # task-gate — context hook emits additionalContext, not a denial
  out=$(run_hook task-gate "$FIXTURES/userprompt-in-worktree.json" 2>/dev/null)
  assert_allowed "task-gate allows (not on feature branch)" "$out"
}

# ── Summary ──

print_summary() {
  echo ""
  echo "────────────────────────────────────────"
  local total=$(( PASS + FAIL ))
  echo "Results: ${PASS}/${total} passed"
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
      echo "  ✗ $err"
    done
    exit 1
  else
    echo "All tests passed."
  fi
}

# ── Engine tests (isolated temp rule dirs) ──

engine_setup() {
  ENGINE_DIR=$(mktemp -d)
  _PRIOR_TRAP=$(trap -p EXIT)
  trap 'rm -rf "$ENGINE_DIR"' EXIT
}

engine_teardown() {
  rm -rf "$ENGINE_DIR"
  eval "${_PRIOR_TRAP:-trap - EXIT}"
}

engine_rule() {
  local id="$1" event="$2" mechanism="$3"; shift 3
  printf 'id: %s\nevent: %s\nmechanism: %s\n' "$id" "$event" "$mechanism" > "$ENGINE_DIR/${id}.yaml"
  local kv
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$ENGINE_DIR/${id}.yaml"
  done
}

engine_run() {
  USER_RULES_DIR="$ENGINE_DIR" PROJECT_RULES_DIR="/dev/null" \
    bash "$HOOKSMITH" run "$1" < "$2" 2>/dev/null
}

# Returns two sections separated by a marker: stderr errors then hooks.json content
engine_build() {
  local output_file="$ENGINE_DIR/hooks.json"
  local errors
  errors=$(USER_RULES_DIR="$ENGINE_DIR" PROJECT_RULES_DIR="/dev/null" \
    OUTPUT="$output_file" bash "${REPO_ROOT}/build.sh" 2>&1 >/dev/null)
  echo "$errors"
  [[ -f "$output_file" ]] && cat "$output_file"
}

test_engine_regex_fields() {
  echo "engine: regex field routing"
  local out

  engine_setup

  engine_rule test-bash-match   PreToolUse regex  "matcher: Bash"  "field: command"    "pattern: 'ls'"      "result: deny"
  engine_rule test-bash-nomatch PreToolUse regex  "matcher: Bash"  "field: command"    "pattern: 'danger'"  "result: deny"
  engine_rule test-filepath     PreToolUse regex  "matcher: Write" "field: file_path"  "pattern: '\.ts$'"   "result: deny"
  engine_rule test-filepath-env PreToolUse regex  "matcher: Write" "field: file_path"  "pattern: '\.env$'"  "result: deny"
  engine_rule test-content      PreToolUse regex  "matcher: Write" "field: content"    "pattern: 'export'"  "result: context"
  engine_rule test-userprompt   UserPromptSubmit regex             "field: user_prompt" "pattern: 'feature'" "result: context"

  out=$(engine_run test-bash-match   "$FIXTURES/bash-safe.json")
  assert_denied   "command field: 'ls' matches bash-safe.json"          "$out"

  out=$(engine_run test-bash-nomatch "$FIXTURES/bash-safe.json")
  assert_allowed  "command field: 'danger' does not match ls command"   "$out"

  out=$(engine_run test-filepath     "$FIXTURES/write-safe.json")
  assert_denied   "file_path field: .ts extension matches write-safe"   "$out"

  out=$(engine_run test-filepath-env "$FIXTURES/write-safe.json")
  assert_allowed  "file_path field: .env does not match .ts path"       "$out"

  out=$(engine_run test-content      "$FIXTURES/write-safe.json")
  assert_contains "content field: 'export' triggers context"             "$out" "additionalContext"

  out=$(engine_run test-userprompt   "$FIXTURES/userprompt-in-worktree.json")
  assert_contains "user_prompt field: 'feature' triggers context"        "$out" "additionalContext"

  engine_teardown
}

test_engine_regex_actions() {
  echo "engine: regex action types"
  local out

  engine_setup

  # All rules match 'ls' from bash-safe.json, differ only in action
  engine_rule test-deny    PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: deny"
  engine_rule test-ask     PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: ask"
  engine_rule test-warn    PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: context"
  engine_rule test-context PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: context"
  engine_rule test-nomatch PreToolUse regex "matcher: Bash" "field: command" "pattern: 'nomatch'" "result: deny"

  out=$(engine_run test-deny    "$FIXTURES/bash-safe.json")
  assert_denied   "deny:    permissionDecision=deny"    "$out"

  out=$(engine_run test-ask     "$FIXTURES/bash-safe.json")
  assert_asks     "ask:     permissionDecision=ask"     "$out"

  out=$(engine_run test-warn    "$FIXTURES/bash-safe.json")
  assert_contains "context: additionalContext present"  "$out" "additionalContext"

  out=$(engine_run test-context "$FIXTURES/bash-safe.json")
  assert_context  "context: additionalContext present"  "$out"

  out=$(engine_run test-nomatch "$FIXTURES/bash-safe.json")
  assert_allowed  "no match: empty output (pass-through)" "$out"

  engine_teardown
}

test_engine_build() {
  echo "engine: build"
  local out

  engine_setup
  engine_rule build-test-rule PreToolUse regex "matcher: Bash" "field: command" "pattern: 'danger'" "result: deny"
  out=$(engine_build)
  assert_contains "valid rule: hooks key present"        "$out" '"hooks"'
  assert_contains "valid rule: PreToolUse event present" "$out" '"PreToolUse"'
  assert_contains "valid rule: runner command embedded"  "$out" "hooksmith run build-test-rule"
  engine_teardown

  engine_setup
  engine_rule bad-rule PreToolUse regex "matcher: Bash" "field: command" "pattern: 'x'"
  out=$(engine_build)
  assert_contains "missing result: build errors"         "$out" "ERROR"
  engine_teardown

  engine_setup
  engine_rule bad-event-rule FakeEvent regex "field: command" "pattern: 'x'" "result: deny"
  out=$(engine_build)
  assert_contains "unknown event: build errors"          "$out" "ERROR"
  engine_teardown
}

test_engine_disabled() {
  echo "engine: disabled rules"
  local out stderr_out

  engine_setup

  engine_rule test-disabled PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: deny" "enabled: false"

  # Capture stderr separately to confirm rule was found but skipped (not missing)
  stderr_out=$(USER_RULES_DIR="$ENGINE_DIR" PROJECT_RULES_DIR="/dev/null" \
    bash "$HOOKSMITH" run test-disabled < "$FIXTURES/bash-safe.json" 2>&1 >/dev/null)
  assert_contains "disabled rule: rule found and skipped" "$stderr_out" "disabled"

  out=$(engine_run test-disabled "$FIXTURES/bash-safe.json")
  assert_allowed  "disabled rule: no deny/ask emitted" "$out"

  engine_teardown
}

# ── Compact format tests ──

compact_setup() {
  COMPACT_DIR=$(mktemp -d)
  trap 'rm -rf "$COMPACT_DIR"' EXIT
}

compact_teardown() {
  rm -rf "$COMPACT_DIR"
  trap - EXIT
}

# Write a compact hooksmith.yaml and build it
compact_build() {
  local yaml_content="$1"
  local output_file="$COMPACT_DIR/hooks.json"
  local rules_dir="$COMPACT_DIR/empty_rules"
  mkdir -p "$rules_dir"

  # Write compact file where build.sh looks for it (.hooksmith/hooksmith.yaml relative to CWD)
  mkdir -p "$COMPACT_DIR/.hooksmith"
  printf '%s\n' "$yaml_content" > "$COMPACT_DIR/.hooksmith/hooksmith.yaml"

  # Build from COMPACT_DIR so .hooksmith/hooksmith.yaml is found
  (cd "$COMPACT_DIR" && \
    USER_RULES_DIR="$rules_dir" PROJECT_RULES_DIR="$COMPACT_DIR/.hooksmith/rules" \
    OUTPUT="$output_file" bash "${REPO_ROOT}/build.sh" 2>&1)

  [[ -f "$output_file" ]] && cat "$output_file"
}

# Extract hooks.json from compact_build output (skip non-JSON status lines)
compact_json() {
  local output="$1"
  # The hooks.json file is already written; extract JSON using jq
  echo "$output" | jq -s 'map(select(type == "object" and has("hooks"))) | .[0] // empty' 2>/dev/null
}

# Run a baked compact hook by piping fixture through the generated command
compact_run() {
  local hooks_json_file="$1" fixture="$2" event="$3" matcher="${4:-}"

  if [[ ! -f "$hooks_json_file" ]]; then
    echo ""; return 0
  fi

  # Extract the command for the given event+matcher
  local cmd
  if [[ -n "$matcher" ]]; then
    cmd=$(jq -r --arg e "$event" --arg m "$matcher" \
      '.hooks[$e][] | select(.matcher == $m) | .hooks[0].command' "$hooks_json_file")
  else
    cmd=$(jq -r --arg e "$event" \
      '.hooks[$e][] | select(.matcher == null or .matcher == "") | .hooks[0].command' "$hooks_json_file")
  fi

  if [[ -z "$cmd" || "$cmd" == "null" ]]; then
    echo ""
    return 0
  fi

  # Replace ${CLAUDE_PLUGIN_ROOT} with actual path
  cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT}"

  # Run the command with fixture as stdin
  bash -c "$cmd" < "$fixture" 2>/dev/null
}

test_compact_basic() {
  echo "compact: basic rules"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Bash
    match: command =~ git\s+push
    deny: No pushing allowed'

  local out
  out=$(compact_build "$yaml")
  local hf="$COMPACT_DIR/hooks.json"
  assert_contains "compact build: generated" "$out" "Generated"

  local content
  content=$(cat "$hf" 2>/dev/null)
  assert_contains "compact build: hooks key present" "$content" '"hooks"'
  assert_contains "compact build: PreToolUse present" "$content" '"PreToolUse"'
  assert_contains "compact build: match.sh baked" "$content" "match.sh"

  # Run against git push fixture — should deny
  local result
  result=$(compact_run "$hf" "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "compact: git push denied" "$result"

  # Run against safe fixture — should allow
  result=$(compact_run "$hf" "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "compact: ls -la allowed" "$result"

  compact_teardown
}

test_compact_actions() {
  echo "compact: action types"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Bash
    match: command =~ danger
    deny: Blocked

  - on: PreToolUse Bash
    match: command =~ askme
    ask: Please confirm

  - on: PreToolUse Bash
    match: command =~ careful
    context: Be careful'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local hook_count
  hook_count=$(jq '.hooks.PreToolUse[0].hooks | length' "$hf")
  if [[ "$hook_count" == "3" ]]; then
    _pass "compact: 3 hooks compiled"
  else
    _fail "compact: 3 hooks compiled" "expected 3, got $hook_count"
  fi

  compact_teardown
}

test_compact_prompt() {
  echo "compact: prompt mechanism"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Write
    prompt: Check if this file write is safe
    context: AI safety check'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local hook_type
  hook_type=$(jq -r '.hooks.PreToolUse[0].hooks[0].type' "$hf")
  if [[ "$hook_type" == "prompt" ]]; then
    _pass "compact prompt: type is prompt"
  else
    _fail "compact prompt: type is prompt" "got '$hook_type'"
  fi

  local prompt_text
  prompt_text=$(jq -r '.hooks.PreToolUse[0].hooks[0].prompt' "$hf")
  assert_contains "compact prompt: prompt text present" "$prompt_text" "safe"

  compact_teardown
}

test_compact_disabled() {
  echo "compact: disabled rules"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Bash
    match: command =~ danger
    deny: Blocked
    enabled: false

  - on: PreToolUse Bash
    match: command =~ other
    deny: Also blocked'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local hook_count
  hook_count=$(jq '.hooks.PreToolUse[0].hooks | length' "$hf")
  if [[ "$hook_count" == "1" ]]; then
    _pass "compact disabled: skipped disabled rule"
  else
    _fail "compact disabled: skipped disabled rule" "expected 1 hook, got $hook_count"
  fi

  compact_teardown
}

test_compact_validation() {
  echo "compact: validation errors"
  compact_setup

  # Missing action
  local yaml='rules:
  - on: PreToolUse Bash
    match: command =~ danger'
  local out
  out=$(compact_build "$yaml" 2>&1)
  assert_contains "compact: missing action error" "$out" "ERROR"

  # Bad event
  yaml='rules:
  - on: FakeEvent Bash
    match: command =~ danger
    deny: Blocked'
  out=$(compact_build "$yaml" 2>&1)
  assert_contains "compact: bad event error" "$out" "ERROR"

  # ask on wrong event
  yaml='rules:
  - on: SessionStart
    match: command =~ danger
    ask: Should not work'
  out=$(compact_build "$yaml" 2>&1)
  assert_contains "compact: ask on SessionStart error" "$out" "ERROR"

  compact_teardown
}

test_compact_run_inline_deny() {
  echo "compact: run inline (deny)"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Bash
    run: |
      cmd=$(get_field command)
      if [[ "$cmd" =~ ^sudo ]]; then
        echo "Root access not allowed"
      elif [[ "$cmd" =~ git.+push ]]; then
        echo "Direct push not permitted"
      fi
    deny: true'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local result
  result=$(compact_run "$hf" "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "run-inline: git push denied" "$result"
  assert_contains "run-inline: reason in output" "$result" "Direct push not permitted"

  result=$(compact_run "$hf" "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "run-inline: safe command allowed" "$result"

  compact_teardown
}

test_compact_run_inline_ask() {
  echo "compact: run inline (ask)"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Write
    run: |
      path=$(get_field file_path)
      if [[ "$path" =~ \.(lock|lockb)$ ]] || [[ "$path" =~ lock\.yaml$ ]]; then
        echo "Lock file modification: $path"
      fi
    ask: true'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local result
  result=$(compact_run "$hf" "$FIXTURES/write-lockfile.json" "PreToolUse" "Write")
  assert_asks "run-inline-ask: lock file triggers ask" "$result"

  result=$(compact_run "$hf" "$FIXTURES/write-safe.json" "PreToolUse" "Write")
  assert_allowed "run-inline-ask: normal file allowed" "$result"

  compact_teardown
}

test_compact_run_dynamic_reason() {
  echo "compact: run provides dynamic reason"
  compact_setup

  local yaml='rules:
  - on: PreToolUse Bash
    run: |
      cmd=$(get_field command)
      echo "Command was: $cmd"
    context: true'

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local result
  result=$(compact_run "$hf" "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_contains "run-reason: dynamic reason includes command" "$result" "ls -la"

  compact_teardown
}

test_compact_run_file() {
  echo "compact: run external file"
  compact_setup

  # Create an external script that follows the same contract
  local script_file="$COMPACT_DIR/my-guard.sh"
  cat > "$script_file" << 'SCRIPT'
source "$HOOKLIB"
read_input
cmd=$(get_field command)
[[ "$cmd" =~ git.+push ]] && echo "Push blocked by external guard"
SCRIPT

  local yaml="rules:
  - on: PreToolUse Bash
    run: $script_file
    deny: true"

  compact_build "$yaml" >/dev/null 2>&1
  local hf="$COMPACT_DIR/hooks.json"

  local result
  result=$(compact_run "$hf" "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "run-file: git push denied" "$result"
  assert_contains "run-file: reason from external script" "$result" "Push blocked by external guard"

  result=$(compact_run "$hf" "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "run-file: safe command allowed" "$result"

  compact_teardown
}

# ── Eval (no-build) tests ──

eval_setup() {
  EVAL_DIR=$(mktemp -d)
  mkdir -p "$EVAL_DIR/.hooksmith"
  trap 'rm -rf "$EVAL_DIR"' EXIT
}

eval_teardown() {
  rm -rf "$EVAL_DIR"
  trap - EXIT
}

eval_run() {
  local fixture="$1" event="$2" tool="${3:-}"
  local context
  context=$(cat "$fixture")
  # Inject hook_event_name and tool_name into the fixture
  context=$(echo "$context" | jq --arg e "$event" '. + {hook_event_name:$e}')
  if [[ -n "$tool" ]]; then
    context=$(echo "$context" | jq --arg t "$tool" '. + {tool_name:$t}')
  fi
  echo "$context" | (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null)
}

test_eval_match() {
  echo "eval: match rules (no build)"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: block-push
    on: PreToolUse Bash
    match: command =~ git\s+push
    deny: No pushing allowed
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "eval-match: git push denied" "$result"

  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "eval-match: safe command allowed" "$result"

  eval_teardown
}

test_eval_run_inline() {
  echo "eval: run inline (no build)"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: sudo-guard
    on: PreToolUse Bash
    run: |
      cmd=$(get_field command)
      [[ "$cmd" =~ ^sudo ]] && echo "Root access not allowed"
    deny: true
YAML

  local result
  # Create a sudo fixture
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo rm -rf /"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_denied "eval-run: sudo denied" "$result"
  assert_contains "eval-run: dynamic reason" "$result" "Root access not allowed"

  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "eval-run: safe command allowed" "$result"

  eval_teardown
}

test_eval_matcher_routing() {
  echo "eval: matcher routing (no build)"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: bash-only
    on: PreToolUse Bash
    match: command =~ danger
    deny: Bash danger blocked

  - name: write-only
    on: PreToolUse Write
    match: file_path =~ \.env$
    ask: Sensitive file
YAML

  # Bash rule should not fire for Write tool
  local result
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/app.ts"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_allowed "eval-routing: Write tool doesn't trigger Bash rule" "$result"

  # Write rule should fire for .env
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".env"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_asks "eval-routing: .env triggers Write ask" "$result"

  eval_teardown
}

test_eval_disabled() {
  echo "eval: disabled rules (no build)"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: disabled-rule
    on: PreToolUse Bash
    match: command =~ ls
    deny: Should not fire
    enabled: false

  - name: active-rule
    on: PreToolUse Bash
    match: command =~ git
    deny: Git blocked
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "eval-disabled: disabled rule doesn't fire" "$result"

  eval_teardown
}

test_eval_readable_names() {
  echo "eval: readable names in debug output"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: my-custom-guard
    on: PreToolUse Bash
    match: command =~ danger
    deny: Blocked
YAML

  local stderr_out
  stderr_out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"danger zone"}}' | \
    (cd "$EVAL_DIR" && HOOKSMITH_DEBUG=1 bash "$HOOKSMITH" eval 2>&1 >/dev/null))
  assert_contains "eval-names: rule name in debug" "$stderr_out" "my-custom-guard"

  eval_teardown
}

# ── Run ──

echo "Hooksmith Test Suite"
echo "════════════════════════════════════════"
echo ""
test_cli
echo ""
test_deny_behaviors
echo ""
test_ask_behaviors
echo ""
test_allow_behaviors
echo ""
echo "engine"
echo "──────"
test_engine_regex_fields
echo ""
test_engine_regex_actions
echo ""
test_engine_build
echo ""
test_engine_disabled
echo ""
echo "compact"
echo "───────"
test_compact_basic
echo ""
test_compact_actions
echo ""
test_compact_prompt
echo ""
test_compact_disabled
echo ""
test_compact_validation
echo ""
test_compact_run_inline_deny
echo ""
test_compact_run_inline_ask
echo ""
test_compact_run_dynamic_reason
echo ""
test_compact_run_file
echo ""
echo "eval (no-build)"
echo "────────────────"
test_eval_match
echo ""
test_eval_run_inline
echo ""
test_eval_matcher_routing
echo ""
test_eval_disabled
echo ""
test_eval_readable_names
echo ""
print_summary
