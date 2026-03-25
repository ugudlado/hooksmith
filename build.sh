#!/bin/bash
# build.sh — Compiles YAML rule files into native hooks.json.
# Usage: build.sh [--rules-dir DIR] [--project-dir DIR] [--output FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/hooks/hooks.json}"

# ── Shared modules ──
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/parse.sh"
source "${SCRIPT_DIR}/lib/validate.sh"

USER_RULES_DIR="$HOOKSMITH_USER_RULES_DIR"
PROJECT_RULES_DIR="$HOOKSMITH_PROJECT_RULES_DIR"

# ── Collect rule files (project overrides user by filename) ──

collect_rules() {
  local tmpdir="$1"
  # User-level rules first
  if [[ -d "$USER_RULES_DIR" ]]; then
    for f in "$USER_RULES_DIR"/*.yaml; do
      [[ -f "$f" ]] || continue
      local name; name=$(basename "$f")
      cp "$f" "$tmpdir/$name"
    done
  fi
  # Project-level rules override by filename
  if [[ -d "$PROJECT_RULES_DIR" ]]; then
    for f in "$PROJECT_RULES_DIR"/*.yaml; do
      [[ -f "$f" ]] || continue
      local name; name=$(basename "$f")
      cp "$f" "$tmpdir/$name"
    done
  fi
}

# ── Generate a single hook entry JSON ──

generate_entry() {
  local name="$1" parsed="$2"
  local mechanism event result timeout fail_mode is_async

  mechanism=$(get_val "$parsed" "mechanism")
  event=$(get_val "$parsed" "event")
  result=$(get_val "$parsed" "result")
  timeout=$(get_val "$parsed" "timeout")
  fail_mode=$(get_val "$parsed" "fail_mode")
  is_async=$(get_val "$parsed" "async")
  apply_defaults timeout fail_mode is_async

  local rule_id
  rule_id=$(get_val "$parsed" "id")

  local entry
  case "$mechanism" in
    regex|script)
      # All command-based hooks use the hooksmith runner
      entry=$(jq -n --arg cmd "bash \${CLAUDE_PLUGIN_ROOT}/hooksmith run $rule_id" \
            --argjson t "$timeout" \
            '{type:"command",command:$cmd,timeout:$t}')
      ;;
    prompt)
      local prompt_text
      prompt_text=$(get_val "$parsed" "prompt")
      entry=$(jq -n --arg p "$prompt_text" --argjson t "$timeout" \
            '{type:"prompt",prompt:$p,timeout:$t}')
      ;;
  esac

  # Add async flag for command hooks
  if [[ "$is_async" == "true" && "$mechanism" != "prompt" ]]; then
    entry=$(echo "$entry" | jq '. + {async:true}')
  fi

  echo "$entry"
}

# ── Main ──

main() {
  TMPDIR_CLEANUP=$(mktemp -d)
  local tmpdir="$TMPDIR_CLEANUP"
  trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT

  collect_rules "$tmpdir"

  # Check if any rules found
  local rule_files=()
  for f in "$tmpdir"/*.yaml; do
    [[ -f "$f" ]] && rule_files+=("$f")
  done

  if [[ ${#rule_files[@]} -eq 0 ]]; then
    echo "WARNING: No rule files found." >&2
    echo '{"hooks":{}}' | jq '.' > "$OUTPUT"
    echo "Generated $OUTPUT with 0 rules."
    return 0
  fi

  # Sort rule files alphabetically
  IFS=$'\n' rule_files=($(printf '%s\n' "${rule_files[@]}" | sort)); unset IFS

  # Process each rule — collect entries grouped by event|matcher
  local groups_dir="$tmpdir/groups"
  mkdir -p "$groups_dir"
  local count=0 errors=0
  local seen_ids=""  # space-separated list for uniqueness tracking

  for rule_file in "${rule_files[@]}"; do
    local name; name=$(basename "$rule_file" .yaml)
    local parsed; parsed=$(parse_yaml "$rule_file")

    # Skip disabled rules
    local enabled; enabled=$(get_val "$parsed" "enabled")
    if [[ "$enabled" == "false" ]]; then
      continue
    fi

    # Validate
    if ! validate_rule "$name" "$parsed"; then
      errors=$((errors + 1))
      continue
    fi

    # Check id uniqueness (post-merge set)
    local rule_id; rule_id=$(get_val "$parsed" "id")
    if [[ " $seen_ids " == *" $rule_id "* ]]; then
      echo "ERROR [$name]: duplicate id '$rule_id'" >&2
      errors=$((errors + 1))
      continue
    fi
    seen_ids="$seen_ids $rule_id"

    # Generate entry
    local entry; entry=$(generate_entry "$name" "$parsed")
    local event matcher group_key
    event=$(get_val "$parsed" "event")
    matcher=$(get_val "$parsed" "matcher")
    group_key="${event}|${matcher}"

    # Append to group file (one JSON object per line)
    local group_file="$groups_dir/$(echo "$group_key" | sed 's/[^a-zA-Z0-9|]/_/g')"
    echo "$group_key" > "$group_file.key"
    echo "$entry" >> "$group_file.entries"
    count=$((count + 1))
  done

  # Assemble hooks.json
  local hooks_json='{"hooks":{}}'

  for key_file in "$groups_dir"/*.key; do
    [[ -f "$key_file" ]] || continue
    local group_key; group_key=$(cat "$key_file")
    local base; base="${key_file%.key}"
    local entries_file="$base.entries"
    [[ -f "$entries_file" ]] || continue

    local event matcher
    event="${group_key%%|*}"
    matcher="${group_key#*|}"

    # Build hooks array from entries file
    local hooks_array; hooks_array=$(jq -s '.' "$entries_file")

    # Build the matcher group object
    local group_obj
    if [[ -n "$matcher" ]]; then
      group_obj=$(jq -n --arg m "$matcher" --argjson h "$hooks_array" '{matcher:$m,hooks:$h}')
    else
      group_obj=$(jq -n --argjson h "$hooks_array" '{hooks:$h}')
    fi

    # Append to the event's array in hooks_json
    hooks_json=$(echo "$hooks_json" | jq --arg e "$event" --argjson g "$group_obj" \
      '.hooks[$e] = (.hooks[$e] // []) + [$g]')
  done

  # Write output
  mkdir -p "$(dirname "$OUTPUT")"
  echo "$hooks_json" | jq '.' > "$OUTPUT"

  if [[ $errors -gt 0 ]]; then
    echo "Generated $OUTPUT with $count rules ($errors rules skipped due to errors)."
  else
    echo "Generated $OUTPUT with $count rules."
  fi
}

main "$@"
