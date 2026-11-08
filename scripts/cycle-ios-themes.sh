#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: cycle-ios-themes.sh --tag <tag> [--interval <seconds>] [--cycles <count>]

Cycles a dark, light, and custom Ghostty theme through a tagged cmux build.
The original Ghostty config and any existing custom theme are restored on exit.
EOF
}

tag="${CMUX_TAG:-}"
interval=5
cycles=0

while (( $# > 0 )); do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --interval)
      interval="${2:-}"
      shift 2
      ;;
    --cycles)
      cycles="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$tag" ]]; then
  usage
  exit 2
fi
if [[ ! "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid interval: %s\n' "$interval" >&2
  exit 2
fi
if [[ ! "$cycles" =~ ^[0-9]+$ ]]; then
  printf 'Invalid cycle count: %s\n' "$cycles" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
config_file="${GHOSTTY_CONFIG_FILE:-$config_dir/config}"
themes_dir="$config_dir/themes"
custom_theme_name="cmux iOS Theme Cycle"
custom_theme_file="$themes_dir/$custom_theme_name"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-theme-cycle.XXXXXX")"
config_existed=0
custom_theme_existed=0
config_mutated=0
custom_theme_mutated=0
restored=0

reload_config() {
  CMUX_TAG="$tag" "$repo_root/scripts/cmux-debug-cli.sh" reload-config >/dev/null
}

restore() {
  local status=$?
  if (( restored )); then
    return "$status"
  fi
  restored=1
  if (( config_mutated )); then
    if (( config_existed )); then
      cp -p "$backup_dir/config" "$config_file"
    else
      rm -f "$config_file"
    fi
  fi
  if (( custom_theme_mutated )); then
    if (( custom_theme_existed )); then
      cp -p "$backup_dir/custom-theme" "$custom_theme_file"
    else
      rm -f "$custom_theme_file"
    fi
  fi
  if (( config_mutated || custom_theme_mutated )); then
    reload_config || true
    printf 'Restored original Ghostty theme.\n'
  fi
  rm -rf "$backup_dir"
  return "$status"
}
trap restore EXIT INT TERM

mkdir -p "$config_dir" "$themes_dir"
if [[ -L "$config_file" ]]; then
  config_file="$(/usr/bin/python3 - "$config_file" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
)"
  mkdir -p "$(dirname "$config_file")"
fi
if [[ -f "$config_file" ]]; then
  cp -p "$config_file" "$backup_dir/config"
  config_existed=1
else
  config_mutated=1
  : > "$config_file"
fi
if [[ -f "$custom_theme_file" ]]; then
  cp -p "$custom_theme_file" "$backup_dir/custom-theme"
  custom_theme_existed=1
fi

custom_theme_mutated=1
cat > "$custom_theme_file" <<'EOF'
palette = 0=#042F34
palette = 1=#FF6B6B
palette = 2=#72F1B8
palette = 3=#FFE66D
palette = 4=#5DADE2
palette = 5=#FF8FE5
palette = 6=#4ECDC4
palette = 7=#F7FFF7
palette = 8=#38666B
palette = 9=#FF8787
palette = 10=#95F9CA
palette = 11=#FFF09A
palette = 12=#85C1E9
palette = 13=#FFB4EF
palette = 14=#76DDD5
palette = 15=#FFFFFF
background = #063F46
foreground = #F7FFF7
cursor-color = #FFE66D
cursor-text = #063F46
selection-background = #2A6870
selection-foreground = #FFFFFF
EOF

set_theme() {
  local theme="$1"
  local temporary
  temporary="$(mktemp "${config_file}.cycle.XXXXXX")"
  awk -v theme="$theme" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*theme[[:space:]]*=/ {
      if (!replaced) {
        print "theme = \"" theme "\""
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) print "theme = \"" theme "\""
    }
  ' "$config_file" > "$temporary"
  config_mutated=1
  mv "$temporary" "$config_file"
  reload_config
  printf '%s  %s\n' "$(date '+%H:%M:%S')" "$theme"
}

themes=("Monokai Classic" "Atom One Light" "$custom_theme_name")
completed=0
printf 'Cycling themes every %s seconds for tag %s. Press Ctrl-C to restore.\n' "$interval" "$tag"
while (( cycles == 0 || completed < cycles )); do
  for theme in "${themes[@]}"; do
    set_theme "$theme"
    sleep "$interval"
  done
  completed=$((completed + 1))
done
