#!/bin/bash
# eval.sh — Rule evaluator with auto-indexing map for fast lookups.
#
# On first run (or when rule files change), builds a JSON map at
# .hooksmith/.map.json that indexes all rules by event. Subsequent
# runs skip YAML parsing entirely and evaluate from the map.
#
# Rule file locations (all scanned, project scope first):
#   .hooksmith/hooksmith.yaml, .hooksmith/rules/**/*.yaml
#   ~/.config/hooksmith/hooksmith.yaml, ~/.config/hooksmith/rules/**/*.yaml
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/core/config.sh"
source "${SCRIPT_DIR}/core/hooklib.sh"

MAP_FILE=".hooksmith/.map.json"

# ── Collect all rule files ──

_rule_files() {
  local dirs=(".hooksmith" "$HOME/.config/hooksmith")
  for dir in "${dirs[@]}"; do
    [[ -f "$dir/hooksmith.yaml" ]] && echo "$dir/hooksmith.yaml"
    if [[ -d "$dir/rules" ]]; then
      for f in "$dir/rules"/*.yaml; do [[ -f "$f" ]] && echo "$f"; done
      for sub in "$dir/rules"/*/; do
        [[ -d "$sub" ]] || continue
        for f in "$sub"*.yaml; do [[ -f "$f" ]] && echo "$f"; done
      done
    fi
  done
}

# ── Check if map is fresh (newer than all rule files) ──

_map_is_fresh() {
  [[ -f "$MAP_FILE" ]] || return 1
  while IFS= read -r f; do
    [[ "$f" -nt "$MAP_FILE" ]] && return 1
  done < <(_rule_files)
  return 0
}

# ── Build the map: pre-parse all rules into a single JSON file ──

_build_map() {
  debug "map: rebuilding $MAP_FILE"
  local rules_json="[]"

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(yq '.rules | length' "$rule_file" 2>/dev/null)
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local i
    for (( i=0; i<rule_count; i++ )); do
      local rule
      rule=$(yq -c ".rules[$i]" "$rule_file" 2>/dev/null)
      [[ -z "$rule" ]] && continue

      # Skip disabled
      local enabled
      enabled=$(echo "$rule" | jq -r 'if has("enabled") then .enabled | tostring else empty end')
      [[ "$enabled" == "false" ]] && continue

      local on_field
      on_field=$(echo "$rule" | jq -r '.on // empty')
      [[ -z "$on_field" ]] && continue

      # Extract event and matcher from "on" field
      local event="${on_field%% *}"
      local matcher="${on_field#"$event"}"
      matcher="${matcher# }"

      # Add source file and parsed event/matcher to the rule
      rule=$(echo "$rule" | jq -c \
        --arg event "$event" --arg matcher "$matcher" --arg file "$rule_file" \
        '. + {_event:$event, _matcher:$matcher, _file:$file}')

      rules_json=$(echo "$rules_json" | jq -c --argjson r "$rule" '. + [$r]')
    done
  done < <(_rule_files)

  mkdir -p "$(dirname "$MAP_FILE")"
  echo "$rules_json" | jq '.' > "$MAP_FILE"
  debug "map: indexed $(echo "$rules_json" | jq 'length') rules"
}

# ── Load map, rebuild if stale ──

_ensure_map() {
  if ! _map_is_fresh; then
    _build_map
  fi
}

# ── Extract event + tool from stdin JSON ──

_parse_context() {
  local json="$1"
  HOOK_EVENT=$(echo "$json" | jq -r '.hook_event_name // empty')
  TOOL_NAME=$(echo "$json" | jq -r '.tool_name // empty')
  debug "eval: event=$HOOK_EVENT tool=$TOOL_NAME"
}

# ── Check if a rule's matcher matches the current tool ──

_matcher_matches() {
  local matcher="$1"
  # No matcher = matches everything
  [[ -z "$matcher" ]] && return 0
  # No tool name = only match if no matcher
  [[ -z "$TOOL_NAME" ]] && return 1
  local re="^(${matcher})$"
  [[ "$TOOL_NAME" =~ $re ]]
}

# ── Evaluate a single rule from the map ──

_eval_rule() {
  local rule="$1" input="$2"

  local action="" message=""
  for a in deny ask context; do
    local val
    val=$(echo "$rule" | jq -r "if has(\"$a\") then .$a | tostring else empty end")
    if [[ -n "$val" ]]; then
      action="$a"; message="$val"; break
    fi
  done
  [[ -z "$action" ]] && return 0

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

  _ensure_map

  # Query map: get rules matching this event, then filter by matcher
  local matching_rules
  matching_rules=$(jq -c --arg e "$HOOK_EVENT" '[.[] | select(._event == $e)]' "$MAP_FILE")

  local rule_count
  rule_count=$(echo "$matching_rules" | jq 'length')
  debug "eval: $rule_count rules for event $HOOK_EVENT"

  local i
  for (( i=0; i<rule_count; i++ )); do
    local rule
    rule=$(echo "$matching_rules" | jq -c ".[$i]")

    local matcher
    matcher=$(echo "$rule" | jq -r '._matcher')

    if _matcher_matches "$matcher"; then
      local name
      name=$(echo "$rule" | jq -r '.name // "unnamed"')
      debug "eval: evaluating rule '$name'"

      if _eval_rule "$rule" "$input"; then
        :
      else
        exit 0
      fi
    fi
  done

  exit 0
}

main
