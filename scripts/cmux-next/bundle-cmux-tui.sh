#!/usr/bin/env bash
# Xcode "Bundle cmux-tui" phase of the cmux-next target: copies a cmux-tui
# binary to <app>/Contents/Resources/bin/cmux-tui, where CmuxNextDaemon's
# DaemonLauncher runs `cmux-tui --session <S> --json server ensure`.
#
# Where the binary comes from:
# - Release, nightly, and CI: scripts/install-cmux-tui-client.sh installs the
#   attested build from the cmux-tui-artifacts workflow manifest
#   (files.cmux.com/cmux-tui/<commit>/manifest.json) after the build. That is
#   the authoritative copy; this phase never downloads anything.
# - Tagged dev builds: scripts/reload.sh calls the same installer post-build.
# - This phase covers plain Xcode/xcodebuild builds. Source order:
#     1. CMUX_NEXT_TUI_BIN (a local cargo build or hosted verification
#        artifact, e.g. cmux-tui/target/hosted/<target>/cmux-tui),
#     2. CMUX_TUI_CLIENT_LOCAL (the installer's local override),
#     3. the newest slice in the installer cache
#        (~/Library/Caches/cmux/cmux-tui-client/<commit>/cmux-tui-<arch>-apple-darwin).
#   With none of these it keeps an existing bundled copy, or warns and exits 0
#   (the app reports "cmux-tui binary not found" at launch).
set -euo pipefail

dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cmux-tui"

arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
[[ "$arch" == arm64 ]] && arch=aarch64

src=""
if [[ -n "${CMUX_NEXT_TUI_BIN:-}" ]]; then
  src="$CMUX_NEXT_TUI_BIN"
elif [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
  src="$CMUX_TUI_CLIENT_LOCAL"
else
  cache="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
  if [[ -d "$cache" ]]; then
    # Newest cached slice by mtime.
    src="$(ls -t "$cache"/*/"cmux-tui-$arch-apple-darwin" 2>/dev/null | head -n 1 || true)"
  fi
fi

if [[ -z "$src" ]]; then
  if [[ -x "$dest" ]]; then
    echo "note: no cmux-tui source configured; keeping bundled $dest"
    exit 0
  fi
  echo "warning: no cmux-tui binary to bundle. Set CMUX_NEXT_TUI_BIN, or run scripts/reload.sh (installs it via scripts/install-cmux-tui-client.sh)."
  exit 0
fi
if [[ ! -f "$src" ]]; then
  echo "error: cmux-tui source $src does not exist" >&2
  exit 1
fi

if [[ -x "$dest" ]] && cmp -s "$src" "$dest"; then
  exit 0
fi
mkdir -p "$dest_dir"
# Remove first: overwriting a Mach-O in place invalidates its signature and
# the kernel SIGKILLs the next launch.
rm -f "$dest"
cp "$src" "$dest"
chmod 755 "$dest"
echo "bundled cmux-tui from $src"
