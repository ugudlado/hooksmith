#!/bin/bash
# convert.sh — Converts hooks from settings.json into hooksmith YAML rules.
# Usage: convert.sh [--apply] [--scope user|project] [--output-dir DIR]
#
# Default: dry-run mode — prints what would be generated without writing files.
# --apply     Write YAML rule files to the output directory
# --scope     Which settings.json to read: "user" (~/.claude/) or "project" (.claude/)
# --output-dir  Override output directory (default: ~/.config/hooksmith/rules for user scope)
set -euo pipefail

# ── Defaults ──

DRY_RUN=true
SCOPE="user"
OUTPUT_DIR=""

# ── Parse args ──

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     DRY_RUN=false; shift ;;
    --scope)     SCOPE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: convert.sh [--apply] [--scope user|project] [--output-dir DIR]"
      echo ""
      echo "Converts hooks from settings.json into hooksmith YAML rule files."
      echo ""
      echo "Options:"
      echo "  --apply       Write YAML files (default: dry-run, just preview)"
      echo "  --scope       Source: 'user' (~/.claude/settings.json) or 'project' (.claude/settings.json)"
      echo "  --output-dir  Output directory (default: ~/.config/hooksmith/rules for user, .hooksmith/rules for project)"
      echo ""
      echo "Hooks that are skipped:"
      echo "  - Plugin hooks (contain \${CLAUDE_PLUGIN_ROOT})"
      echo "  - type: http or type: agent hooks"
      echo "  - Scripts that use updatedInput (detected via grep)"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Resolve paths ──

case "$SCOPE" in
  user)
    SETTINGS_FILE="$HOME/.claude/settings.json"
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$HOME/.config/hooksmith/rules"
    ;;
  project)
    SETTINGS_FILE=".claude/settings.json"
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR=".hooksmith/rules"
    ;;
  *)
    echo "ERROR: --scope must be 'user' or 'project'" >&2
    exit 1
    ;;
esac

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "ERROR: Settings file not found: $SETTINGS_FILE" >&2
  exit 1
fi

# ── Check for hooks ──

HOOKS_JSON=$(jq -r '.hooks // empty' "$SETTINGS_FILE")
if [[ -z "$HOOKS_JSON" || "$HOOKS_JSON" == "null" || "$HOOKS_JSON" == "{}" ]]; then
  echo "No hooks found in $SETTINGS_FILE"
  exit 0
fi

# ── Helpers ──

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# Check if a command script uses updatedInput
uses_updated_input() {
  local cmd="$1"
  # Extract the script path from the command string
  # Hooks can be: "bash /path/to/script.sh" or "/path/to/script.sh" or "bash -c '...'"
  local script_path=""

  # Try to find a .sh file path in the command
  script_path=$(echo "$cmd" | grep -oE '(/[^ ]+\.sh|~/[^ ]+\.sh)' | tail -1)

  # Expand ~ if present
  script_path="${script_path/#\~/$HOME}"

  if [[ -n "$script_path" && -f "$script_path" ]]; then
    grep -q 'updatedInput' "$script_path" 2>/dev/null
    return $?
  fi

  # If we can't find the script, check the command string itself
  echo "$cmd" | grep -q 'updatedInput' 2>/dev/null
  return $?
}

# Determine result type by reading a script's output patterns
detect_result() {
  local cmd="$1" hook_type="$2"

  if [[ "$hook_type" == "prompt" ]]; then
    # Prompt hooks: scan the prompt text for decision patterns
    if echo "$cmd" | grep -q 'permissionDecision.*deny\|"deny"'; then
      echo "deny"
    elif echo "$cmd" | grep -q 'permissionDecision.*ask\|"ask"'; then
      echo "ask"
    elif echo "$cmd" | grep -q 'decision.*block\|"block"'; then
      echo "deny"
    else
      echo "warn"
    fi
    return
  fi

  # For command hooks, try reading the script
  local script_path=""
  script_path=$(echo "$cmd" | grep -oE '(/[^ ]+\.sh|~/[^ ]+\.sh)' | tail -1)
  script_path="${script_path/#\~/$HOME}"

  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local content
    content=$(cat "$script_path" 2>/dev/null || true)
    if echo "$content" | grep -q 'permissionDecision.*deny\|"deny"\|deny "'; then
      echo "deny"
    elif echo "$content" | grep -q 'permissionDecision.*ask\|"ask"\|ask "'; then
      echo "ask"
    elif echo "$content" | grep -q 'decision.*block\|block_stop'; then
      echo "deny"
    elif echo "$content" | grep -q 'systemMessage\|warn "'; then
      echo "warn"
    elif echo "$content" | grep -q 'additionalContext\|context "'; then
      echo "context"
    else
      echo "warn"
    fi
    return
  fi

  echo "warn"
}

# ── Process hooks ──

converted=0
skipped=0
skipped_reasons=()

# Get all event names
EVENTS=$(echo "$HOOKS_JSON" | jq -r 'keys[]')

