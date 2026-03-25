#!/bin/bash
# regex-match.sh — Generic regex matcher for hooksmith regex rules.
# Args: field pattern message result
set -euo pipefail

FIELD="$1"
PATTERN="$2"
MESSAGE="${3:-Blocked by regex rule}"
RESULT="${4:-deny}"

INPUT=$(cat)
VALUE=$(echo "$INPUT" | jq -r --arg f "$FIELD" '.tool_input[$f] // .[$f] // empty')

# Assign to variable before =~ to prevent glob expansion of pattern
re="$PATTERN"
if [[ "$VALUE" =~ $re ]]; then
  case "$RESULT" in
    deny)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    ask)
      jq -n --arg r "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}' ;;
    warn)
      jq -n --arg m "$MESSAGE" '{systemMessage:$m}' ;;
    context)
      jq -n --arg c "$MESSAGE" '{hookSpecificOutput:{permissionDecision:"allow",additionalContext:$c}}' ;;
  esac
fi
exit 0
