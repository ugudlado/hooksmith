#!/bin/bash
# convert.sh — Converts hooks from settings.json into hooksmith YAML rules.
# Usage: convert.sh [--apply] [--scope user|project] [--output-dir DIR]
#
# Default: dry-run mode — prints what would be generated without writing files.
# --apply     Write YAML rule files to the output directory
# --scope     Which settings.json to read: "user" (~/.claude/) or "project" (.claude/)
# --output-dir  Override output directory (default: ~/.config/hooksmith/hooks for user scope)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../core/config.sh"

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
      echo "  --output-dir  Output directory (default: ~/.config/hooksmith/hooks for user, .hooksmith/hooks for project)"
      echo ""
      echo "Hooks that are skipped:"
      echo "  - Plugin hooks (contain \${CLAUDE_PLUGIN_ROOT})"
      echo "  - type: http or type: agent hooks"
      echo "  - type: prompt hooks (not supported by hooksmith eval)"
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
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$HOME/.config/hooksmith/hooks"
    ;;
  project)
    SETTINGS_FILE=".claude/settings.json"
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR=".hooksmith/hooks"
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

uses_updated_input() {
  local cmd="$1"
  local script_path=""
  script_path=$(extract_script_path "$cmd")
  script_path=$(expand_tilde "$script_path")

  if [[ -n "$script_path" && -f "$script_path" ]]; then
    grep -q 'updatedInput' "$script_path" 2>/dev/null
    return $?
  fi

  echo "$cmd" | grep -q 'updatedInput' 2>/dev/null
  return $?
}

detect_action() {
  local cmd="$1"
  local script_path=""
  script_path=$(extract_script_path "$cmd")
  script_path=$(expand_tilde "$script_path")

  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local content
    content=$(cat "$script_path" 2>/dev/null || true)
    if echo "$content" | grep -q 'permissionDecision.*deny\|"deny"\|deny "'; then
      echo "deny"
    elif echo "$content" | grep -q 'permissionDecision.*ask\|"ask"\|ask "'; then
      echo "ask"
    elif echo "$content" | grep -q 'decision.*block\|block_stop'; then
      echo "deny"
    elif echo "$content" | grep -q 'additionalContext\|context "'; then
      echo "context"
    else
      echo "context"
    fi
    return
  fi

  echo "context"
}

# ── Process hooks ──

converted=0
skipped=0
skipped_reasons=()

declare -A file_rules

EVENTS=$(echo "$HOOKS_JSON" | jq -r 'keys[]')

for event in $EVENTS; do
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

      # ── Skip conditions ──

      if echo "$HOOK_CMD" | grep -q 'CLAUDE_PLUGIN_ROOT'; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [plugin]: $event${MATCHER:+ ($MATCHER)} — contains \${CLAUDE_PLUGIN_ROOT}")
        continue
      fi

      if [[ "$HOOK_TYPE" == "http" || "$HOOK_TYPE" == "agent" ]]; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [unsupported type]: $event${MATCHER:+ ($MATCHER)} — type: $HOOK_TYPE")
        continue
      fi

      if [[ "$HOOK_TYPE" == "prompt" ]]; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [prompt]: $event${MATCHER:+ ($MATCHER)} — prompt hooks not supported by hooksmith eval")
        continue
      fi

      if [[ "$HOOK_TYPE" == "command" ]] && uses_updated_input "$HOOK_CMD"; then
        skipped=$((skipped + 1))
        skipped_reasons+=("  SKIP [updatedInput]: $event${MATCHER:+ ($MATCHER)} — script uses updatedInput")
        continue
      fi

      # ── Generate rule in new schema ──

      local_slug=$(slugify "${event}${MATCHER:+-$MATCHER}")
      if [[ $HOOK_COUNT -gt 1 ]]; then
        local_slug="${local_slug}-$((hi + 1))"
      fi

      ON_FIELD="$event"
      [[ -n "$MATCHER" ]] && ON_FIELD="$event $MATCHER"

      ACTION=$(detect_action "$HOOK_CMD")

      SCRIPT_PATH=$(extract_script_path "$HOOK_CMD")

      RULE_YAML="  - name: ${local_slug}\n"
      RULE_YAML+="    on: ${ON_FIELD}\n"

      if [[ -n "$SCRIPT_PATH" ]]; then
        SCRIPT_PATH="${SCRIPT_PATH/#"$HOME"/\~}"
        RULE_YAML+="    run: ${SCRIPT_PATH}\n"
      else
        RULE_YAML+="    # TODO: extract inline command to a .sh script\n"
        RULE_YAML+="    # Original command: ${HOOK_CMD}\n"
        RULE_YAML+="    run: \"# FIXME: provide script path or inline script\"\n"
      fi

      RULE_YAML+="    ${ACTION}: \"Triggered by ${local_slug}\"\n"

      [[ -n "$HOOK_TIMEOUT" && "$HOOK_TIMEOUT" != "null" && "$HOOK_TIMEOUT" != "10" ]] && \
        RULE_YAML+="    # timeout: ${HOOK_TIMEOUT}\n"

      FILENAME="${local_slug}.yaml"
      file_rules["$FILENAME"]="${file_rules[$FILENAME]:-}${RULE_YAML}"

      converted=$((converted + 1))
    done
  done
done

# ── Output ──

for FILENAME in $(echo "${!file_rules[@]}" | tr ' ' '\n' | sort); do
  YAML="# Converted from ${SCOPE} settings.json\nrules:\n${file_rules[$FILENAME]}"

  if $DRY_RUN; then
    echo "--- $FILENAME ---"
    printf '%b' "$YAML"
    echo ""
  else
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
