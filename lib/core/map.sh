#!/bin/bash
# map.sh — Shared rule map (auto-indexing) for hooksmith.
# Provides _rule_files, _map_is_fresh, _build_map, _ensure_map.
# Source this file from eval.sh and init.sh.
#
# Map v2 format: event-keyed with cached rules.
#   {"PreToolUse":[{"name":"block-rm","file":"...","index":0,"matcher":"Bash","rule":{...}}], ...}
#
# Requires: config.sh must be sourced first (for debug and _yq_json).

_default_map_dir="$HOME/.config/hooksmith"
if [[ -z "${MAP_FILE:-}" ]]; then
  mkdir -p "$_default_map_dir" 2>/dev/null
  if touch "$_default_map_dir/.map.json" 2>/dev/null; then
    MAP_FILE="$_default_map_dir/.map.json"
  else
    MAP_FILE="${TMPDIR:-/tmp}/.hooksmith-map.json"
  fi
fi

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
  map_files=$(jq -r '[.[]] | add // [] | .[].file' "$MAP_FILE" 2>/dev/null | sort -u)
  [[ "$current_files" == "$map_files" ]] || return 1

  return 0
}

# ── Build the map: event-keyed with cached rules ──

_build_map() {
  debug "map: rebuilding $MAP_FILE"
  local tmp_entries
  tmp_entries=$(mktemp "${TMPDIR:-${MAP_FILE%/*}}/.map_build.XXXXXX")
  trap "rm -f '$tmp_entries'" RETURN

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(_yq_json '.rules | length' "$rule_file")
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local i
    for (( i=0; i<rule_count; i++ )); do
      local rule_json
      rule_json=$(_yq_json ".rules[$i]" "$rule_file")

      # Extract all validation fields in one jq call
      local fields
      fields=$(printf '%s\n' "$rule_json" | jq -r '{
        name: (.name // ""),
        enabled: (if has("enabled") then (.enabled | tostring) else "unset" end),
        on: (.on // ""),
        has_mech: (if (has("match") or has("run") or has("prompt")) then "yes" else "" end),
        has_action: (if (has("deny") or has("ask") or has("context")) then "yes" else "" end)
      } | "\(.name)\n\(.enabled)\n\(.on)\n\(.has_mech)\n\(.has_action)"')

      local name enabled on_field has_mechanism has_action
      { read -r name; read -r enabled; read -r on_field; read -r has_mechanism; read -r has_action; } <<< "$fields"

      [[ "$enabled" == "false" ]] && continue

      if [[ -z "$name" ]]; then
        debug "map: WARNING $rule_file rules[$i]: missing 'name' field, skipping"
        continue
      fi
      if [[ -z "$on_field" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing 'on' field, skipping"
        continue
      fi
      if [[ -z "$has_mechanism" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing 'match', 'run', or 'prompt' field, skipping"
        continue
      fi
      if [[ -z "$has_action" ]]; then
        debug "map: WARNING $rule_file rules[$i] ($name): missing action (deny/ask/context), skipping"
        continue
      fi

      # Split "on" field into event + matcher
      on_field=$(echo "$on_field" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
      local event="${on_field%% *}"
      local matcher="${on_field#"$event"}"
      matcher="${matcher# }"

      # Build map entry with event key, matcher, and cached rule
      printf '%s\n' "$rule_json" | jq -c \
        --arg file "$rule_file" --argjson idx "$i" \
        --arg event "$event" --arg matcher "$matcher" \
        '{event:$event, entry:{name:.name, file:$file, index:$idx, matcher:$matcher, rule:.}}' >> "$tmp_entries"
    done
  done < <(_rule_files)

  # Group entries by event into {event: [entries...]}
  mkdir -p "$(dirname "$MAP_FILE")"
  if [[ -s "$tmp_entries" ]]; then
    jq -s 'group_by(.event) | map({key:.[0].event, value:[.[].entry]}) | from_entries' "$tmp_entries" > "$MAP_FILE"
  else
    echo '{}' > "$MAP_FILE"
  fi
  debug "map: indexed $(_map_rule_count) rules"
}

# ── Count total rules across all events ──

_map_rule_count() {
  jq '[.[]] | add // [] | length' "$MAP_FILE" 2>/dev/null || echo 0
}

_ensure_map() {
  if ! _map_is_fresh; then
    _build_map
  fi
}
