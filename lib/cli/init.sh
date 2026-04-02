#!/bin/bash
# init.sh — Rebuilds the hooksmith rule map and runs diagnostics.
#
# hooks.json is pre-registered with all events (static file in hooks/).
# This script rebuilds the map index and checks for common issues.
#
# Usage: hooksmith init
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../core/config.sh"
source "${SCRIPT_DIR}/../core/map.sh"

# ── Diagnostics ──

_doctor() {
  local warnings=0

  # Check for v1 format rules (id/event/mechanism instead of rules/name/on)
  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local has_v1_fields
    has_v1_fields=$(yq -o=json '.' "$rule_file" 2>/dev/null | jq -r 'if (has("id") or has("event") or has("mechanism")) then "v1" else empty end' 2>/dev/null)
    if [[ "$has_v1_fields" == "v1" ]]; then
      echo "  ⚠ v1 format: ${rule_file/#$HOME/~}"
      echo "    Expected v2 format with rules: array, name:, on:, match/run/prompt"
      warnings=$((warnings + 1))
    fi
  done < <(_rule_files)

  # Check for missing script files referenced by rules
  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(_yq_json '.rules | length' "$rule_file")
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    for (( i=0; i<rule_count; i++ )); do
      local run_field name
      run_field=$(_yq_json ".rules[$i].run" "$rule_file" | jq -r '. // empty' 2>/dev/null)
      name=$(_yq_json ".rules[$i].name" "$rule_file" | jq -r '. // empty' 2>/dev/null)
      [[ -z "$run_field" ]] && continue

      # Only check file references (paths with / or ~), not inline scripts
      if [[ "$run_field" == */* || "$run_field" == ~* ]]; then
        local resolved
        resolved=$(expand_tilde "$run_field")
        if [[ ! -f "$resolved" ]]; then
          echo "  ⚠ missing script: $name → ${run_field/#$HOME/~}"
          warnings=$((warnings + 1))
        fi
      fi
    done
  done < <(_rule_files)

  # Check for rules with no rule files at all
  local file_count=0
  while IFS= read -r f; do
    [[ -n "$f" ]] && file_count=$((file_count + 1))
  done < <(_rule_files)

  if [[ $file_count -eq 0 ]]; then
    echo "  ⚠ no rule files found"
    echo "    Create rules in ~/.config/hooksmith/rules/ or .hooksmith/rules/"
    warnings=$((warnings + 1))
  fi

  echo "$warnings"
}

# ── Build map ──
_build_map
map_count=$(jq 'length' "$MAP_FILE")

# ── Collect events for display ──
declare -A events
events[SessionStart]=1

while IFS= read -r rule_file; do
  [[ -z "$rule_file" ]] && continue
  local_count=$(_yq_json '.rules | length' "$rule_file")
  [[ -z "$local_count" || "$local_count" == "0" ]] && continue

  for (( i=0; i<local_count; i++ )); do
    on_field=$(_yq_json ".rules[$i].on" "$rule_file" | jq -r '. // empty' 2>/dev/null)
    [[ -z "$on_field" ]] && continue
    event="${on_field%% *}"
    events["$event"]=1
  done
done < <(_rule_files)

event_list=$(printf '%s\n' "${!events[@]}" | sort | tr '\n' ',' | sed 's/,$//')
debug "init: rebuilt map with $map_count rules, events in use: $event_list"

# ── Output ──
if [[ "${HOOKSMITH_SILENT_INIT:-}" != "1" ]]; then
  echo "Map rebuilt: ${MAP_FILE/#$HOME/~}"
  echo "Events in use: $event_list"
  echo "Rules: $map_count indexed"
  echo ""
  echo "Diagnostics"
  echo "───────────"
  warning_count=$(_doctor)
  # Last line of _doctor output is the count
  warning_count=$(echo "$warning_count" | tail -1)
  if [[ "$warning_count" -eq 0 ]]; then
    echo "  ✓ No issues found"
  fi
fi
