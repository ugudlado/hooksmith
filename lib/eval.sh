#!/bin/bash
# eval.sh — Rule evaluator with event-keyed map for fast routing.
#
# The map (.hooksmith/.map.json) is an event-keyed index:
#   {"PreToolUse":[{"name":"block-rm","file":"...","matcher":"Bash","rule":{...}}], ...}
#
# Rules are cached in the map — no YAML parsing at eval time.
# Map auto-rebuilds when any rule file is newer than .map.json.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/core/config.sh"
source "${SCRIPT_DIR}/core/hooklib.sh"
source "${SCRIPT_DIR}/core/map.sh"

# ── Extract event + tool from stdin JSON ──

_parse_context() {
  local json="$1"
  # Single jq call to extract both fields
  local fields
  fields=$(echo "$json" | jq -r '[.hook_event_name // "", .tool_name // ""] | join("\t")')
  IFS=$'\t' read -r HOOK_EVENT TOOL_NAME <<< "$fields"
  debug "eval: event=$HOOK_EVENT tool=$TOOL_NAME"
}

# ── Check if a rule's matcher matches the current tool ──

_matcher_matches() {
  local matcher="$1"
  [[ -z "$matcher" ]] && return 0
  [[ -z "$TOOL_NAME" ]] && return 0
  local re="^(${matcher})$"
  [[ "$TOOL_NAME" =~ $re ]] || return 1
  return 0
}

# ── Evaluate a single rule (all fields pre-extracted in one jq call) ──

_eval_rule() {
  local rule="$1" input="$2" rule_file="${3:-}"

  # Single jq call: extract action type, message, name, and mechanism type
  local meta
  meta=$(printf '%s\n' "$rule" | jq -r '{
    action: (if has("deny") then "deny" elif has("ask") then "ask" elif has("context") then "context" else "" end),
    message: (if has("deny") then (.deny|tostring) elif has("ask") then (.ask|tostring) elif has("context") then (.context|tostring) else "" end),
    name: (.name // "unnamed"),
    mech: (if has("match") then "match" elif has("run") then "run" elif has("prompt") then "prompt" else "" end)
  } | "\(.action)\n\(.message)\n\(.name)\n\(.mech)"')

  local action message name mech
  { read -r action; read -r message; read -r name; read -r mech; } <<< "$meta"
  [[ -z "$action" ]] && return 0

  # Fix bare "true" messages (e.g. deny: true)
  if [[ "$message" == "true" ]]; then
    message="Blocked by rule: $name"
    debug "eval [$name]: action '$action' had bare 'true', using generated message"
  fi

  # Extract the mechanism field value (may contain newlines for run/prompt)
  case "$mech" in
    match)
      local match_field
      match_field=$(printf '%s\n' "$rule" | jq -r '.match // empty')
      _eval_match "$name" "$match_field" "$message" "$action" "$input"
      ;;
    run)
      local run_field
      run_field=$(printf '%s\n' "$rule" | jq -r '.run // empty')
      _eval_run "$name" "$run_field" "$action" "$input" "$rule_file"
      ;;
    prompt)
      local prompt_field
      prompt_field=$(printf '%s\n' "$rule" | jq -r '.prompt // empty')
      _eval_prompt "$name" "$prompt_field" "$action" "$input"
      ;;
  esac
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
  local name="$1" run_field="$2" action="$3" input="$4" rule_file="${5:-}"

  local script_content
  local resolved_path
  resolved_path=$(expand_tilde "$run_field")
  if [[ -f "$resolved_path" ]]; then
    script_content=$(cat "$resolved_path")
  elif [[ -n "$rule_file" && "$run_field" == */* && "$run_field" != /* && "$run_field" != ~* ]]; then
    # Relative path — resolve from the rule file's directory
    local rule_dir
    rule_dir=$(dirname "$rule_file")
    resolved_path="$rule_dir/$run_field"
    if [[ -f "$resolved_path" ]]; then
      script_content=$(cat "$resolved_path")
    else
      debug "eval [$name]: script file not found: $resolved_path (relative to $rule_dir)"
      return 0
    fi
  elif [[ "$run_field" == */* || "$run_field" == ~* ]]; then
    debug "eval [$name]: script file not found: $resolved_path"
    return 0
  else
    script_content="$run_field"
  fi

  local reason
  HOOKLIB="${SCRIPT_DIR}/core/hooklib.sh" INPUT="$input" reason=$(echo "$input" | eval "$script_content") || true

  if [[ -n "$reason" ]]; then
    debug "eval [$name]: script returned reason: $reason"
    # If the script already emitted a full hooksmith decision JSON, pass it through
    if echo "$reason" | jq -e '.hookSpecificOutput.permissionDecision // .decision' >/dev/null 2>&1; then
      echo "$reason"
      return 1
    fi
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
  case "$HOOK_EVENT" in
    Stop|SubagentStop)
      case "$action" in
        deny)    jq -n --arg r "$message" '{decision:"block",reason:$r}' ;;
        context) jq -n --arg c "$message" '{decision:"approve",reason:$c}' ;;
        *)       return 0 ;;
      esac ;;
    UserPromptSubmit)
      case "$action" in
        deny)    jq -n --arg r "$message" '{decision:"block",reason:$r}' ;;
        context) jq -n --arg c "$message" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}' ;;
        *)       return 0 ;;
      esac ;;
    PostToolUse)
      case "$action" in
        deny)    jq -n --arg r "$message" '{hookSpecificOutput:{hookEventName:"PostToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
        context) jq -n --arg c "$message" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' ;;
        *)       return 0 ;;
      esac ;;
    *)
      # PreToolUse and all other events
      case "$action" in
        deny)    jq -n --arg r "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
        ask)     jq -n --arg r "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' ;;
        context) jq -n --arg c "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}' ;;
      esac ;;
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

  # Auto-init on SessionStart: rebuild the map index
  if [[ "$HOOK_EVENT" == "SessionStart" ]]; then
    debug "eval: SessionStart — rebuilding map"
    _build_map
    exit 0
  fi

  _ensure_map

  # Event-keyed lookup: only load rules for this event (single jq call)
  local event_rules
  event_rules=$(jq -c --arg e "$HOOK_EVENT" '.[$e] // [] | .[]' "$MAP_FILE")

  [[ -z "$event_rules" ]] && exit 0
  debug "eval: $(echo "$event_rules" | wc -l | tr -d ' ') rules for $HOOK_EVENT"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue

    # Pre-filter by matcher (stored in map, no rule load needed)
    local matcher name
    matcher=$(printf '%s\n' "$entry" | jq -r '.matcher')
    if ! _matcher_matches "$matcher"; then
      continue
    fi

    local name rule_file
    name=$(printf '%s\n' "$entry" | jq -r '.name')
    rule_file=$(printf '%s\n' "$entry" | jq -r '.file')
    debug "eval: evaluating rule '$name'"

    # Rule is cached in the map — no YAML load needed
    local rule
    rule=$(printf '%s\n' "$entry" | jq -c '.rule')

    if ! _eval_rule "$rule" "$input" "$rule_file"; then
      exit 0
    fi
  done <<< "$event_rules"

  exit 0
}

main
