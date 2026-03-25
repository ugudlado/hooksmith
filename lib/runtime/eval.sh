#!/bin/bash
# eval.sh — Live rule evaluator. Reads hooksmith.yaml, matches rules, returns decision.
# No build step needed. Called directly from hooks.json.
#
# Usage: eval.sh
#   Reads hook context JSON on stdin (from Claude Code).
#   Reads rules from hooksmith.yaml files (project then user scope).
#   Evaluates matching rules and outputs decision JSON.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../core/config.sh"
source "${SCRIPT_DIR}/../core/hooklib.sh"

PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Rule file locations ──

_rule_files() {
  # Project scope first (higher priority), then user scope
  local files=()
  [[ -f ".hooksmith/hooksmith.yaml" ]] && files+=(".hooksmith/hooksmith.yaml")
  [[ -f "$HOME/.config/hooksmith/hooksmith.yaml" ]] && files+=("$HOME/.config/hooksmith/hooksmith.yaml")
  printf '%s\n' "${files[@]}"
}

# ── Extract event + tool from stdin JSON ──

_parse_context() {
  local json="$1"
  HOOK_EVENT=$(echo "$json" | jq -r '.hook_event_name // empty')
  TOOL_NAME=$(echo "$json" | jq -r '.tool_name // empty')
  debug "eval: event=$HOOK_EVENT tool=$TOOL_NAME"
}

# ── Check if a rule's "on" field matches the current event+tool ──

_rule_matches() {
  local on_field="$1"
  local rule_event="${on_field%% *}"
  local rule_matcher="${on_field#"$rule_event"}"
  rule_matcher="${rule_matcher# }"

  # Event must match
  [[ "$rule_event" != "$HOOK_EVENT" ]] && return 1

  # If rule has a matcher, check it against the tool name (regex)
  if [[ -n "$rule_matcher" && -n "$TOOL_NAME" ]]; then
    local re="^(${rule_matcher})$"
    [[ "$TOOL_NAME" =~ $re ]] || return 1
  fi

  return 0
}

# ── Evaluate a single rule ──

_eval_rule() {
  local rule="$1" input="$2"
  local name match_field run_field prompt_field action

  name=$(echo "$rule" | jq -r '.name // "unnamed"')

  # Detect action
  action=""
  local message=""
  for a in deny ask context; do
    local val
    val=$(echo "$rule" | jq -r "if has(\"$a\") then .$a | tostring else empty end")
    if [[ -n "$val" ]]; then
      action="$a"; message="$val"; break
    fi
  done
  [[ -z "$action" ]] && return 0

  # Detect mechanism
  match_field=$(echo "$rule" | jq -r '.match // empty')
  run_field=$(echo "$rule" | jq -r '.run // empty')
  prompt_field=$(echo "$rule" | jq -r '.prompt // empty')

  if [[ -n "$match_field" ]]; then
    _eval_match "$name" "$match_field" "$message" "$action" "$input"
  elif [[ -n "$run_field" ]]; then
    _eval_run "$name" "$run_field" "$action" "$input"
  fi
  # prompt rules can't be evaluated at runtime (they need type:prompt in hooks.json)
}

# ── Evaluate a match (regex) rule ──

_eval_match() {
  local name="$1" match_field="$2" message="$3" action="$4" input="$5"

  # Parse "field =~ pattern"
  if [[ ! "$match_field" =~ ^([a-z_]+)[[:space:]]*=~[[:space:]]*(.+)$ ]]; then
    debug "eval [$name]: invalid match syntax: $match_field"
    return 0
  fi
  local field="${BASH_REMATCH[1]}"
  local pattern="${BASH_REMATCH[2]}"
  pattern=$(echo "$pattern" | sed "s/^[\"']//; s/[\"']$//")

  # Extract field value
  local value
  value=$(echo "$input" | jq -r --arg f "$field" '.tool_input[$f] // .[$f] // empty')

  local re="$pattern"
  if [[ "$value" =~ $re ]]; then
    debug "eval [$name]: matched '$field' =~ '$pattern'"
    _emit_decision "$action" "$message"
    return 1  # signal: decision made
  fi
  return 0
}

# ── Evaluate a run (script) rule ──

_eval_run() {
  local name="$1" run_field="$2" action="$3" input="$4"

  local script_content
  local resolved_path
  resolved_path=$(expand_tilde "$run_field")
  if [[ -f "$resolved_path" ]]; then
    script_content=$(cat "$resolved_path")
  else
    script_content="$run_field"
  fi

  # Execute with INPUT set
  local reason
  INPUT="$input" reason=$(eval "$script_content" 2>/dev/null) || true

  if [[ -n "$reason" ]]; then
    debug "eval [$name]: script returned reason: $reason"
    _emit_decision "$action" "$reason"
    return 1  # signal: decision made
  fi
  return 0
}

# ── Emit decision JSON ──

_emit_decision() {
  local action="$1" message="$2"
  case "$action" in
    deny)
      jq -n --arg r "$message" '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    ask)
      jq -n --arg r "$message" '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}' ;;
    context)
      jq -n --arg c "$message" '{hookSpecificOutput:{permissionDecision:"allow",additionalContext:$c}}' ;;
  esac
}

# ── Main ──

main() {
  # Read stdin
  local input
  input=$(cat)

  _parse_context "$input"

  if [[ -z "$HOOK_EVENT" ]]; then
    debug "eval: no hook_event_name in input"
    exit 0
  fi

  # Find and evaluate matching rules
  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue

    local rule_count
    rule_count=$(yq '.rules | length' "$rule_file" 2>/dev/null)
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local i
    for (( i=0; i<rule_count; i++ )); do
      local rule
      rule=$(yq -c ".rules[$i]" "$rule_file" 2>/dev/null)

      # Skip disabled
      local enabled
      enabled=$(echo "$rule" | jq -r 'if has("enabled") then .enabled | tostring else empty end')
      [[ "$enabled" == "false" ]] && continue

      # Check if rule matches this event
      local on_field
      on_field=$(echo "$rule" | jq -r '.on // empty')
      [[ -z "$on_field" ]] && continue

      if _rule_matches "$on_field"; then
        local name
        name=$(echo "$rule" | jq -r '.name // "rule-'"$((i+1))"'"')
        debug "eval: evaluating rule '$name'"

        if _eval_rule "$rule" "$input"; then
          : # rule didn't produce a decision, continue
        else
          exit 0  # decision was emitted, stop
        fi
      fi
    done
  done < <(_rule_files)

  # No rule matched — pass through
  exit 0
}

main