for event in $EVENTS; do
  # Iterate over matcher groups within this event
  GROUP_COUNT=$(echo "$HOOKS_JSON" | jq -r --arg e "$event" '.[$e] | length')

  for (( gi=0; gi<GROUP_COUNT; gi++ )); do
    GROUP=$(echo "$HOOKS_JSON" | jq -r --arg e "$event" --argjson i "$gi" '.[$e][$i]')
    MATCHER=$(echo "$GROUP" | jq -r '.matcher // ""')
    HOOK_COUNT=$(echo "$GROUP" | jq -r '.hooks | length')

    for (( hi=0; hi<HOOK_COUNT; hi++ )); do
      HOOK=$(echo "$GROUP" | jq -r --argjson i "$hi" '.hooks[$i]')
      HOOK_TYPE=$(echo "$HOOK" | jq -r '.type')
      HOOK_CMD=$(echo "$HOOK" | jq -r '.command // .prompt // ""')
      HOOK_TIMEOUT=$(echo "$HOOK" | jq -r '.timeout // empty')
      HOOK_ASYNC=$(echo "$HOOK" | jq -r '.async // empty')

      # ── Skip conditions ──

      # Skip plugin hooks
      if echo "$HOOK_CMD" | grep -q 'CLAUDE_PLUGIN_ROOT'; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [plugin]: $event${MATCHER:+ ($MATCHER)} — contains \${CLAUDE_PLUGIN_ROOT}")
        continue
      fi

      # Skip unsupported types
      if [[ "$HOOK_TYPE" == "http" || "$HOOK_TYPE" == "agent" ]]; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [unsupported type]: $event${MATCHER:+ ($MATCHER)} — type: $HOOK_TYPE")
        continue
      fi

      # Skip updatedInput hooks (option B)
      if [[ "$HOOK_TYPE" == "command" ]] && uses_updated_input "$HOOK_CMD"; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [updatedInput]: $event${MATCHER:+ ($MATCHER)} — script uses updatedInput")
        continue
      fi

      # ── Generate YAML ──

      # Build filename
      local_slug=$(slugify "${event}${MATCHER:+-$MATCHER}")
      # Add index suffix if multiple hooks in same group
      if [[ $HOOK_COUNT -gt 1 ]]; then
        local_slug="${local_slug}-$((hi + 1))"
      fi
      FILENAME="${local_slug}.yaml"

      # Detect mechanism and result
      RESULT=$(detect_result "$HOOK_CMD" "$HOOK_TYPE")

      # Derive id from filename (strip .yaml extension)
      RULE_ID="${local_slug}"
      # Ensure id is valid kebab-case (slugify already handles this)
      if [[ ! "$RULE_ID" =~ ^[a-z0-9-]+$ ]]; then
        RULE_ID=$(slugify "$RULE_ID")
      fi

      # Build YAML content — id first, then event
      YAML="# Converted from ${SCOPE} settings.json\n"
      YAML+="id: ${RULE_ID}\n"
      YAML+="event: ${event}\n"
      [[ -n "$MATCHER" ]] && YAML+="matcher: ${MATCHER}\n"

      if [[ "$HOOK_TYPE" == "prompt" ]]; then
        YAML+="mechanism: prompt\n"
        YAML+="result: ${RESULT}\n"
        # Multi-line prompt — indent each line under YAML block scalar
        YAML+="prompt: |\n"
        indented_prompt=$(echo "$HOOK_CMD" | sed 's/^/  /')
        YAML+="${indented_prompt}\n"
      elif [[ "$HOOK_TYPE" == "command" ]]; then
        # Extract script path for script mechanism
        SCRIPT_PATH=$(echo "$HOOK_CMD" | grep -oE '(/[^ ]+\.sh|~/[^ ]+\.sh)' | tail -1 || true)
        if [[ -n "$SCRIPT_PATH" ]]; then
          # Collapse $HOME back to ~
          SCRIPT_PATH="${SCRIPT_PATH/#"$HOME"/\~}"
          YAML+="mechanism: script\n"
          YAML+="result: ${RESULT}\n"
          YAML+="script: ${SCRIPT_PATH}\n"
        else
          # Inline command — wrap as script
          YAML+="mechanism: script\n"
          YAML+="result: ${RESULT}\n"
          YAML+="# TODO: extract this inline command into a standalone .sh script\n"
          YAML+="# Original command: ${HOOK_CMD}\n"
          YAML+="script: # FIXME: provide script path\n"
        fi
      fi

      # Optional fields
      [[ -n "$HOOK_TIMEOUT" && "$HOOK_TIMEOUT" != "null" ]] && YAML+="timeout: ${HOOK_TIMEOUT}\n"
      [[ -n "$HOOK_ASYNC" && "$HOOK_ASYNC" != "null" && "$HOOK_ASYNC" != "false" ]] && YAML+="async: true\n"

      # ── Output ──

      if $DRY_RUN; then
        echo "--- $FILENAME ---"
        printf '%b' "$YAML"
        echo ""
      else
        # Check for existing file
        TARGET="$OUTPUT_DIR/$FILENAME"
        if [[ -f "$TARGET" ]]; then
          echo "  EXISTS: $TARGET — skipping (won't overwrite)" >&2
          skipped=$((skipped + 1))
          skipped_reasons+=("  SKIP [exists]: $FILENAME — file already exists in output directory")
          continue
        fi
        mkdir -p "$OUTPUT_DIR"
        printf '%b' "$YAML" > "$TARGET"
        echo "  CREATED: $TARGET"
      fi

      converted=$((converted + 1))
    done
  done
done

# ── Summary ──

echo ""
if $DRY_RUN; then
  echo "=== DRY RUN SUMMARY ==="
  echo "Would convert: $converted hook(s)"
else
  echo "=== CONVERSION SUMMARY ==="
  echo "Converted: $converted hook(s)"
fi

if [[ $skipped -gt 0 ]]; then
  echo "Skipped: $skipped hook(s)"
  for reason in "${skipped_reasons[@]}"; do
    echo "$reason"
  done
fi

if $DRY_RUN && [[ $converted -gt 0 ]]; then
  echo ""
  echo "Run with --apply to write rule files to $OUTPUT_DIR"
fi
