#!/bin/bash
# hooklib.sh — Shared helpers for hooksmith script rules.
# Source this in your script: source "$HOOKLIB"

deny() {
  jq -n --arg r "${1:-Blocked by hook rule}" \
    '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

ask() {
  jq -n --arg r "${1:-Manual approval required}" \
    '{hookSpecificOutput:{permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

context() {
  jq -n --arg c "$1" '{hookSpecificOutput:{permissionDecision:"allow",additionalContext:$c}}'
  exit 0
}

block_stop() {
  jq -n --arg r "${1:-Blocked}" '{decision:"block",reason:$r}'
  exit 0
}

read_input() { [[ -n "${INPUT:-}" ]] && return; INPUT=$(cat); export INPUT; }

get_field() {
  local field="$1" json="${INPUT:-$(cat)}"
  case "$field" in
    command)     echo "$json" | jq -r '.tool_input.command // empty' ;;
    file_path)   echo "$json" | jq -r '.tool_input.file_path // empty' ;;
    content)     echo "$json" | jq -r '.tool_input.content // .tool_input.new_string // empty' ;;
    user_prompt) echo "$json" | jq -r '.user_prompt // empty' ;;
    tool_name)   echo "$json" | jq -r '.tool_name // empty' ;;
    cwd)         echo "$json" | jq -r '.cwd // empty' ;;
    *)           echo "$json" | jq -r --arg f "$field" '.tool_input[$f] // .[$f] // empty' ;;
  esac
}

log() { echo "[hooksmith] $*" >&2; }
