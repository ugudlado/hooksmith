#!/bin/bash
# match.sh — Regex field matcher for hooksmith rules.
# Args: field pattern message action
set -euo pipefail

FIELD="$1"
PATTERN="$2"
MESSAGE="${3:-Blocked by regex rule}"
ACTION="${4:-deny}"

INPUT=$(cat)
VALUE=$(echo "$INPUT" | jq -r --arg f "$FIELD" '.tool_input[$f] // .[$f] // empty')

# Assign to variable before =~ to prevent glob expansion of pattern
re="$PATTERN"
if [[ "$VALUE" =~ $re ]]; then
  case "$ACTION" in
    deny)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    ask)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}' ;;
    context)
      jq -n --arg c "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"allow",additionalContext:$c}}' ;;
  esac
fi
exit 0
