#!/bin/bash
# validate.sh — Rule validation for hooksmith.
# Provides validate_rule() used by build.sh.
# Requires: config.sh and parse.sh to be sourced first.

# ── Validate a single rule ──

validate_rule() {
  local name="$1" parsed="$2"
  local event mechanism result

  event=$(get_val "$parsed" "event")
  mechanism=$(get_val "$parsed" "mechanism")
  result=$(get_val "$parsed" "result")

  # Required fields
  local field
  for field in id event mechanism result; do
    if [[ -z "$(get_val "$parsed" "$field")" ]]; then
      echo "ERROR [$name]: missing required field '$field'" >&2
      return 1
    fi
  done

  # Validate id format (lowercase kebab-case)
  local rule_id
  rule_id=$(get_val "$parsed" "id")
  if [[ ! "$rule_id" =~ ^[a-z0-9-]+$ ]]; then
    echo "ERROR [$name]: id '$rule_id' must be lowercase kebab-case (a-z, 0-9, hyphens)" >&2
    return 1
  fi

  # Validate id matches filename
  if [[ "$rule_id" != "$name" ]]; then
    echo "ERROR [$name]: id '$rule_id' does not match filename '$name.yaml'" >&2
    return 1
  fi

  # Valid event name
  if ! valid_event "$event"; then
    echo "ERROR [$name]: unknown event '$event'" >&2
    return 1
  fi

  # Mutual exclusivity of mechanism fields
  local has_script has_pattern has_prompt
  has_script=$(get_val "$parsed" "script")
  has_pattern=$(get_val "$parsed" "pattern")
  has_prompt=$(get_val "$parsed" "prompt")

  case "$mechanism" in
    regex)
      if [[ -z "$(get_val "$parsed" "field")" || -z "$has_pattern" ]]; then
        echo "ERROR [$name]: regex mechanism requires 'field' and 'pattern'" >&2; return 1
      fi
      if [[ -n "$has_script" || -n "$has_prompt" ]]; then
        echo "ERROR [$name]: regex mechanism must not have 'script' or 'prompt' fields" >&2; return 1
      fi
      # Test regex compiles (safe: grep -E exits 2 on invalid regex, 1 on no match)
      echo "" | grep -E -- "$has_pattern" >/dev/null 2>&1; _rc=$?
      if [[ $_rc -eq 2 ]]; then
        echo "ERROR [$name]: regex pattern does not compile: $has_pattern" >&2; return 1
      fi
      ;;
    script)
      if [[ -z "$has_script" ]]; then
        echo "ERROR [$name]: script mechanism requires 'script' field" >&2; return 1
      fi
      if [[ -n "$has_pattern" || -n "$has_prompt" ]]; then
        echo "ERROR [$name]: script mechanism must not have 'pattern' or 'prompt' fields" >&2; return 1
      fi
      # Expand ~ and check script exists
      local script_path
      script_path=$(expand_tilde "$has_script")
      if [[ ! -f "$script_path" ]]; then
        echo "ERROR [$name]: script not found: $has_script" >&2; return 1
      fi
      ;;
    prompt)
      if [[ -z "$has_prompt" ]]; then
        echo "ERROR [$name]: prompt mechanism requires 'prompt' field" >&2; return 1
      fi
      if [[ -n "$has_script" || -n "$has_pattern" ]]; then
        echo "ERROR [$name]: prompt mechanism must not have 'script' or 'pattern' fields" >&2; return 1
      fi
      if ! prompt_event_ok "$event"; then
        echo "ERROR [$name]: prompt mechanism not supported for event '$event'" >&2; return 1
      fi
      ;;
    *)
      echo "ERROR [$name]: unknown mechanism '$mechanism'" >&2; return 1
      ;;
  esac

  # Result-event compatibility
  if ! valid_result_event "$result" "$event"; then
    echo "ERROR [$name]: result '$result' not valid for event '$event'" >&2; return 1
  fi

  return 0
}
