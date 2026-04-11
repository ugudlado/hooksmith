#!/bin/bash
# pack.sh — Pack management for hooksmith.
# Usage: pack.sh <subcommand> [args...]
#   pack.sh install <source> [--name <name>]   — Install a rule pack
#   pack.sh update [<name>]                     — Update installed pack(s)
#   pack.sh remove <name>                       — Remove an installed pack
#   pack.sh list                                — List installed packs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../core/config.sh"
source "${SCRIPT_DIR}/../core/map.sh"

PACKS_DIR="$HOOKSMITH_PACKS_DIR"

# ── Parse a pack source into repo URL, subpath, and default name ──
# Supports:
#   owner/repo                     → github clone, no subpath
#   owner/repo/sub/path            → github clone, copy subpath
#   https://github.com/owner/repo  → full URL clone
#   https://...repo/sub/path       → full URL with subpath (3+ segments after host)

_parse_source() {
  local source="$1"
  local repo_url="" subpath="" default_name=""

  if [[ "$source" =~ ^https?:// ]]; then
    # Full URL — extract repo (first 2 path segments after host) and optional subpath
    local path_part
    path_part=$(echo "$source" | sed 's|https\?://[^/]*/||')
    local segments
    IFS='/' read -ra segments <<< "$path_part"
    if [[ ${#segments[@]} -lt 2 ]]; then
      echo "pack: invalid source — need at least owner/repo" >&2
      return 1
    fi
    local host
    host=$(echo "$source" | grep -oE 'https?://[^/]+')
    repo_url="${host}/${segments[0]}/${segments[1]%.git}.git"
    if [[ ${#segments[@]} -gt 2 ]]; then
      subpath=$(IFS='/'; echo "${segments[*]:2}")
    fi
    default_name="${segments[${#segments[@]}-1]}"
  else
    # Shorthand: owner/repo[/subpath...]
    local segments
    IFS='/' read -ra segments <<< "$source"
    if [[ ${#segments[@]} -lt 2 ]]; then
      echo "pack: invalid source — need at least owner/repo" >&2
      return 1
    fi
    repo_url="https://github.com/${segments[0]}/${segments[1]}.git"
    if [[ ${#segments[@]} -gt 2 ]]; then
      subpath=$(IFS='/'; echo "${segments[*]:2}")
    fi
    default_name="${segments[${#segments[@]}-1]}"
  fi

  echo "$repo_url"
  echo "$subpath"
  echo "$default_name"
}

# ── Install ──

_pack_install() {
  local source="" pack_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) pack_name="$2"; shift 2 ;;
      -*)     echo "pack install: unknown option '$1'" >&2; exit 1 ;;
      *)      source="$1"; shift ;;
    esac
  done

  if [[ -z "$source" ]]; then
    echo "Usage: hooksmith pack install <source> [--name <name>]" >&2
    echo "  source: owner/repo, owner/repo/subpath, or full git URL" >&2
    exit 1
  fi

  local parsed repo_url subpath default_name
  parsed=$(_parse_source "$source") || exit 1
  { read -r repo_url; read -r subpath; read -r default_name; } <<< "$parsed"
  [[ -z "$pack_name" ]] && pack_name="$default_name"

  local dest="$PACKS_DIR/$pack_name"

  if [[ -d "$dest" ]]; then
    echo "pack: '$pack_name' is already installed at $dest" >&2
    echo "  Use 'hooksmith pack update $pack_name' to update it." >&2
    exit 1
  fi

  mkdir -p "$PACKS_DIR"
  local tmp_clone
  tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/hooksmith-pack.XXXXXX")
  trap "rm -rf '$tmp_clone'" RETURN

  echo "Cloning $repo_url..."
  if ! git clone --depth 1 --quiet "$repo_url" "$tmp_clone" 2>&1; then
    echo "pack: failed to clone $repo_url" >&2
    exit 1
  fi

  local src="$tmp_clone"
  if [[ -n "$subpath" ]]; then
    src="$tmp_clone/$subpath"
    if [[ ! -d "$src" ]]; then
      echo "pack: subpath '$subpath' not found in $repo_url" >&2
      exit 1
    fi
  fi

  # Copy rules (not .git metadata)
  mkdir -p "$dest"
  find "$src" -name "*.yaml" -o -name "*.sh" | while IFS= read -r f; do
    local rel="${f#"$src"/}"
    mkdir -p "$dest/$(dirname "$rel")"
    cp "$f" "$dest/$rel"
  done

  # Write pack metadata for updates
  cat > "$dest/.packinfo" <<EOF
source=$source
repo=$repo_url
subpath=$subpath
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  local rule_count
  rule_count=$(find "$dest" -name "*.yaml" | wc -l | tr -d ' ')
  echo "Installed pack '$pack_name' ($rule_count rule files)"
  echo "  Location: $dest"
  echo "  Run 'hooksmith init' to rebuild the rule index."
}

# ── Update ──

_pack_update() {
  local target="${1:-}"

  if [[ -n "$target" ]]; then
    _update_one "$target"
  else
    # Update all installed packs
    local found=false
    for pack_dir in "$PACKS_DIR"/*/; do
      [[ -d "$pack_dir" ]] || continue
      found=true
      _update_one "$(basename "$pack_dir")"
    done
    if [[ "$found" == "false" ]]; then
      echo "No packs installed."
    fi
  fi
}

_update_one() {
  local pack_name="$1"
  local dest="$PACKS_DIR/$pack_name"

  if [[ ! -d "$dest" ]]; then
    echo "pack: '$pack_name' is not installed" >&2
    return 1
  fi

  local info_file="$dest/.packinfo"
  if [[ ! -f "$info_file" ]]; then
    echo "pack: '$pack_name' has no .packinfo — cannot update (reinstall instead)" >&2
    return 1
  fi

  local source repo_url subpath
  source=$(grep '^source=' "$info_file" | cut -d= -f2-)
  repo_url=$(grep '^repo=' "$info_file" | cut -d= -f2-)
  subpath=$(grep '^subpath=' "$info_file" | cut -d= -f2-)

  local tmp_clone
  tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/hooksmith-pack.XXXXXX")
  trap "rm -rf '$tmp_clone'" RETURN

  echo "Updating '$pack_name' from $repo_url..."
  if ! git clone --depth 1 --quiet "$repo_url" "$tmp_clone" 2>&1; then
    echo "pack: failed to clone $repo_url" >&2
    return 1
  fi

  local src="$tmp_clone"
  [[ -n "$subpath" ]] && src="$tmp_clone/$subpath"

  if [[ ! -d "$src" ]]; then
    echo "pack: subpath '$subpath' no longer exists in $repo_url" >&2
    return 1
  fi

  # Replace pack contents (preserve .packinfo)
  find "$dest" -not -name ".packinfo" -not -path "$dest" -delete 2>/dev/null
  find "$src" -name "*.yaml" -o -name "*.sh" | while IFS= read -r f; do
    local rel="${f#"$src"/}"
    mkdir -p "$dest/$(dirname "$rel")"
    cp "$f" "$dest/$rel"
  done

  # Update timestamp in .packinfo
  sed -i '' "s/^installed=.*/updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$info_file" 2>/dev/null || true

  local rule_count
  rule_count=$(find "$dest" -name "*.yaml" | wc -l | tr -d ' ')
  echo "Updated '$pack_name' ($rule_count rule files)"
}

# ── Remove ──

_pack_remove() {
  local pack_name="${1:-}"

  if [[ -z "$pack_name" ]]; then
    echo "Usage: hooksmith pack remove <name>" >&2
    exit 1
  fi

  local dest="$PACKS_DIR/$pack_name"
  if [[ ! -d "$dest" ]]; then
    echo "pack: '$pack_name' is not installed" >&2
    exit 1
  fi

  rm -rf "$dest"
  echo "Removed pack '$pack_name'"
  echo "  Run 'hooksmith init' to rebuild the rule index."
}

# ── List ──

_pack_list() {
  if [[ ! -d "$PACKS_DIR" ]] || [[ -z "$(ls -A "$PACKS_DIR" 2>/dev/null)" ]]; then
    echo "No packs installed."
    echo "  Install one with: hooksmith pack install <source>"
    return 0
  fi

  local sep="──────────────────────────────────────────────────────────────────────────────────────"
  echo "INSTALLED PACKS"
  echo "$sep"
  printf "%-20s %-8s %-30s %s\n" "NAME" "RULES" "SOURCE" "INSTALLED"
  echo "$sep"

  for pack_dir in "$PACKS_DIR"/*/; do
    [[ -d "$pack_dir" ]] || continue
    local name
    name=$(basename "$pack_dir")
    local rule_count
    rule_count=$(find "$pack_dir" -name "*.yaml" | wc -l | tr -d ' ')

    local source="" installed=""
    if [[ -f "$pack_dir/.packinfo" ]]; then
      source=$(grep '^source=' "$pack_dir/.packinfo" | cut -d= -f2-)
      installed=$(grep -E '^(updated|installed)=' "$pack_dir/.packinfo" | tail -1 | cut -d= -f2- | cut -dT -f1)
    fi

    printf "%-20s %-8s %-30s %s\n" "$name" "$rule_count" "$source" "$installed"
  done
  echo "$sep"
}

# ── Main dispatch ──

subcmd="${1:-}"
shift 2>/dev/null || true

case "$subcmd" in
  install) _pack_install "$@" ;;
  update)  _pack_update "$@" ;;
  remove)  _pack_remove "$@" ;;
  list)    _pack_list ;;
  *)
    echo "Usage: hooksmith pack <install|update|remove|list>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  install <source> [--name <name>]   Install a rule pack from a git repo" >&2
    echo "  update [<name>]                    Update one or all installed packs" >&2
    echo "  remove <name>                      Remove an installed pack" >&2
    echo "  list                               List installed packs" >&2
    echo "" >&2
    echo "Source formats:" >&2
    echo "  owner/repo                         Clone entire repo as a pack" >&2
    echo "  owner/repo/subpath                 Clone repo, install only subpath" >&2
    echo "  https://github.com/owner/repo      Full git URL" >&2
    exit 1 ;;
esac
