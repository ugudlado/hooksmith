#!/bin/bash
# list.sh — Registry listing for hooksmith rules.
# Usage: list.sh [--json] [--scope user|project|all]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/parse.sh"

USER_RULES_DIR="$HOOKSMITH_USER_RULES_DIR"
PROJECT_RULES_DIR="$HOOKSMITH_PROJECT_RULES_DIR"

# ── Argument parsing ──

OUTPUT_JSON=false
SCOPE="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)   OUTPUT_JSON=true; shift ;;
    --scope)  SCOPE="$2"; shift 2 ;;
    *)        echo "list.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# Use a delimiter that never appears in field values
SEP=$'\x01'

# ── Collect rule files with scope ──

collect_rules_with_scope() {
  local seen_files=""

  if [[ "$SCOPE" == "project" || "$SCOPE" == "all" ]]; then
    if [[ -d "$PROJECT_RULES_DIR" ]]; then
      for f in "$PROJECT_RULES_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        local name; name=$(basename "$f")
        seen_files="$seen_files $name"
        echo "project${SEP}${f}"
      done
    fi
  fi

  if [[ "$SCOPE" == "user" || "$SCOPE" == "all" ]]; then
    if [[ -d "$USER_RULES_DIR" ]]; then
      for f in "$USER_RULES_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        local name; name=$(basename "$f")
        # Skip if project already has this file (project overrides user)
        if [[ "$SCOPE" == "all" && " $seen_files " == *" $name "* ]]; then
          continue
        fi
        echo "user${SEP}${f}"
      done
    fi
  fi
}

# ── Main ──

main() {
  local rules_data=()
  local user_count=0 project_count=0 disabled_count=0

  while IFS="$SEP" read -r scope file; do
    local parsed; parsed=$(parse_yaml "$file" 2>/dev/null)
    local rule_id event matcher mechanism result fail_mode enabled
    rule_id=$(get_val "$parsed" "id")
    event=$(get_val "$parsed" "event")
    matcher=$(get_val "$parsed" "matcher")
    mechanism=$(get_val "$parsed" "mechanism")
    result=$(get_val "$parsed" "result")
    fail_mode=$(get_val "$parsed" "fail_mode")
    enabled=$(get_val "$parsed" "enabled")

    [[ -z "$fail_mode" ]] && fail_mode="$HOOKSMITH_DEFAULT_FAIL_MODE"
    [[ -z "$enabled" ]] && enabled="$HOOKSMITH_DEFAULT_ENABLED"

    local display_file="$file"
    display_file="${display_file/#$HOME/~}"

    if [[ -z "$rule_id" || -z "$event" || -z "$mechanism" ]]; then
      rule_id="${rule_id:-$(basename "$file" .yaml)}"
      rules_data+=("${scope}${SEP}${file}${SEP}${rule_id}${SEP}[error]${SEP}${SEP}[error]${SEP}${SEP}open${SEP}false${SEP}${display_file}")
      if [[ "$scope" == "user" ]]; then user_count=$((user_count + 1)); fi
      if [[ "$scope" == "project" ]]; then project_count=$((project_count + 1)); fi
      continue
    fi

    rules_data+=("${scope}${SEP}${file}${SEP}${rule_id}${SEP}${event}${SEP}${matcher}${SEP}${mechanism}${SEP}${result}${SEP}${fail_mode}${SEP}${enabled}${SEP}${display_file}")

    if [[ "$scope" == "user" ]]; then user_count=$((user_count + 1)); fi
    if [[ "$scope" == "project" ]]; then project_count=$((project_count + 1)); fi
    if [[ "$enabled" == "false" ]]; then disabled_count=$((disabled_count + 1)); fi
  done < <(collect_rules_with_scope)

  local total=${#rules_data[@]}

  if [[ $total -eq 0 ]]; then
    echo "No hooksmith rules found. Create rules in ~/.config/hooksmith/rules/ or .hooksmith/rules/"
    exit 0
  fi

  # Sort by event then id (fields 4 and 3 in SEP-delimited record)
  IFS=$'\n' rules_data=($(printf '%s\n' "${rules_data[@]}" | sort -t"$SEP" -k4,4 -k3,3)); unset IFS

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    local first=true
    echo "["
    for entry in "${rules_data[@]}"; do
      IFS="$SEP" read -r scope file rule_id event matcher mechanism result fail_mode enabled display_file <<< "$entry"
      local enabled_bool
      [[ "$enabled" == "true" ]] && enabled_bool=true || enabled_bool=false
      [[ "$first" == "true" ]] && first=false || echo ","
      jq -n \
        --arg id "$rule_id" \
        --arg event "$event" \
        --arg matcher "$matcher" \
        --arg mechanism "$mechanism" \
        --arg result "$result" \
        --arg fail_mode "$fail_mode" \
        --arg scope "$scope" \
        --argjson enabled "$enabled_bool" \
        --arg file "${display_file/#$HOME/~}" \
        '{id:$id,event:$event,matcher:$matcher,mechanism:$mechanism,result:$result,fail_mode:$fail_mode,scope:$scope,enabled:$enabled,file:$file}'
    done
    echo "]"
  else
    local sep="──────────────────────────────────────────────────────────────────────────────────────"
    echo "HOOKSMITH RULES"
    echo "$sep"
    printf "%-28s %-18s %-14s %-8s %-8s %s\n" "ID" "EVENT" "MATCHER" "MECH" "RESULT" "SCOPE"
    echo "$sep"
    for entry in "${rules_data[@]}"; do
      IFS="$SEP" read -r scope file rule_id event matcher mechanism result fail_mode enabled display_file <<< "$entry"
      [[ -z "$matcher" ]] && matcher="—"
      local suffix=""
      [[ "$enabled" == "false" ]] && suffix=" [disabled]"
      [[ "$event" == "[error]" ]] && suffix=" [error]"
      printf "%-28s %-18s %-14s %-8s %-8s %s%s\n" "$rule_id" "$event" "$matcher" "$mechanism" "$result" "$scope" "$suffix"
    done
    echo "$sep"
    local summary="${total} rules (${user_count} user, ${project_count} project)"
    [[ $disabled_count -gt 0 ]] && summary="$summary · ${disabled_count} disabled"
    echo "$summary"
  fi
}

main
