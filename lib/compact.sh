#!/bin/bash
# compact.sh — Compiler for hooksmith compact rule format.
#
# Compact format example (hooksmith.yaml):
#
#   rules:
#     - on: PreToolUse Bash
#       if: command =~ 'rm\s+-rf'
#       deny: Destructive command blocked
#
#     - on: PreToolUse Write|Edit
#       if: file_path =~ '\.env$'
#       ask: Modifying sensitive file
#
#     - on: PreToolUse Bash
#       check: |
#         cmd=$(get_field command)
#         [[ "$cmd" =~ ^sudo ]] && echo "Root access not allowed"
#       deny: true
#
#     - on: PreToolUse Bash
#       script: ~/scripts/guard.sh
#       deny: Custom guard
#
#     - on: PreToolUse Write
#       prompt: Check if this write is safe
#       warn: AI flagged concern
#
# Optional per-rule: timeout, fail_mode, async, enabled
#
# Requires: config.sh sourced, yq + jq available.
# Outputs one JSON line per rule: {"event":..,"matcher":..,"entry":..}

compile_compact_rules() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  local rule_count
  rule_count=$(yq '.rules | length' "$file" 2>/dev/null)
  if [[ -z "$rule_count" || "$rule_count" == "null" || "$rule_count" -eq 0 ]]; then
    return 0
  fi

  local count=0 errors=0 i
  for (( i=0; i<rule_count; i++ )); do
    if _compile_one_rule "$file" "$i"; then
      count=$((count + 1))
    else
      errors=$((errors + 1))
    fi
  done

  debug "compact: compiled $count rules, $errors errors from $file"
  return 0
}

# ── Compile a single compact rule ──

_compile_one_rule() {
  local file="$1" idx="$2"
  local prefix="compact rule $((idx + 1))"

  local rule
  rule=$(yq -c ".rules[$idx]" "$file" 2>/dev/null)

  # ── Skip disabled ──
  local enabled
  enabled=$(echo "$rule" | jq -r 'if has("enabled") then .enabled | tostring else empty end')
  [[ "$enabled" == "false" ]] && return 0

  # ── Parse "on" → event + matcher ──
  local on_field event matcher
  on_field=$(echo "$rule" | jq -r '.on // empty')
  if [[ -z "$on_field" ]]; then
    echo "ERROR [$prefix]: missing 'on' field" >&2; return 1
  fi
  event="${on_field%% *}"
  matcher="${on_field#"$event"}"
  matcher="${matcher# }"

  if ! valid_event "$event"; then
    echo "ERROR [$prefix]: unknown event '$event'" >&2; return 1
  fi

  # ── Detect action (deny/ask/warn/context) ──
  local action="" message=""
  for a in deny ask warn context; do
    local val
    val=$(echo "$rule" | jq -r ".$a // empty")
    if [[ -n "$val" ]]; then
      action="$a"; message="$val"; break
    fi
  done
  if [[ -z "$action" ]]; then
    echo "ERROR [$prefix]: missing action (deny/ask/warn/context)" >&2; return 1
  fi
  if ! valid_result_event "$action" "$event"; then
    echo "ERROR [$prefix]: '$action' not valid for event '$event'" >&2; return 1
  fi

  # ── Detect mechanism (exactly one of: if, check, script, prompt) ──
  local if_field check_field script_field prompt_field
  if_field=$(echo "$rule" | jq -r '.["if"] // empty')
  check_field=$(echo "$rule" | jq -r '.check // empty')
  script_field=$(echo "$rule" | jq -r '.script // empty')
  prompt_field=$(echo "$rule" | jq -r '.prompt // empty')

  local mech_count=0
  [[ -n "$if_field" ]] && mech_count=$((mech_count + 1))
  [[ -n "$check_field" ]] && mech_count=$((mech_count + 1))
  [[ -n "$script_field" ]] && mech_count=$((mech_count + 1))
  [[ -n "$prompt_field" ]] && mech_count=$((mech_count + 1))

  if [[ $mech_count -ne 1 ]]; then
    echo "ERROR [$prefix]: exactly one of 'if', 'check', 'script', 'prompt' required" >&2; return 1
  fi

  # ── Optional fields ──
  local timeout is_async
  timeout=$(echo "$rule" | jq -r '.timeout // empty')
  is_async=$(echo "$rule" | jq -r '.async // empty')
  [[ -z "$timeout" ]] && timeout="$HOOKSMITH_DEFAULT_TIMEOUT"
  [[ -z "$is_async" ]] && is_async="$HOOKSMITH_DEFAULT_ASYNC"

  # ── Build entry ──
  local entry

  if [[ -n "$if_field" ]]; then
    entry=$(_build_regex_entry "$prefix" "$if_field" "$message" "$action" "$timeout")
    [[ $? -ne 0 ]] && return 1

  elif [[ -n "$check_field" ]]; then
    entry=$(_build_check_entry "$prefix" "$check_field" "$action" "$timeout")
    [[ $? -ne 0 ]] && return 1

  elif [[ -n "$script_field" ]]; then
    entry=$(_build_script_entry "$prefix" "$script_field" "$timeout")
    [[ $? -ne 0 ]] && return 1

  elif [[ -n "$prompt_field" ]]; then
    if ! prompt_event_ok "$event"; then
      echo "ERROR [$prefix]: prompt not supported for event '$event'" >&2; return 1
    fi
    entry=$(jq -n --arg p "$prompt_field" --argjson t "$timeout" \
      '{type:"prompt",prompt:$p,timeout:$t}')
  fi

  # Add async flag
  if [[ "$is_async" == "true" ]]; then
    local htype
    htype=$(echo "$entry" | jq -r '.type')
    [[ "$htype" == "command" ]] && entry=$(echo "$entry" | jq '. + {async:true}')
  fi

  # Output the compiled rule (compact, one line)
  jq -cn --arg e "$event" --arg m "$matcher" --argjson entry "$entry" \
    '{event:$e,matcher:$m,entry:$entry}'
}

