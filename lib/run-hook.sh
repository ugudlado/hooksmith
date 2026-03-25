#!/bin/bash
# run-hook.sh — Unified hook runner for compact rules.
#
# Usage: run-hook.sh <action> <base64-encoded-script-or-path>
#
# The script (inline or file) follows one contract:
#   - Gets $INPUT (hook context JSON) and get_field/read_input helpers
#   - Outputs a reason string to stdout (the "why")
#   - If output is non-empty → the action fires with that reason
#   - If output is empty → pass through (allow)
#
# At build time, the compiler detects whether "run" is a file path or
# inline code. Either way it arrives here as base64-encoded content.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKLIB="${HOOKLIB:-${SCRIPT_DIR}/hooklib.sh}"
source "$HOOKLIB"

ACTION="$1"
PAYLOAD_B64="$2"

# Read hook context from stdin
read_input

# Decode and execute — stderr flows through to Claude Code
SCRIPT_CONTENT=$(echo "$PAYLOAD_B64" | base64 -d)
REASON=$(eval "$SCRIPT_CONTENT")

# If the script produced a reason, fire the action
if [[ -n "$REASON" ]]; then
  case "$ACTION" in
    deny)    deny "$REASON" ;;
    ask)     ask "$REASON" ;;
    warn)    warn "$REASON" ;;
    context) context "$REASON" ;;
  esac
fi

# No reason → pass through (allow)
exit 0
