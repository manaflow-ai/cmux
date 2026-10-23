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
#   Resources/terminfo-overlay, ghostty-next/src/shell-integration (with
#   cmux-tui's shell_integration/ghostty-preexec.bash appended to ghostty.bash),
#   Resources/cmux-cli-path.
# Not Resources/shell-integration: that is the classic app's integration
# (report_pwd, git and PR watchers, per-path-part checks, #21977), which no
# cmux-next shell sources; cmux-next's shells get Ghostty's integration under
# the cmux-cli-path layer (GhosttyShellIntegration, BundledCLIEnvironment).
set -euo pipefail

dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
share="${SRCROOT:?}/ghostty-next/zig-out/share"

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
  echo "warning: no Ghostty resources found; themes will not resolve"
fi
# cmux's own themes sit next to Ghostty's, so `theme = <name>` and every
# picker find them. They never replace a Ghostty theme of the same name.
if [[ -d "$SRCROOT/Resources/cmux-themes" ]]; then
  mkdir -p "$dest/ghostty/themes"
  rsync -a --ignore-existing "$SRCROOT/Resources/cmux-themes/" "$dest/ghostty/themes/"
fi

if [[ -d "$SRCROOT/ghostty-next/src/shell-integration" ]]; then
  sync_dir "$SRCROOT/ghostty-next/src/shell-integration" "$dest/ghostty/shell-integration"
  # cmux's interim fix to Ghostty's bash preexec hook (no fork per command on
  # bash 5.3), appended as the cmux-tui daemon appends it to its embedded copy
  # (shell_integration.rs SCRIPTS), so both spawn paths run the same script.
  # The sync above restores Ghostty's file first, so the append runs once.
  # A missing fix file stops the build: the app would ship Ghostty's forking
  # hook while the daemon's copy (include_str!) has the fix. Interim: delete
  # with the ghostty-next bump to 72578da (see ghostty-preexec.bash).
  bash_fix="$SRCROOT/cmux-tui/crates/cmux-tui-core/src/shell_integration/ghostty-preexec.bash"
  if [[ -f "$dest/ghostty/shell-integration/bash/ghostty.bash" ]]; then
    if [[ ! -f "$bash_fix" ]]; then
      echo "error: $bash_fix is missing; the bundled bash integration would differ from the cmux-tui daemon's" >&2
      exit 1
    fi
    cat "$bash_fix" >>"$dest/ghostty/shell-integration/bash/ghostty.bash"
  fi
else
  echo "warning: no ghostty-next/src/shell-integration; shells start without Ghostty's integration"
fi

if [[ -d "$share/terminfo" ]]; then
  sync_dir "$share/terminfo" "$dest/terminfo"
elif [[ -d "$SRCROOT/Resources/ghostty/terminfo" ]]; then
  sync_dir "$SRCROOT/Resources/ghostty/terminfo" "$dest/terminfo"
fi
if [[ -d "$SRCROOT/Resources/terminfo-overlay" ]]; then
  mkdir -p "$dest/terminfo"
  rsync -a "$SRCROOT/Resources/terminfo-overlay/" "$dest/terminfo/"
fi

# An older build of this phase copied the classic integration here.
rm -rf "$dest/shell-integration"
# Keeps the bundled `cmux` first on PATH after the user's startup files
# (BundledCLIEnvironment.swift).
if [[ -d "$SRCROOT/Resources/cmux-cli-path" ]]; then
  sync_dir "$SRCROOT/Resources/cmux-cli-path" "$dest/cmux-cli-path"
fi
echo "bundled Ghostty resources into $dest"
