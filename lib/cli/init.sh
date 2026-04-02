#!/bin/bash
# init.sh — Generates hooks.json routing table for hooksmith eval.
# Scans all rules to find which events are used, then registers exactly
# those events (plus SessionStart for auto-init on next session).
#
# Usage: hooksmith init
#
# No flags needed. Run manually or let eval.sh call it on SessionStart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
OUTPUT="${OUTPUT:-${PLUGIN_ROOT}/hooks/hooks.json}"

source "${SCRIPT_DIR}/../core/config.sh"
source "${SCRIPT_DIR}/../core/map.sh"

# ── Build map first (ensures it's fresh) ──
_build_map
map_count=$(jq 'length' "$MAP_FILE")

# ── Collect events from all rules ──
# Always include SessionStart so eval can auto-init on next session.
declare -A events
events[SessionStart]=1

while IFS= read -r rule_file; do
  [[ -z "$rule_file" ]] && continue
  local_count=$(_yq_json '.rules | length' "$rule_file")
  [[ -z "$local_count" || "$local_count" == "0" ]] && continue

  for (( i=0; i<local_count; i++ )); do
    on_field=$(_yq_json ".rules[$i].on" "$rule_file" | jq -r '. // empty' 2>/dev/null)
    [[ -z "$on_field" ]] && continue
    # Event is the first word
    event="${on_field%% *}"
    events["$event"]=1
  done
done < <(_rule_files)

# ── Build hooks.json ──
hooks_json='{"hooks":{}}'

for event in "${!events[@]}"; do
  hooks_json=$(echo "$hooks_json" | jq --arg e "$event" \
    '.hooks[$e] = [{"hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooksmith eval","timeout":10}]}]')
done

# ── Write ──
mkdir -p "$(dirname "$OUTPUT")"
echo "$hooks_json" | jq '.' > "$OUTPUT"

event_list=$(printf '%s\n' "${!events[@]}" | sort | tr '\n' ',' | sed 's/,$//')
debug "init: generated $OUTPUT with events: $event_list ($map_count rules)"

# Only print to stdout when run directly (not from eval.sh)
if [[ "${HOOKSMITH_SILENT_INIT:-}" != "1" ]]; then
  echo "Generated $OUTPUT"
  echo "Events: $event_list"
  echo "Rules: $map_count indexed"
fi
