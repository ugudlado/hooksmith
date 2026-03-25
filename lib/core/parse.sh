#!/bin/bash
# parse.sh — YAML parser for hooksmith using yq.
# Provides parse_yaml() and get_val() functions.
# Source this file from build.sh, run.sh, or list.sh.
#
# Requires: yq (https://github.com/kislyuk/yq or https://github.com/mikefarah/yq)
#
# parse_yaml outputs JSON from a YAML file.
# get_val extracts a top-level field from that JSON.

_check_yq() {
  if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required but not installed." >&2
    echo "Install: pip install yq  (or)  brew install yq  (or)  snap install yq" >&2
    return 1
  fi
}

parse_yaml() {
  _check_yq || return 1
  yq '.' "$1" 2>/dev/null
}

get_val() {
  local json="$1" key="$2"
  # Use 'has' check to distinguish missing keys from false/null values
  echo "$json" | jq -r --arg k "$key" 'if has($k) then .[$k] | tostring else empty end' 2>/dev/null || true
}
