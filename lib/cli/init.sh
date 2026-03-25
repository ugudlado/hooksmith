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

echo "Generated $OUTPUT"
echo "Events registered: ${EVENTS}"
echo ""
echo "Rules are evaluated live from hooksmith.yaml — no build step needed."
echo "Edit your rules in .hooksmith/hooksmith.yaml or ~/.config/hooksmith/hooksmith.yaml"
