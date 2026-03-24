#!/bin/bash
# fail-wrapper.sh — Wraps hook commands to handle fail_mode (open/closed).
# Usage: fail-wrapper.sh <open|closed> <command...>
FAIL_MODE="$1"; shift

if output=$("$@" 2>/dev/null); then
  [[ -n "$output" ]] && echo "$output"
else
  if [[ "$FAIL_MODE" == "closed" ]]; then
    jq -n '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:"Hook script failed (fail_mode: closed)"}}'
  fi
fi
exit 0
