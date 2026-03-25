#!/bin/bash
# eval.sh — Live rule evaluator. Reads rules from YAML files, matches, returns decision.
# No build step. Called directly from hooks.json.
#
# Usage: eval.sh
#   Reads hook context JSON on stdin (from Claude Code).
#   Scans rule files from project and user scope.
#   Evaluates matching rules and outputs decision JSON.
#
# Rule file locations (all scanned, project scope first):
#   .hooksmith/hooksmith.yaml                — project single-file rules
#   .hooksmith/rules/*.yaml                  — project rule folder
#   .hooksmith/rules/<subfolder>/*.yaml      — project grouped rules
#   ~/.config/hooksmith/hooksmith.yaml       — user single-file rules
#   ~/.config/hooksmith/rules/*.yaml         — user rule folder
#   ~/.config/hooksmith/rules/<subfolder>/*.yaml — user grouped rules
#
# Example folder structure:
#   .hooksmith/
#     hooksmith.yaml           — quick rules
#     rules/
#       security/
#         block-rm.yaml
#         sudo-guard.yaml
#       formatting/
#         lint-on-save.yaml
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/core/config.sh"
source "${SCRIPT_DIR}/core/hooklib.sh"

# ── Collect all rule files (project scope first, then user scope) ──

_rule_files() {
  local dirs=(
    ".hooksmith"
    "$HOME/.config/hooksmith"
  )
  for dir in "${dirs[@]}"; do
    # Single-file rules
    [[ -f "$dir/hooksmith.yaml" ]] && echo "$dir/hooksmith.yaml"
    # Rule folder (flat)
    if [[ -d "$dir/rules" ]]; then
      for f in "$dir/rules"/*.yaml; do
        [[ -f "$f" ]] && echo "$f"
      done
      # Subfolders (one level deep for grouping)
      for sub in "$dir/rules"/*/; do
        [[ -d "$sub" ]] || continue
        for f in "$sub"*.yaml; do
          [[ -f "$f" ]] && echo "$f"
        done
      done
    fi
  done
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

  # Detect action
  local action="" message=""
  for a in deny ask context; do
    local val
    val=$(echo "$rule" | jq -r "if has(\"$a\") then .$a | tostring else empty end")
    if [[ -n "$val" ]]; then
      action="$a"; message="$val"; break
    fi
  done
  [[ -z "$action" ]] && return 0

  # Detect mechanism
  local match_field run_field
  match_field=$(echo "$rule" | jq -r '.match // empty')
  run_field=$(echo "$rule" | jq -r '.run // empty')

  local name
  name=$(echo "$rule" | jq -r '.name // "unnamed"')

  if [[ -n "$match_field" ]]; then
    _eval_match "$name" "$match_field" "$message" "$action" "$input"
  elif [[ -n "$run_field" ]]; then
    _eval_run "$name" "$run_field" "$action" "$input"
  fi
}

# ── Evaluate a match (regex) rule ──

_eval_match() {
  local name="$1" match_field="$2" message="$3" action="$4" input="$5"

  if [[ ! "$match_field" =~ ^([a-z_]+)[[:space:]]*=~[[:space:]]*(.+)$ ]]; then
    debug "eval [$name]: invalid match syntax: $match_field"
    return 0
  fi
  local field="${BASH_REMATCH[1]}"
  local pattern="${BASH_REMATCH[2]}"
  pattern=$(echo "$pattern" | sed "s/^[\"']//; s/[\"']$//")

  local value
  value=$(echo "$input" | jq -r --arg f "$field" '.tool_input[$f] // .[$f] // empty')

  local re="$pattern"
  if [[ "$value" =~ $re ]]; then
    debug "eval [$name]: matched '$field' =~ '$pattern'"
    _emit_decision "$action" "$message"
    return 1
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

  local reason
  HOOKLIB="${SCRIPT_DIR}/core/hooklib.sh" INPUT="$input" reason=$(eval "$script_content" 2>/dev/null) || true

  if [[ -n "$reason" ]]; then
    debug "eval [$name]: script returned reason: $reason"
    _emit_decision "$action" "$reason"
    return 1
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
  local input
  input=$(cat)

  _parse_context "$input"

  if [[ -z "$HOOK_EVENT" ]]; then
    debug "eval: no hook_event_name in input"
    exit 0
  fi

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    debug "eval: scanning $rule_file"

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

      local on_field
      on_field=$(echo "$rule" | jq -r '.on // empty')
      [[ -z "$on_field" ]] && continue

      if _rule_matches "$on_field"; then
        local name
        name=$(echo "$rule" | jq -r '.name // "rule-'"$((i+1))"'"')
        debug "eval: evaluating rule '$name'"

        if _eval_rule "$rule" "$input"; then
          :
        else
          exit 0
        fi
      fi
    done
  done < <(_rule_files)

  exit 0
}

main
