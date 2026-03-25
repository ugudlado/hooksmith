#!/bin/bash
# run-tests.sh — Hooksmith test runner
# Usage: bash tests/run-tests.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"
HOOKSMITH="${REPO_ROOT}/hooksmith"

# ── Test state ──
PASS=0
FAIL=0
ERRORS=()

# ── Helpers ──

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
  if [[ "$decision" == "deny" ]]; then _pass "$label"
  else _fail "$label" "expected deny, got '${decision:-empty}'"; fi
}

assert_allowed() {
  local label="$1" output="$2"
  local decision; decision=$(_decision "$output")
  if [[ "$decision" == "deny" || "$decision" == "ask" ]]; then
    _fail "$label" "expected allow, got '$decision'"
  else _pass "$label"; fi
}

assert_asks() {
  local label="$1" output="$2"
  local decision; decision=$(_decision "$output")
  if [[ "$decision" == "ask" ]]; then _pass "$label"
  else _fail "$label" "expected ask, got '${decision:-empty}'"; fi
}

assert_contains() {
  local label="$1" output="$2" pattern="$3"
  if echo "$output" | grep -q "$pattern"; then _pass "$label"
  else _fail "$label" "expected output to contain '$pattern'"; fi
}

assert_exit_ok() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then _pass "$label"
  else _fail "$label" "expected exit 0, got $exit_code"; fi
}

assert_context() {
  local label="$1" output="$2"
  local val; val=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [[ -n "$val" ]]; then _pass "$label"
  else _fail "$label" "expected additionalContext to be present"; fi
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

# ── Eval test infrastructure ──

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
  context=$(echo "$context" | jq --arg e "$event" '. + {hook_event_name:$e}')
  if [[ -n "$tool" ]]; then
    context=$(echo "$context" | jq --arg t "$tool" '. + {tool_name:$t}')
  fi
  echo "$context" | (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null)
}

# ── CLI tests ──

test_cli() {
  echo "CLI"

  local out exit_code

  out=$(bash "$HOOKSMITH" 2>&1 || true)
  assert_contains "no args shows usage" "$out" "Commands:"

  out=$(bash "$HOOKSMITH" init --help 2>/dev/null); exit_code=$?
  assert_exit_ok "init --help exits 0" "$exit_code"
  assert_contains "init --help shows usage" "$out" "hooksmith init"
}

# ── Match (regex) tests ──

test_eval_match() {
  echo "match rules"
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
  assert_denied "git push denied" "$result"
  assert_contains "reason in output" "$result" "No pushing allowed"

  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "safe command allowed" "$result"

  eval_teardown
}

test_eval_match_actions() {
  echo "match actions (deny/ask/context)"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: deny-test
    on: PreToolUse Bash
    match: command =~ ls
    deny: Denied
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_denied "deny action works" "$result"
  eval_teardown

  eval_setup
  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: ask-test
    on: PreToolUse Bash
    match: command =~ ls
    ask: Please confirm
YAML
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_asks "ask action works" "$result"
  eval_teardown

  eval_setup
  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: context-test
    on: PreToolUse Bash
    match: command =~ ls
    context: Additional info
YAML
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_context "context action works" "$result"
  eval_teardown
}

test_eval_match_fields() {
  echo "match field routing"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: file-path-check
    on: PreToolUse Write
    match: file_path =~ \.ts$
    deny: TypeScript file

  - name: content-check
    on: PreToolUse Write
    match: content =~ export
    context: Has exports
YAML

  local result
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/app.ts","content":"export default"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_denied "file_path field match works" "$result"

  eval_teardown
}

# ── Run (script) tests ──

test_eval_run_inline() {
  echo "run inline scripts"
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
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo rm -rf /"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_denied "sudo denied" "$result"
  assert_contains "dynamic reason" "$result" "Root access not allowed"

  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "safe command allowed" "$result"

  eval_teardown
}

test_eval_run_file() {
  echo "run external files"
  eval_setup

  cat > "$EVAL_DIR/guard.sh" << 'SCRIPT'
source "$HOOKLIB"
read_input
cmd=$(get_field command)
[[ "$cmd" =~ git.+push ]] && echo "Push blocked by guard"
SCRIPT

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << YAML
rules:
  - name: external-guard
    on: PreToolUse Bash
    run: $EVAL_DIR/guard.sh
    deny: true
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "external file deny works" "$result"
  assert_contains "external file reason" "$result" "Push blocked by guard"

  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "external file pass-through works" "$result"

  eval_teardown
}

# ── Matcher routing tests ──

test_eval_routing() {
  echo "matcher routing"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: bash-only
    on: PreToolUse Bash
    match: command =~ danger
    deny: Bash blocked

  - name: write-only
    on: PreToolUse Write
    match: file_path =~ \.env$
    ask: Sensitive file
YAML

  local result
  # Write tool should not trigger Bash rule
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/app.ts"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_allowed "Write tool doesn't trigger Bash rule" "$result"

  # .env should trigger Write rule
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".env"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_asks ".env triggers Write ask" "$result"

  # Bash|Write pipe matcher
  eval_teardown
  eval_setup
  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: multi-tool
    on: PreToolUse Bash|Write
    match: command =~ ls
    deny: Blocked
YAML
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_denied "pipe matcher matches Bash" "$result"

  eval_teardown
}

# ── Disabled rules ──

test_eval_disabled() {
  echo "disabled rules"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: disabled-rule
    on: PreToolUse Bash
    match: command =~ ls
    deny: Should not fire
    enabled: false
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "disabled rule doesn't fire" "$result"

  eval_teardown
}

