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
REQUIRED_SDK_MAJOR="${CMUX_CI_REQUIRED_MACOS_SDK_MAJOR:-}"

sdk_major() {
  local v="$1" maj
  maj="${v%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$maj"
}

validate_required_sdk() {
  local selected_dir="$1" sdk_version="$2" actual_major
  [ -n "$REQUIRED_SDK_MAJOR" ] || return 0
  case "$REQUIRED_SDK_MAJOR" in ''|*[!0-9]*)
    echo "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR must be numeric, got: $REQUIRED_SDK_MAJOR" >&2
    exit 1
    ;;
  esac
  if ! actual_major="$(sdk_major "$sdk_version")"; then
    echo "Could not parse macOS SDK version for $selected_dir: $sdk_version" >&2
    exit 1
  fi
  if [ "$actual_major" != "$REQUIRED_SDK_MAJOR" ]; then
    echo "Selected Xcode at $selected_dir has macOS SDK $sdk_version; required major is $REQUIRED_SDK_MAJOR" >&2
    exit 1
  fi
}

select_developer_dir() {
  local selected_dir="$1" sdk_version="$2" label="$3"

  validate_required_sdk "$selected_dir" "$sdk_version"
  echo "$label (DEVELOPER_DIR): $selected_dir (macOS SDK $sdk_version)"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$selected_dir" >> "$GITHUB_ENV"
  fi
  export DEVELOPER_DIR="$selected_dir"

  # Also point the *system* xcode-select default at the selected toolchain. Tools
  # that ignore DEVELOPER_DIR resolve `xcodebuild` via the xcode-select default,
  # notably Apple's `/usr/bin/git` shim (`xcodebuild -find git`). The xctest host
  # spawns git subprocesses that do NOT inherit our DEVELOPER_DIR, so on runner VMs
  # whose default is the old Xcode symlink, `git` runs the old `xcodebuild`, which
  # dlopen()s a libxcodebuildLoader ABI-incompatible with the newer-Xcode-built test
  # host and crashes ("Symbol not found"), failing git-shell-out tests
  # (e.g. ExtensionWorktreePrototypeTests) before they can assert - nondeterministic
  # per which VM a shard lands on. Aligning the default removes that divergence.
  # Best-effort: never hard-fail a runner that disallows the switch.
  if xcode-select -s "$selected_dir" 2>/dev/null; then
    echo "xcode-select default -> $selected_dir"
  elif command -v sudo >/dev/null 2>&1 && sudo -n xcode-select -s "$selected_dir" 2>/dev/null; then
    echo "xcode-select default (via sudo) -> $selected_dir"
  else
    echo "WARN: could not switch xcode-select default to $selected_dir (continuing; DEVELOPER_DIR is still set for steps that honor it)" >&2
  fi

  xcodebuild -version
  # Diagnostic: resolve the SDK with DEVELOPER_DIR set in-process. The workflow
  # step that calls this script gets DEVELOPER_DIR only via GITHUB_ENV, which
  # applies to *later* steps, not the current shell, so a bare `xcrun` on the
  # next line of the same step would still resolve the old xcode-select default.
  xcrun --sdk macosx --show-sdk-path
}

PINNED_DEVELOPER_DIR="${CMUX_CI_DEVELOPER_DIR:-}"
if [ -z "$PINNED_DEVELOPER_DIR" ] && [ -n "${CMUX_CI_XCODE_APP:-}" ]; then
  PINNED_DEVELOPER_DIR="${CMUX_CI_XCODE_APP%/}/Contents/Developer"
fi

if [ -n "$PINNED_DEVELOPER_DIR" ]; then
  if [ ! -d "$PINNED_DEVELOPER_DIR" ]; then
    echo "Pinned Xcode developer dir does not exist: $PINNED_DEVELOPER_DIR" >&2
    exit 1
  fi
  PINNED_SDK_VER="$(DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  if [ -z "$PINNED_SDK_VER" ]; then
    echo "Pinned Xcode developer dir has no usable macOS SDK: $PINNED_DEVELOPER_DIR" >&2
    exit 1
  fi
  select_developer_dir "$PINNED_DEVELOPER_DIR" "$PINNED_SDK_VER" "Selected pinned Xcode"
  exit 0
fi

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
BETA_DIR=""
BETA_VER=""
BETA_RANK=-1
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
  # Beta Xcodes (e.g. Xcode_27.0_Beta.app) otherwise outrank every stable
  # release and put the gate on an SDK nothing ships with. Only select one
  # when the image has no stable Xcode at all.
  case "$(basename "$app")" in
    *[Bb]eta*)
      echo "Found $app -> macOS SDK $sdk_ver (rank $rank, beta)"
      if [ "$rank" -ge "$BETA_RANK" ]; then
        BETA_DIR="$dev"
        BETA_VER="$sdk_ver"
        BETA_RANK="$rank"
      fi
      continue
      ;;
  esac
  echo "Found $app -> macOS SDK $sdk_ver (rank $rank)"
  # `-ge` so among equal-SDK Xcodes the alphabetically-last (newest point
  # release, e.g. Xcode_26.3.app over Xcode_26.2.0.app) wins.
  if [ "$rank" -ge "$BEST_RANK" ]; then
    BEST_DIR="$dev"
    BEST_VER="$sdk_ver"
    BEST_RANK="$rank"
  fi
done < <(find "$APPLICATIONS_DIR" -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort)

if [ -z "$BEST_DIR" ] && [ -n "$BETA_DIR" ]; then
  echo "No stable Xcode found; falling back to beta: $BETA_DIR" >&2
  BEST_DIR="$BETA_DIR"
  BEST_VER="$BETA_VER"
  BEST_RANK="$BETA_RANK"
fi

if [ -z "$BEST_DIR" ]; then
  echo "No Xcode.app found under $APPLICATIONS_DIR" >&2
  exit 1
fi

select_developer_dir "$BEST_DIR" "$BEST_VER" "Selected Xcode"
