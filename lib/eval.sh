#!/bin/bash
# eval.sh — Rule evaluator with auto-indexing map for fast routing.
#
# The map (.hooksmith/.map.json) is a lightweight index:
#   [{"name":"block-rm","file":".hooksmith/rules/security/block-rm.yaml","index":0}]
#
# It only stores name, file path, and rule index.
# The actual rule content stays in YAML — map is just for routing.
# On eval, the map tells us which file+index to load, then we parse
# only that one rule from YAML.
#
# Map auto-rebuilds when any rule file is newer than .map.json.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/core/config.sh"
source "${SCRIPT_DIR}/core/hooklib.sh"
source "${SCRIPT_DIR}/core/map.sh"

# ── Load a single rule from its YAML file by index ──

_load_rule() {
  local file="$1" idx="$2"
  _yq_json ".rules[$idx]" "$file" | jq -c '.' 2>/dev/null
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
  # Normalize whitespace: collapse runs, trim edges
  on_field=$(echo "$on_field" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')

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

# ── Evaluate a single rule ──

_eval_rule() {
  local rule="$1" input="$2"

  local action="" message=""
  for a in deny ask context; do
    local val
    val=$(printf '%s\n' "$rule" | jq -r "if has(\"$a\") then .$a | tostring else empty end")
    if [[ -n "$val" ]]; then
      action="$a"; message="$val"; break
    fi
  done
  [[ -z "$action" ]] && return 0

  # Fix bare "true" messages (e.g. deny: true) — generate a useful message
  if [[ "$message" == "true" ]]; then
    local rule_name
    rule_name=$(printf '%s\n' "$rule" | jq -r '.name // "unnamed"')
    message="Blocked by rule: $rule_name"
    debug "eval [$rule_name]: action '$action' had bare 'true', using generated message"
  fi

  local match_field run_field prompt_field
  match_field=$(printf '%s\n' "$rule" | jq -r '.match // empty')
  run_field=$(printf '%s\n' "$rule" | jq -r '.run // empty')
  prompt_field=$(printf '%s\n' "$rule" | jq -r '.prompt // empty')
  local name
  name=$(printf '%s\n' "$rule" | jq -r '.name // "unnamed"')

  if [[ -n "$match_field" ]]; then
    _eval_match "$name" "$match_field" "$message" "$action" "$input"
  elif [[ -n "$run_field" ]]; then
    _eval_run "$name" "$run_field" "$action" "$input"
  elif [[ -n "$prompt_field" ]]; then
    _eval_prompt "$name" "$prompt_field" "$action" "$input"
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
  value=$(printf '%s\n' "$input" | jq -r --arg f "$field" '.tool_input[$f] // .[$f] // empty')

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
  elif [[ "$run_field" == */* || "$run_field" == ~* ]]; then
    debug "eval [$name]: script file not found: $resolved_path"
    return 0
  else
    script_content="$run_field"
  fi

  local reason
  HOOKLIB="${SCRIPT_DIR}/core/hooklib.sh" INPUT="$input" reason=$(eval "$script_content") || true

  if [[ -n "$reason" ]]; then
    debug "eval [$name]: script returned reason: $reason"
    _emit_decision "$action" "$reason"
    return 1
  fi
  return 0
}

_eval_prompt() {
  local name="$1" prompt_field="$2" action="$3" input="$4"

  # Build context: prompt text + serialized tool input for Claude to reason about
  local tool_input
  tool_input=$(printf '%s\n' "$input" | jq -c '.tool_input // {}')
  local full_prompt="[hooksmith:$name] $prompt_field

Tool input:
$tool_input"

  debug "eval [$name]: prompt rule firing, action=$action"
  _emit_decision "$action" "$full_prompt"
  return 1
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

  # Auto-init on SessionStart: rebuild map and regenerate hooks.json
  if [[ "$HOOK_EVENT" == "SessionStart" ]]; then
    debug "eval: SessionStart — running auto-init"
    HOOKSMITH_SILENT_INIT=1 OUTPUT="${OUTPUT:-}" bash "${SCRIPT_DIR}/cli/init.sh"
    exit 0
  fi

  _ensure_map

  # Load entire map in one jq call — array of {name, file, index}
  local map_entries
  map_entries=$(jq -c '.[]' "$MAP_FILE")
  debug "eval: $(jq 'length' "$MAP_FILE") rules in map"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local name file idx
    name=$(printf '%s\n' "$entry" | jq -r '.name')
    file=$(printf '%s\n' "$entry" | jq -r '.file')
    idx=$(printf '%s\n' "$entry" | jq -r '.index')

    # Load rule from YAML and check event/matcher
    local rule
    rule=$(_load_rule "$file" "$idx")
    [[ -z "$rule" ]] && continue

    local on_field
    on_field=$(printf '%s\n' "$rule" | jq -r '.on // empty')
    [[ -z "$on_field" ]] && continue

    if _rule_matches "$on_field"; then
      debug "eval: evaluating rule '$name' from $file"

      if ! _eval_rule "$rule" "$input"; then
        exit 0
      fi
    fi
  done <<< "$map_entries"

  exit 0
}

main
