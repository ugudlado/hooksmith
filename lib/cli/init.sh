#!/bin/bash
# init.sh — Generates hooks.json routing table for hooksmith eval.
# No compilation. Just registers which events hooksmith should handle.
#
# Usage: hooksmith init [--events EVENT1,EVENT2,...] [--output FILE]
#
# Default: registers PreToolUse, PostToolUse, UserPromptSubmit, Stop.
# The generated hooks.json simply routes all events to `hooksmith eval`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT="${OUTPUT:-${PLUGIN_ROOT}/hooks/hooks.json}"

# ── Default events to register ──
DEFAULT_EVENTS="PreToolUse,PostToolUse,UserPromptSubmit,Stop"
EVENTS=""

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --events)  EVENTS="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: hooksmith init [--events EVENT1,EVENT2,...] [--output FILE]"
      echo ""
      echo "Generates a static hooks.json that routes events to hooksmith eval."
      echo "No compilation needed — rules in hooksmith.yaml are evaluated live."
      echo ""
      echo "Options:"
      echo "  --events   Comma-separated events to register (default: $DEFAULT_EVENTS)"
      echo "  --output   Output file (default: hooks/hooks.json)"
      echo ""
      echo "Available events:"
      echo "  PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,"
      echo "  Stop, StopFailure, UserPromptSubmit, SessionStart, SessionEnd,"
      echo "  SubagentStart, SubagentStop, TeammateIdle, TaskCompleted,"
      echo "  Notification, PreCompact, PostCompact, ConfigChange,"
      echo "  InstructionsLoaded, WorktreeCreate, WorktreeRemove,"
      echo "  Elicitation, ElicitationResult"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$EVENTS" ]] && EVENTS="$DEFAULT_EVENTS"

# ── Build hooks.json ──

hooks_json='{"hooks":{}}'

IFS=',' read -ra event_list <<< "$EVENTS"
for event in "${event_list[@]}"; do
  event=$(echo "$event" | tr -d ' ')  # trim whitespace
  hooks_json=$(echo "$hooks_json" | jq --arg e "$event" \
    '.hooks[$e] = [{"hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooksmith eval","timeout":10}]}]')
done

# ── Write ──
mkdir -p "$(dirname "$OUTPUT")"
echo "$hooks_json" | jq '.' > "$OUTPUT"

# ── Build rule map for fast lookups ──
source "${SCRIPT_DIR}/../core/config.sh"
MAP_FILE=".hooksmith/.map.json"

# Reuse _rule_files and _build_map logic inline
_init_rule_files() {
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

map_json="[]"
while IFS= read -r rule_file; do
  [[ -z "$rule_file" ]] && continue
  rc=$(yq '.rules | length' "$rule_file" 2>/dev/null)
  [[ -z "$rc" || "$rc" == "0" ]] && continue
  for (( i=0; i<rc; i++ )); do
    on_field=$(yq -r ".rules[$i].on // empty" "$rule_file" 2>/dev/null)
    name=$(yq -r ".rules[$i].name // \"rule-$((i+1))\"" "$rule_file" 2>/dev/null)
    enabled=$(yq -r "if .rules[$i] | has(\"enabled\") then .rules[$i].enabled | tostring else empty end" "$rule_file" 2>/dev/null)
    [[ -z "$on_field" ]] && continue
    [[ "$enabled" == "false" ]] && continue
    ev="${on_field%% *}"; mt="${on_field#"$ev"}"; mt="${mt# }"
    map_json=$(echo "$map_json" | jq -c \
      --arg name "$name" --arg event "$ev" --arg matcher "$mt" \
      --arg file "$rule_file" --argjson idx "$i" \
      '. + [{name:$name, event:$event, matcher:$matcher, file:$file, index:$idx}]')
  done
done < <(_init_rule_files)

mkdir -p "$(dirname "$MAP_FILE")"
echo "$map_json" | jq '.' > "$MAP_FILE"
map_count=$(echo "$map_json" | jq 'length')

echo "Generated $OUTPUT"
echo "Events registered: ${EVENTS}"
echo "Rule map: $MAP_FILE ($map_count rules indexed)"
echo ""
echo "Edit rules in .hooksmith/hooksmith.yaml or ~/.config/hooksmith/hooksmith.yaml"
echo "Map auto-rebuilds when rule files change."