# ── Debug output ──

test_eval_debug() {
  echo "debug output"
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
  assert_contains "rule name in debug" "$stderr_out" "my-custom-guard"
  assert_contains "event in debug" "$stderr_out" "PreToolUse"

  eval_teardown
}

# ── Multi-file / folder rules ──

test_eval_multi_file() {
  echo "multi-file rules"
  eval_setup

  # Single-file rules
  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: base-rule
    on: PreToolUse Bash
    match: command =~ rm\s+-rf
    deny: Base rule blocked rm
YAML

  # Rule folder with grouped files
  mkdir -p "$EVAL_DIR/.hooksmith/rules/security"
  cat > "$EVAL_DIR/.hooksmith/rules/security/sudo.yaml" << 'YAML'
rules:
  - name: sudo-block
    on: PreToolUse Bash
    run: |
      cmd=$(get_field command)
      [[ "$cmd" =~ ^sudo ]] && echo "Sudo blocked by security rules"
    deny: true
YAML

  mkdir -p "$EVAL_DIR/.hooksmith/rules/files"
  cat > "$EVAL_DIR/.hooksmith/rules/files/env-guard.yaml" << 'YAML'
rules:
  - name: env-file-guard
    on: PreToolUse Write
    match: file_path =~ \.env$
    ask: Env file modification
YAML

  # Test base rule (hooksmith.yaml)
  local result
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_denied "multi-file: base hooksmith.yaml rule works" "$result"

  # Test subfolder rule (security/sudo.yaml)
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo whoami"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_denied "multi-file: security/sudo.yaml rule works" "$result"
  assert_contains "multi-file: reason from subfolder rule" "$result" "Sudo blocked by security rules"

  # Test subfolder rule (files/env-guard.yaml)
  result=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"config/.env"}}' | \
    (cd "$EVAL_DIR" && bash "$HOOKSMITH" eval 2>/dev/null))
  assert_asks "multi-file: files/env-guard.yaml rule works" "$result"

  # Non-matching command should pass through all rules
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_allowed "multi-file: safe command passes all rules" "$result"

  eval_teardown
}

test_eval_flat_rules_folder() {
  echo "flat rules folder"
  eval_setup

  mkdir -p "$EVAL_DIR/.hooksmith/rules"
  cat > "$EVAL_DIR/.hooksmith/rules/block-push.yaml" << 'YAML'
rules:
  - name: block-push
    on: PreToolUse Bash
    match: command =~ git\s+push
    deny: Push blocked
YAML

  local result
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "flat folder: rule from rules/*.yaml works" "$result"

  eval_teardown
}

# ── Map auto-rebuild tests ──

test_eval_map_auto_rebuild() {
  echo "map auto-rebuild"
  eval_setup

  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: original-rule
    on: PreToolUse Bash
    match: command =~ git\s+push
    deny: Push blocked
YAML

  # First eval builds the map
  local result
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "map: first eval builds map and denies" "$result"

  # Map file should exist
  if [[ -f "$EVAL_DIR/.hooksmith/.map.json" ]]; then
    _pass "map: .map.json created"
  else
    _fail "map: .map.json created" "file not found"
  fi

  # Second eval uses cached map (rule still works)
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_denied "map: cached map still denies" "$result"

  # Update rules — add a new rule, touch file to ensure newer timestamp
  sleep 1
  cat > "$EVAL_DIR/.hooksmith/hooksmith.yaml" << 'YAML'
rules:
  - name: updated-rule
    on: PreToolUse Bash
    match: command =~ ls
    deny: ls is now blocked
YAML

  # Eval should detect stale map, rebuild, and use new rule
  result=$(eval_run "$FIXTURES/bash-safe.json" "PreToolUse" "Bash")
  assert_denied "map: auto-rebuild picks up new rule" "$result"
  assert_contains "map: new reason after rebuild" "$result" "ls is now blocked"

  # Old rule should no longer match
  result=$(eval_run "$FIXTURES/bash-git-push.json" "PreToolUse" "Bash")
  assert_allowed "map: old rule gone after rebuild" "$result"

  eval_teardown
}

# ── Init command ──

test_init() {
  echo "init command"
  eval_setup

  local out hf="$EVAL_DIR/hooks.json"
  out=$(OUTPUT="$hf" bash "$HOOKSMITH" init 2>&1)
  assert_contains "init generates output" "$out" "Generated"

  local content
  content=$(cat "$hf")
  assert_contains "init: hooks key" "$content" '"hooks"'
  assert_contains "init: PreToolUse registered" "$content" '"PreToolUse"'
  assert_contains "init: hooksmith eval command" "$content" "hooksmith eval"

  eval_teardown
}

# ── Run ──

echo "Hooksmith Test Suite"
echo "════════════════════════════════════════"
echo ""
test_cli
echo ""
test_init
echo ""
echo "match"
echo "─────"
test_eval_match
echo ""
test_eval_match_actions
echo ""
test_eval_match_fields
echo ""
echo "run"
echo "───"
test_eval_run_inline
echo ""
test_eval_run_file
echo ""
echo "routing"
echo "───────"
test_eval_routing
echo ""
test_eval_disabled
echo ""
echo "multi-file"
echo "──────────"
test_eval_multi_file
echo ""
test_eval_flat_rules_folder
echo ""
echo "map"
echo "───"
test_eval_map_auto_rebuild
echo ""
echo "debug"
echo "─────"
test_eval_debug
echo ""
print_summary
