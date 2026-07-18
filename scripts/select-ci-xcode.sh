#!/usr/bin/env bash
# Select the newest Xcode for CI compile/test gates.
#
# The runner images ship multiple Xcodes (16.x with the macOS 15 SDK / Swift 6.1
# and 26.x with the macOS 26 SDK / Swift 6.3), but `/Applications/Xcode.app` is
# symlinked to an old 16.x. The previous "prefer /Applications/Xcode.app" logic
# therefore pinned the test/compile gate to Swift 6.1, while nightly and release
# already build on 26.x (see select-nightly-xcodes.sh). That divergence let code
# that compiles locally (6.3) and ships (6.3) fail only on the 6.1 test gate
# (e.g. `isolated deinit`, region-based isolation differences).
#
# Pick the highest macOS SDK Xcode so the test gate matches what ships. Fall back
# to the newest available if no 26+ is installed, so this never hard-fails a
# runner that lacks the newer Xcode. Exports DEVELOPER_DIR to GITHUB_ENV.
set -euo pipefail

APPLICATIONS_DIR="${CMUX_XCODE_APPLICATIONS_DIR:-/Applications}"

# Rank by macOS SDK as maj*1000+min so 26.2 (26002) outranks 15.5 (15005).
sdk_rank() {
  local v="$1" maj min
  maj="${v%%.*}"
  min="${v#*.}"
  [ "$min" = "$v" ] && min=0
  min="${min%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  printf '%d' "$(( maj * 1000 + min ))"
}

BEST_DIR=""
BEST_VER=""
BEST_RANK=-1
while IFS= read -r app; do
  [ -n "$app" ] || continue
  dev="$app/Contents/Developer"
  [ -d "$dev" ] || continue
  sdk_ver="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  [ -n "$sdk_ver" ] || continue
  if ! rank="$(sdk_rank "$sdk_ver")"; then
    echo "Ignoring $app with unparsable macOS SDK version: $sdk_ver" >&2
    continue
  fi
  echo "Found $app -> macOS SDK $sdk_ver (rank $rank)"
  # `-ge` so among equal-SDK Xcodes the alphabetically-last (newest point
  # release, e.g. Xcode_26.3.app over Xcode_26.2.0.app) wins.
  if [ "$rank" -ge "$BEST_RANK" ]; then
    BEST_DIR="$dev"
    BEST_VER="$sdk_ver"
    BEST_RANK="$rank"
  fi
done < <(find "$APPLICATIONS_DIR" -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort)

if [ -z "$BEST_DIR" ]; then
  echo "No Xcode.app found under $APPLICATIONS_DIR" >&2
  exit 1
fi

echo "Selected Xcode (DEVELOPER_DIR): $BEST_DIR (macOS SDK $BEST_VER)"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$BEST_DIR" >> "$GITHUB_ENV"
fi
export DEVELOPER_DIR="$BEST_DIR"

# Also point the *system* xcode-select default at the selected toolchain. Tools
# that ignore DEVELOPER_DIR resolve `xcodebuild` via the xcode-select default,
# notably Apple's `/usr/bin/git` shim (`xcodebuild -find git`). The xctest host
# spawns git subprocesses that do NOT inherit our DEVELOPER_DIR, so on runner VMs
# whose default is the old Xcode symlink, `git` runs the old `xcodebuild`, which
# dlopen()s a libxcodebuildLoader ABI-incompatible with the newer-Xcode-built test
# host and crashes ("Symbol not found"), failing git-shell-out tests
# (e.g. ExtensionWorktreePrototypeTests) before they can assert — nondeterministic
# per which VM a shard lands on. Aligning the default removes that divergence.
# Best-effort: never hard-fail a runner that disallows the switch.
if xcode-select -s "$BEST_DIR" 2>/dev/null; then
  echo "xcode-select default -> $BEST_DIR"
elif command -v sudo >/dev/null 2>&1 && sudo -n xcode-select -s "$BEST_DIR" 2>/dev/null; then
  echo "xcode-select default (via sudo) -> $BEST_DIR"
else
  echo "WARN: could not switch xcode-select default to $BEST_DIR (continuing; DEVELOPER_DIR is still set for steps that honor it)" >&2
fi

xcodebuild -version
# Diagnostic: resolve the SDK with DEVELOPER_DIR set in-process. The workflow
# step that calls this script gets DEVELOPER_DIR only via GITHUB_ENV, which
# applies to *later* steps, not the current shell, so a bare `xcrun` on the
# next line of the same step would still resolve the old xcode-select default.
xcrun --sdk macosx --show-sdk-path
