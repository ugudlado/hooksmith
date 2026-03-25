#!/bin/bash
# check-runner.sh — Runs inline check scripts from compact rules.
#
# Usage: check-runner.sh <action> <base64-encoded-check>
#
# The check script:
#   - Gets $INPUT (hook context JSON) and get_field helper
#   - Outputs a reason string (the "why") to stdout
#   - If output is non-empty → the action fires with that reason
#   - If output is empty → pass through (allow)
#
# This lets compact rules embed complex logic without separate script files:
#
#   rules:
#     - on: PreToolUse Bash
#       check: |
#         cmd=$(get_field command)
#         [[ "$cmd" =~ ^sudo ]] && echo "Root access not allowed"
#       deny: true
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKLIB="${HOOKLIB:-${SCRIPT_DIR}/hooklib.sh}"
source "$HOOKLIB"

ACTION="$1"
CHECK_B64="$2"

# Read hook context from stdin
read_input

# Decode and execute the check script
CHECK_SCRIPT=$(echo "$CHECK_B64" | base64 -d)
REASON=$(eval "$CHECK_SCRIPT" 2>/dev/null)

# If check produced a reason, fire the action
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
