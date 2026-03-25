#!/bin/bash
# eval.sh — Rule evaluator with auto-indexing map for fast routing.
#
# The map (.hooksmith/.map.json) is a lightweight index:
#   [{"name":"block-rm","event":"PreToolUse","matcher":"Bash","file":".hooksmith/rules/security/block-rm.yaml","index":0}]
#
# It only stores name, event, matcher, file path, and rule index.
# The actual rule content stays in YAML — map is just for routing.
# On eval, the map tells us which file+index to load, then we parse
# only that one rule from YAML.
#
# Map auto-rebuilds when any rule file is newer than .map.json.
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

# ── Check if map is fresh ──

_map_is_fresh() {
  [[ -f "$MAP_FILE" ]] || return 1
  while IFS= read -r f; do
    [[ "$f" -nt "$MAP_FILE" ]] && return 1
  done < <(_rule_files)
  return 0
}

# ── Build the map: just name, file, index ──

_build_map() {
  debug "map: rebuilding $MAP_FILE"
  local map_json="[]"

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(yq '.rules | length' "$rule_file" 2>/dev/null)
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local i
    for (( i=0; i<rule_count; i++ )); do
      local name enabled
      name=$(yq -r ".rules[$i].name // \"rule-$((i+1))\"" "$rule_file" 2>/dev/null)
      enabled=$(yq -r "if .rules[$i] | has(\"enabled\") then .rules[$i].enabled | tostring else empty end" "$rule_file" 2>/dev/null)
      [[ "$enabled" == "false" ]] && continue

      map_json=$(echo "$map_json" | jq -c \
        --arg name "$name" --arg file "$rule_file" --argjson idx "$i" \
        '. + [{name:$name, file:$file, index:$idx}]')
    done
  done < <(_rule_files)

  mkdir -p "$(dirname "$MAP_FILE")"
  echo "$map_json" | jq '.' > "$MAP_FILE"
  debug "map: indexed $(echo "$map_json" | jq 'length') rules"
}

_ensure_map() {
  if ! _map_is_fresh; then
    _build_map
  fi
}

# ── Load a single rule from its YAML file by index ──

_load_rule() {
  local file="$1" idx="$2"
  yq -c ".rules[$idx]" "$file" 2>/dev/null
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

  [[ "$rule_event" != "$HOOK_EVENT" ]] && return 1

  if [[ -n "$rule_matcher" && -n "$TOOL_NAME" ]]; then
    local re="^(${rule_matcher})$"
    [[ "$TOOL_NAME" =~ $re ]] || return 1
  fi

  return 0
}

# ── Check if matcher matches the current tool ──

_matcher_matches() {
  local matcher="$1"
  [[ -z "$matcher" ]] && return 0
  [[ -z "$TOOL_NAME" ]] && return 1
  local re="^(${matcher})$"
  [[ "$TOOL_NAME" =~ $re ]]
}

# ── Evaluate a single rule ──

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

  local entry_count
  entry_count=$(jq 'length' "$MAP_FILE")
  debug "eval: $entry_count rules in map"

  local i
  for (( i=0; i<entry_count; i++ )); do
    local name file idx
    name=$(jq -r ".[$i].name" "$MAP_FILE")
    file=$(jq -r ".[$i].file" "$MAP_FILE")
    idx=$(jq -r ".[$i].index" "$MAP_FILE")

    # Load rule from YAML and check event/matcher
    local rule
    rule=$(_load_rule "$file" "$idx")
    [[ -z "$rule" ]] && continue

    local on_field
    on_field=$(echo "$rule" | jq -r '.on // empty')
    [[ -z "$on_field" ]] && continue

    if _rule_matches "$on_field"; then
      debug "eval: evaluating rule '$name' from $file"

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
