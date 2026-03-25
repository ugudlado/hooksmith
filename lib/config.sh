#!/bin/bash
# config.sh — Shared constants, defaults, and debug logging for hooksmith.
# Source this file from any hooksmith script.

# ── Directory defaults ──

HOOKSMITH_USER_RULES_DIR="${USER_RULES_DIR:-$HOME/.config/hooksmith/rules}"
HOOKSMITH_PROJECT_RULES_DIR="${PROJECT_RULES_DIR:-.hooksmith/rules}"

# ── Defaults ──

HOOKSMITH_DEFAULT_TIMEOUT=10
HOOKSMITH_DEFAULT_FAIL_MODE="open"
HOOKSMITH_DEFAULT_ASYNC="false"
HOOKSMITH_DEFAULT_ENABLED="true"

# ── Debug logging ──
# Set HOOKSMITH_DEBUG=1 to enable debug output on stderr.

debug() {
  if [[ "${HOOKSMITH_DEBUG:-}" == "1" ]]; then
    echo "[hooksmith:debug] $*" >&2
  fi
}

# ── Valid events ──

_HOOKSMITH_EVENTS=(
  PreToolUse PostToolUse PostToolUseFailure PermissionRequest
  Stop StopFailure
  UserPromptSubmit
  SessionStart SessionEnd
  SubagentStart SubagentStop
  TeammateIdle TaskCompleted Notification
  PreCompact PostCompact
  ConfigChange InstructionsLoaded
  WorktreeCreate WorktreeRemove
  Elicitation ElicitationResult
)

valid_event() {
  local event="$1" e
  for e in "${_HOOKSMITH_EVENTS[@]}"; do
    [[ "$e" == "$event" ]] && return 0
  done
  return 1
}

# ── Result-event compatibility ──

valid_result_event() {
  local result="$1" event="$2"
  case "$result" in
    deny)    [[ "$event" == "PreToolUse" || "$event" == "PostToolUse" || \
                "$event" == "Stop" || "$event" == "UserPromptSubmit" || \
                "$event" == "SubagentStop" ]] ;;
    ask)     [[ "$event" == "PreToolUse" ]] ;;
    warn)    return 0 ;;
    context) return 0 ;;
    *)       return 1 ;;
  esac
}

# ── Prompt-compatible events (command-only events excluded) ──

prompt_event_ok() {
  local event="$1"
  case "$event" in
    SessionStart|SessionEnd|PreCompact|PostCompact|InstructionsLoaded|\
    WorktreeCreate|WorktreeRemove) return 1 ;;
    *) return 0 ;;
  esac
}

# ── Script path extraction ──
# Extracts a .sh file path from a command string.
# Used by convert.sh and anywhere else that needs to find the script in a command.

extract_script_path() {
  local cmd="$1"
  echo "$cmd" | grep -oE '(/[^ ]+\.sh|~/[^ ]+\.sh)' | tail -1
}

# ── Expand tilde in paths ──

expand_tilde() {
  echo "${1/#\~/$HOME}"
}

# ── Apply defaults to parsed rule values ──

apply_defaults() {
  local -n _timeout="$1" _fail_mode="$2" _is_async="$3"
  [[ -z "$_timeout" ]]   && _timeout="$HOOKSMITH_DEFAULT_TIMEOUT"
  [[ -z "$_fail_mode" ]] && _fail_mode="$HOOKSMITH_DEFAULT_FAIL_MODE"
  [[ -z "$_is_async" ]]  && _is_async="$HOOKSMITH_DEFAULT_ASYNC"
}
