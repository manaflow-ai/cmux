#!/usr/bin/env bash
# Xcode "Bundle Ghostty resources" phase of the cmux-next target: copies the
# Ghostty themes, terminfo (plus cmux's overlay), and shell integration into
# <app>/Contents/Resources, where GhosttyRuntime points GHOSTTY_RESOURCES_DIR.
#
# Ghostty's files come from ghostty-next, the Ghostty that GhosttyNextKit and
# libghostty-vt build from (the cmux-tui daemon embeds the same shell
# integration scripts). The cmux-next app ships no Ghostty CLI helper yet.
# Sources, in order:
#   ghostty-next/zig-out/share/{ghostty,terminfo}  (a local zig build), else
#   Resources/ghostty/{themes,terminfo}             (checked in),
#   Resources/cmux-themes (cmux's own themes, added to ghostty/themes),
#   Resources/terminfo-overlay, ghostty-next/src/shell-integration,
#   Resources/shell-integration.
set -euo pipefail

dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
share="${SRCROOT:?}/ghostty-next/zig-out/share"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-ghostty-resources.stamp"
on_exit() {
  status=$?
  if (( status == 0 )); then
    mkdir -p "$(dirname "$stamp")"
    printf 'completed\n' > "$stamp"
  fi
  exit "$status"
}
trap on_exit EXIT
rm -f "$stamp"

# Keep all declared resource directories present even when a source tree is
# unavailable, so the dependency-analysis output is stable for optional hosts.
mkdir -p "$dest/ghostty" "$dest/terminfo" "$dest/shell-integration" "$dest/cmux-cli-path"

sync_dir() {
  local src="$1" dst="$2"
  # File-system synchronized groups can materialize a same-named resource
  # before this legacy script runs. Replace that placeholder with the
  # directory this phase owns.
  if [[ -e "$dst" && ! -d "$dst" ]]; then
    rm -f "$dst"
  fi
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
}

if [[ -d "$share/ghostty" ]]; then
  sync_dir "$share/ghostty" "$dest/ghostty"
elif [[ -d "$SRCROOT/Resources/ghostty" ]]; then
  sync_dir "$SRCROOT/Resources/ghostty" "$dest/ghostty"
else
  rm -rf "$dest/ghostty"
  echo "warning: no Ghostty resources found; themes will not resolve"
fi
# cmux's own themes sit next to Ghostty's, so `theme = <name>` and every
# picker find them. They never replace a Ghostty theme of the same name.
if [[ -d "$SRCROOT/Resources/cmux-themes" ]]; then
  mkdir -p "$dest/ghostty/themes"
  theme_list="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-ghostty-resources.cmux-themes.list"
  if [[ -f "$theme_list" ]]; then
    while IFS= read -r relative; do
      [[ -n "$relative" ]] && rm -f "$dest/ghostty/themes/$relative"
    done < "$theme_list"
  fi
  : > "$theme_list"
  while IFS= read -r relative; do
    printf '%s\n' "$relative" >> "$theme_list"
  done < <(cd "$SRCROOT/Resources/cmux-themes" && find . -type f -print | sed 's#^\./##')
  rsync -a --ignore-existing "$SRCROOT/Resources/cmux-themes/" "$dest/ghostty/themes/"
else
  theme_list="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-ghostty-resources.cmux-themes.list"
  if [[ -f "$theme_list" ]]; then
    while IFS= read -r relative; do
      [[ -n "$relative" ]] && rm -f "$dest/ghostty/themes/$relative"
    done < "$theme_list"
    rm -f "$theme_list"
  fi
fi

if [[ -d "$SRCROOT/ghostty-next/src/shell-integration" ]]; then
  sync_dir "$SRCROOT/ghostty-next/src/shell-integration" "$dest/ghostty/shell-integration"
else
  rm -rf "$dest/ghostty/shell-integration"
  echo "warning: no ghostty-next/src/shell-integration; shells start without Ghostty's integration"
fi

if [[ -d "$share/terminfo" ]]; then
  sync_dir "$share/terminfo" "$dest/terminfo"
elif [[ -d "$SRCROOT/Resources/ghostty/terminfo" ]]; then
  sync_dir "$SRCROOT/Resources/ghostty/terminfo" "$dest/terminfo"
else
  rm -rf "$dest/terminfo"
fi
if [[ -d "$SRCROOT/Resources/terminfo-overlay" ]]; then
  mkdir -p "$dest/terminfo"
  overlay_list="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-ghostty-resources.terminfo-overlay.list"
  if [[ -f "$overlay_list" ]]; then
    while IFS= read -r relative; do
      [[ -n "$relative" ]] && rm -f "$dest/terminfo/$relative"
    done < "$overlay_list"
  fi
  : > "$overlay_list"
  while IFS= read -r relative; do
    printf '%s\n' "$relative" >> "$overlay_list"
  done < <(cd "$SRCROOT/Resources/terminfo-overlay" && find . -type f -print | sed 's#^\./##')
  rsync -a "$SRCROOT/Resources/terminfo-overlay/" "$dest/terminfo/"
else
  overlay_list="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-ghostty-resources.terminfo-overlay.list"
  if [[ -f "$overlay_list" ]]; then
    while IFS= read -r relative; do
      [[ -n "$relative" ]] && rm -f "$dest/terminfo/$relative"
    done < "$overlay_list"
    rm -f "$overlay_list"
  fi
fi

if [[ -d "$SRCROOT/Resources/shell-integration" ]]; then
  sync_dir "$SRCROOT/Resources/shell-integration" "$dest/shell-integration"
else
  rm -rf "$dest/shell-integration"
fi
# Keeps the bundled `cmux` first on PATH after the user's startup files
# (BundledCLIEnvironment.swift).
if [[ -d "$SRCROOT/Resources/cmux-cli-path" ]]; then
  sync_dir "$SRCROOT/Resources/cmux-cli-path" "$dest/cmux-cli-path"
else
  rm -rf "$dest/cmux-cli-path"
fi
echo "bundled Ghostty resources into $dest"
