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
  engine_rule test-content      PreToolUse regex  "matcher: Write" "field: content"    "pattern: 'export'"  "result: warn"
  engine_rule test-userprompt   UserPromptSubmit regex             "field: user_prompt" "pattern: 'feature'" "result: warn"

  out=$(engine_run test-bash-match   "$FIXTURES/bash-safe.json")
  assert_denied   "command field: 'ls' matches bash-safe.json"          "$out"

  out=$(engine_run test-bash-nomatch "$FIXTURES/bash-safe.json")
  assert_allowed  "command field: 'danger' does not match ls command"   "$out"

  out=$(engine_run test-filepath     "$FIXTURES/write-safe.json")
  assert_denied   "file_path field: .ts extension matches write-safe"   "$out"

  out=$(engine_run test-filepath-env "$FIXTURES/write-safe.json")
  assert_allowed  "file_path field: .env does not match .ts path"       "$out"

  out=$(engine_run test-content      "$FIXTURES/write-safe.json")
  assert_contains "content field: 'export' triggers systemMessage"      "$out" "systemMessage"

  out=$(engine_run test-userprompt   "$FIXTURES/userprompt-in-worktree.json")
  assert_contains "user_prompt field: 'feature' triggers systemMessage" "$out" "systemMessage"

  engine_teardown
}

test_engine_regex_actions() {
  echo "engine: regex action types"
  local out

  engine_setup

  # All rules match 'ls' from bash-safe.json, differ only in action
  engine_rule test-deny    PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: deny"
  engine_rule test-ask     PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: ask"
  engine_rule test-warn    PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: warn"
  engine_rule test-context PreToolUse regex "matcher: Bash" "field: command" "pattern: 'ls'" "result: context"
  engine_rule test-nomatch PreToolUse regex "matcher: Bash" "field: command" "pattern: 'nomatch'" "result: deny"

  out=$(engine_run test-deny    "$FIXTURES/bash-safe.json")
  assert_denied   "deny:    permissionDecision=deny"    "$out"

  out=$(engine_run test-ask     "$FIXTURES/bash-safe.json")
  assert_asks     "ask:     permissionDecision=ask"     "$out"

  out=$(engine_run test-warn    "$FIXTURES/bash-safe.json")
  assert_contains "warn:    systemMessage present"      "$out" "systemMessage"

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
print_summary
