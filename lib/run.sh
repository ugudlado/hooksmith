#!/bin/bash
# run.sh — Unified hook executor. Resolves hook id to YAML rule and executes.
# Usage: run.sh <id>
# Receives hook context JSON on stdin from Claude Code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/parse.sh"

PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
USER_RULES_DIR="$HOOKSMITH_USER_RULES_DIR"
PROJECT_RULES_DIR="$HOOKSMITH_PROJECT_RULES_DIR"

# ── Resolve id to rule file ──

resolve_rule() {
  local id="$1"
  # Guard against path traversal in id
  [[ "$id" =~ ^[a-z0-9-]+$ ]] || { echo "ERROR: invalid rule id: $id" >&2; return 1; }
  # Project scope first (override), then user scope
  if [[ -f "${PROJECT_RULES_DIR}/${id}.yaml" ]]; then
    echo "${PROJECT_RULES_DIR}/${id}.yaml"
  elif [[ -f "${USER_RULES_DIR}/${id}.yaml" ]]; then
    echo "${USER_RULES_DIR}/${id}.yaml"
  fi
}

# ── Main ──

main() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "hooksmith run: missing hook id" >&2
    exit 1
  fi

  # Read stdin (hook context JSON)
  local input
  input=$(cat)

  # Resolve rule file
  local rule_file
  rule_file=$(resolve_rule "$id")
  if [[ -z "$rule_file" ]]; then
    debug "rule not found for id '$id'"
    echo "hooksmith run: rule not found for id '$id'" >&2
    exit 0  # fail-open
  fi
  debug "resolved rule '$id' -> $rule_file"

  # Parse YAML
  local parsed
  parsed=$(parse_yaml "$rule_file" 2>/dev/null)
  if [[ -z "$parsed" ]]; then
    debug "failed to parse rule '$id' from $rule_file"
    echo "hooksmith run: failed to parse rule '$id'" >&2
    exit 0  # fail-open
  fi

  # Check if disabled
  local enabled
  enabled=$(get_val "$parsed" "enabled")
  if [[ "$enabled" == "false" ]]; then
    echo "hooksmith run: rule '$id' is disabled" >&2
    exit 0
  fi

  local mechanism fail_mode
  mechanism=$(get_val "$parsed" "mechanism")
  fail_mode=$(get_val "$parsed" "fail_mode")
  [[ -z "$fail_mode" ]] && fail_mode="$HOOKSMITH_DEFAULT_FAIL_MODE"

  debug "dispatching rule '$id': mechanism=$mechanism fail_mode=$fail_mode"

  # Dispatch by mechanism
  local output
  case "$mechanism" in
    regex)
      local field pattern message result
      field=$(get_val "$parsed" "field")
      pattern=$(get_val "$parsed" "pattern")
      message=$(get_val "$parsed" "message")
      result=$(get_val "$parsed" "result")
      [[ -z "$message" ]] && message="Blocked by hooksmith rule: $id"
      if output=$(echo "$input" | bash "${PLUGIN_ROOT}/lib/regex-match.sh" "$field" "$pattern" "$message" "$result" 2>/dev/null); then
        if [[ -n "$output" ]]; then echo "$output"; fi
      else
        _handle_failure "$fail_mode"
      fi
      ;;
    script)
      local script_path
      script_path=$(get_val "$parsed" "script")
      script_path=$(expand_tilde "$script_path")
      if [[ ! -f "$script_path" ]]; then
        echo "hooksmith run: script not found: $script_path" >&2
        _handle_failure "$fail_mode"
        return
      fi
      if output=$(echo "$input" | HOOKLIB="${PLUGIN_ROOT}/lib/hooklib.sh" bash "$script_path" 2>/dev/null); then
        if [[ -n "$output" ]]; then echo "$output"; fi
      else
        _handle_failure "$fail_mode"
      fi
      ;;
    *)
      echo "hooksmith run: unknown mechanism '$mechanism' for rule '$id'" >&2
      exit 0  # fail-open
      ;;
  esac
}

_handle_failure() {
  local fail_mode="$1"
  if [[ "$fail_mode" == "closed" ]]; then
    jq -n '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:"Hook script failed (fail_mode: closed)"}}'
  fi
  exit 0
}

main "$@"
