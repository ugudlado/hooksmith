#!/bin/bash
# list.sh — Registry listing for hooksmith rules.
# Usage: list.sh [--json] [--scope user|project|all]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../core/config.sh"
source "${SCRIPT_DIR}/../core/map.sh"

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

SEP=$'\x01'

# ── Determine scope of a rule file ──

_file_scope() {
  local file="$1"
  case "$file" in
    "$HOME"/.config/hooksmith/*|"$HOOKSMITH_USER_RULES_DIR"/*) echo "user" ;;
    *) echo "project" ;;
  esac
}

# ── Detect action type from a rule JSON ──

_detect_action() {
  local rule="$1"
  for a in deny ask context; do
    local val
    val=$(printf '%s\n' "$rule" | jq -r "if has(\"$a\") then \"$a\" else empty end")
    if [[ -n "$val" ]]; then
      echo "$a"
      return
    fi
  done
  echo "—"
}

# ── Detect mechanism from a rule JSON ──

_detect_mechanism() {
  local rule="$1"
  local has_match has_run
  has_match=$(printf '%s\n' "$rule" | jq -r '.match // empty')
  has_run=$(printf '%s\n' "$rule" | jq -r '.run // empty')
  if [[ -n "$has_match" ]]; then
    echo "match"
  elif [[ -n "$has_run" ]]; then
    echo "run"
  else
    echo "—"
  fi
}

# ── Main ──

main() {
  _ensure_map

  local rules_data=()
  local user_count=0 project_count=0 disabled_count=0

  local entry_count
  entry_count=$(jq 'length' "$MAP_FILE")

  local i
  for (( i=0; i<entry_count; i++ )); do
    local name file idx
    name=$(jq -r ".[$i].name" "$MAP_FILE")
    file=$(jq -r ".[$i].file" "$MAP_FILE")
    idx=$(jq -r ".[$i].index" "$MAP_FILE")

    local scope
    scope=$(_file_scope "$file")

    # Filter by scope
    if [[ "$SCOPE" != "all" && "$scope" != "$SCOPE" ]]; then
      continue
    fi

    local rule
    rule=$(_yq_json ".rules[$idx]" "$file" | jq -c '.' 2>/dev/null)
    [[ -z "$rule" ]] && continue

    local on_field event matcher action mechanism
    on_field=$(printf '%s\n' "$rule" | jq -r '.on // empty')
    on_field=$(echo "$on_field" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    event="${on_field%% *}"
    matcher="${on_field#"$event"}"
    matcher="${matcher# }"

    action=$(_detect_action "$rule")
    mechanism=$(_detect_mechanism "$rule")

    local display_file="$file"
    display_file="${display_file/#$HOME/~}"

    rules_data+=("${scope}${SEP}${file}${SEP}${name}${SEP}${event}${SEP}${matcher}${SEP}${mechanism}${SEP}${action}${SEP}${display_file}")

    if [[ "$scope" == "user" ]]; then user_count=$((user_count + 1)); fi
    if [[ "$scope" == "project" ]]; then project_count=$((project_count + 1)); fi
  done

  # Also scan for disabled rules (not in map)
  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    local rule_count
    rule_count=$(yq -o=json '.rules | length' "$rule_file" 2>/dev/null)
    [[ -z "$rule_count" || "$rule_count" == "0" ]] && continue

    local j
    for (( j=0; j<rule_count; j++ )); do
      local rule_json enabled
      rule_json=$(_yq_json ".rules[$j]" "$rule_file")
      enabled=$(printf '%s\n' "$rule_json" | jq -r 'if has("enabled") then .enabled | tostring else empty end')
      [[ "$enabled" != "false" ]] && continue

      local dname scope
      dname=$(printf '%s\n' "$rule_json" | jq -r '.name // "rule-'"$((j+1))"'"')
      scope=$(_file_scope "$rule_file")

      [[ "$SCOPE" != "all" && "$scope" != "$SCOPE" ]] && continue

      local rule
      rule=$(printf '%s\n' "$rule_json" | jq -c '.')
      local on_field event matcher action mechanism
      on_field=$(printf '%s\n' "$rule" | jq -r '.on // empty')
      on_field=$(echo "$on_field" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
      event="${on_field%% *}"
      matcher="${on_field#"$event"}"
      matcher="${matcher# }"
      action=$(_detect_action "$rule")
      mechanism=$(_detect_mechanism "$rule")

      local display_file="${rule_file/#$HOME/~}"
      rules_data+=("${scope}${SEP}${rule_file}${SEP}${dname}${SEP}${event}${SEP}${matcher}${SEP}${mechanism}${SEP}${action}${SEP}${display_file}${SEP}disabled")

      disabled_count=$((disabled_count + 1))
      if [[ "$scope" == "user" ]]; then user_count=$((user_count + 1)); fi
      if [[ "$scope" == "project" ]]; then project_count=$((project_count + 1)); fi
    done
  done < <(_rule_files)

  local total=${#rules_data[@]}

  if [[ $total -eq 0 ]]; then
    echo "No hooksmith rules found. Create rules in ~/.config/hooksmith/rules/ or .hooksmith/rules/"
    exit 0
  fi

  # Sort by event then name
  IFS=$'\n' rules_data=($(printf '%s\n' "${rules_data[@]}" | sort -t"$SEP" -k4,4 -k3,3)); unset IFS

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    local first=true
    echo "["
    for entry in "${rules_data[@]}"; do
      IFS="$SEP" read -r scope file name event matcher mechanism action display_file disabled_flag <<< "$entry"
      local enabled_bool=true
      [[ "$disabled_flag" == "disabled" ]] && enabled_bool=false
      [[ "$first" == "true" ]] && first=false || echo ","
      jq -n \
        --arg name "$name" \
        --arg event "$event" \
        --arg matcher "$matcher" \
        --arg mechanism "$mechanism" \
        --arg action "$action" \
        --arg scope "$scope" \
        --argjson enabled "$enabled_bool" \
        --arg file "$display_file" \
        '{name:$name,event:$event,matcher:$matcher,mechanism:$mechanism,action:$action,scope:$scope,enabled:$enabled,file:$file}'
    done
    echo "]"
  else
    local sep="──────────────────────────────────────────────────────────────────────────────────────"
    echo "HOOKSMITH RULES"
    echo "$sep"
    printf "%-28s %-18s %-14s %-8s %-8s %s\n" "NAME" "EVENT" "MATCHER" "TYPE" "ACTION" "SCOPE"
    echo "$sep"
    for entry in "${rules_data[@]}"; do
      IFS="$SEP" read -r scope file name event matcher mechanism action display_file disabled_flag <<< "$entry"
      [[ -z "$matcher" ]] && matcher="—"
      local suffix=""
      [[ "$disabled_flag" == "disabled" ]] && suffix=" [disabled]"
      printf "%-28s %-18s %-14s %-8s %-8s %s%s\n" "$name" "$event" "$matcher" "$mechanism" "$action" "$scope" "$suffix"
    done
    echo "$sep"
    local summary="${total} rules (${user_count} user, ${project_count} project)"
    [[ $disabled_count -gt 0 ]] && summary="$summary · ${disabled_count} disabled"
    echo "$summary"
  fi
}

main
