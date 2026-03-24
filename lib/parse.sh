#!/bin/bash
# parse.sh — Shared YAML parser for hooksmith.
# Provides parse_yaml() and get_val() functions.
# Source this file from build.sh, run.sh, or list.sh.

# ── YAML parser (flat key: value only, with multi-line support for `key: |`) ──

parse_yaml() {
  awk '
    /^#/ || /^[[:space:]]*$/ { next }
    /^[a-z_]+:[[:space:]]*\|[[:space:]]*$/ {
      key = $0; sub(/:.*/, "", key)
      multiline = 1; val = ""
      next
    }
    multiline && /^[[:space:]]/ {
      line = $0; sub(/^[[:space:]][[:space:]]/, "", line)
      val = (val == "" ? line : val "\n" line)
      next
    }
    multiline {
      print key "=" val
      multiline = 0
    }
    /^[a-z_]+:/ {
      key = $0; sub(/:.*/, "", key)
      val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
      gsub(/^["'"'"']|["'"'"']$/, "", val)
      print key "=" val
    }
    END { if (multiline) print key "=" val }
  ' "$1"
}

get_val() {
  local input="$1" key="$2"
  echo "$input" | awk -v k="$key" '
    BEGIN { found=0 }
    found && /^[a-z_]+=/ { exit }
    found { print; next }
    index($0, k "=") == 1 { sub("^" k "=", ""); print; found=1 }
  ' || true
}
