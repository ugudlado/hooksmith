#!/bin/bash
# map.sh — Shared rule map (auto-indexing) for hooksmith.
# Provides _rule_files, _map_is_fresh, _build_map, _ensure_map.
# Source this file from eval.sh and init.sh.
#
# Requires: config.sh must be sourced first (for debug and _yq_json).

MAP_FILE="${MAP_FILE:-.hooksmith/.map.json}"

# ── Collect all rule files ──

_rule_files() {
  # Derive base dirs from config constants (strip /rules suffix if present)
  local project_base="${HOOKSMITH_PROJECT_RULES_DIR%/rules}"
  local user_base="${HOOKSMITH_USER_RULES_DIR%/rules}"
  local dirs=("$project_base" "$user_base")
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

  # Check if any rule file is newer than the map
  while IFS= read -r f; do
    [[ "$f" -nt "$MAP_FILE" ]] && return 1
  done < <(_rule_files)

  # Check if any file in the map was deleted (file set changed)
  local current_files map_files
  current_files=$(_rule_files | sort)
  map_files=$(jq -r '.[].file' "$MAP_FILE" 2>/dev/null | sort -u)
  [[ "$current_files" == "$map_files" ]] || return 1

  return 0
}

# ── Build the map: just name, file, index ──

_build_map() {
  debug "map: rebuilding $MAP_FILE"
  local tmp_entries
  tmp_entries=$(mktemp)
  trap "rm -f '$tmp_entries'" RETURN

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(_yq_json '.rules | length' "$rule_file")
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local i
    for (( i=0; i<rule_count; i++ )); do
      local rule_json name enabled
      rule_json=$(_yq_json ".rules[$i]" "$rule_file")
      name=$(printf '%s\n' "$rule_json" | jq -r '.name // empty')
      enabled=$(printf '%s\n' "$rule_json" | jq -r 'if has("enabled") then .enabled | tostring else empty end')
      [[ "$enabled" == "false" ]] && continue

      # Validate required fields
      if [[ -z "$name" ]]; then
        debug "map: WARNING $rule_file rules[$i]: missing 'name' field, skipping"
        continue
      fi
      local on_field
      on_field=$(printf '%s\n' "$rule_json" | jq -r '.on // empty')
      if [[ -z "$on_field" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing 'on' field, skipping"
        continue
      fi
      local has_match has_run has_prompt has_action
      has_match=$(printf '%s\n' "$rule_json" | jq -r '.match // empty')
      has_run=$(printf '%s\n' "$rule_json" | jq -r '.run // empty')
      has_prompt=$(printf '%s\n' "$rule_json" | jq -r '.prompt // empty')
      if [[ -z "$has_match" && -z "$has_run" && -z "$has_prompt" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing 'match', 'run', or 'prompt' field, skipping"
        continue
      fi
      has_action=$(printf '%s\n' "$rule_json" | jq -r 'if (has("deny") or has("ask") or has("context")) then "yes" else empty end')
      if [[ -z "$has_action" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing action (deny/ask/context), skipping"
        continue
      fi

      printf '%s\n' "$rule_json" | jq -c \
        --arg file "$rule_file" --argjson idx "$i" \
        '{name:.name, file:$file, index:$idx}' >> "$tmp_entries"
    done
  done < <(_rule_files)

  mkdir -p "$(dirname "$MAP_FILE")"
  jq -s '.' "$tmp_entries" > "$MAP_FILE"
  debug "map: indexed $(jq 'length' "$MAP_FILE") rules"
}

_ensure_map() {
  if ! _map_is_fresh; then
    _build_map
  fi
}
