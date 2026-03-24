#!/bin/bash
# auto-build.sh — Runs at SessionStart, rebuilds hooks.json only if rules changed.
# Change detection: compares checksum of all rule files against last build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USER_RULES_DIR="${USER_RULES_DIR:-$HOME/.config/hooksmith/rules}"
PROJECT_RULES_DIR="${PROJECT_RULES_DIR:-.hooksmith/rules}"
CHECKSUM_FILE="$SCRIPT_DIR/hooks/.rules-checksum"

# Compute checksum of all rule files (content + filenames)
compute_checksum() {
  local checksum=""
  for dir in "$USER_RULES_DIR" "$PROJECT_RULES_DIR"; do
    if [[ -d "$dir" ]]; then
      for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        checksum+="$(basename "$f"):$(cat "$f" | shasum -a 256 | cut -d' ' -f1);"
      done
    fi
  done
  # If no rules, use empty marker
  [[ -z "$checksum" ]] && checksum="EMPTY"
  echo "$checksum" | shasum -a 256 | cut -d' ' -f1
}

current=$(compute_checksum)

# Check if rebuild needed
if [[ -f "$CHECKSUM_FILE" ]]; then
  previous=$(cat "$CHECKSUM_FILE")
  if [[ "$current" == "$previous" ]]; then
    # No changes — skip build
    exit 0
  fi
fi

# Rules changed — rebuild
echo "[hooksmith] Rules changed, rebuilding hooks.json..." >&2
bash "$SCRIPT_DIR/build.sh" >&2

# Save checksum for next check
echo "$current" > "$CHECKSUM_FILE"

# Notify user that rebuild happened (changes take effect next session)
jq -n '{systemMessage:"[hooksmith] hooks.json was rebuilt because rule files changed. Changes will take effect on your next session."}'
exit 0