# ── Build a regex entry (baked — no runtime YAML parse) ──

_build_regex_entry() {
  local prefix="$1" if_field="$2" message="$3" action="$4" timeout="$5"

  # Parse "field =~ 'pattern'"
  if [[ ! "$if_field" =~ ^([a-z_]+)[[:space:]]*=~[[:space:]]*(.+)$ ]]; then
    echo "ERROR [$prefix]: 'if' must be 'field =~ pattern' (got: $if_field)" >&2
    return 1
  fi
  local field="${BASH_REMATCH[1]}"
  local pattern="${BASH_REMATCH[2]}"
  # Strip surrounding quotes
  pattern=$(echo "$pattern" | sed "s/^[\"']//; s/[\"']$//")

  # Validate regex compiles
  echo "" | grep -E -- "$pattern" >/dev/null 2>&1; local _rc=$?
  if [[ $_rc -eq 2 ]]; then
    echo "ERROR [$prefix]: regex does not compile: $pattern" >&2; return 1
  fi

  # Bake directly into hooks.json command — no runtime YAML parse needed.
  # Shell-quote each arg so spaces/special chars survive.
  jq -n \
    --arg f "$field" --arg p "$pattern" --arg m "$message" --arg a "$action" \
    --argjson t "$timeout" \
    '{type:"command",command:("bash ${CLAUDE_PLUGIN_ROOT}/lib/regex-match.sh " + ($f | @sh) + " " + ($p | @sh) + " " + ($m | @sh) + " " + ($a | @sh)),timeout:$t}'
}

# ── Build a check entry (inline shell logic, baked as base64) ──

_build_check_entry() {
  local prefix="$1" check_script="$2" action="$3" timeout="$4"

  # Base64-encode the check script so it survives JSON + shell quoting
  local check_b64
  check_b64=$(printf '%s' "$check_script" | base64 -w0 2>/dev/null || printf '%s' "$check_script" | base64)

  jq -n \
    --arg a "$action" --arg b "$check_b64" \
    --argjson t "$timeout" \
    '{type:"command",command:("HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash ${CLAUDE_PLUGIN_ROOT}/lib/check-runner.sh " + ($a | @sh) + " " + ($b | @sh)),timeout:$t}'
}

# ── Build a script entry ──

_build_script_entry() {
  local prefix="$1" script_field="$2" timeout="$3"

  local script_path
  script_path=$(expand_tilde "$script_field")
  if [[ ! -f "$script_path" ]]; then
    echo "ERROR [$prefix]: script not found: $script_field" >&2; return 1
  fi

  jq -n \
    --arg s "$script_path" \
    --argjson t "$timeout" \
    '{type:"command",command:("HOOKLIB=${CLAUDE_PLUGIN_ROOT}/lib/hooklib.sh bash " + $s),timeout:$t}'
}
