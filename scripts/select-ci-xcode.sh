#!/usr/bin/env bash
# Select the Xcode for a CI compile/test gate and export DEVELOPER_DIR.
#
# Resolution, in order:
#   1. An explicit pin: CMUX_CI_DEVELOPER_DIR, else CMUX_CI_XCODE_APP. A pinned
#      path that is not installed fails; it never falls back.
#   2. The pool pin: the Xcode version scripts/ci/xcode-pins.txt names for this
#      runner's macOS major. A job that sets no pin therefore gets the same Xcode
#      as every other job on its pool, never the image's /Applications/Xcode.app
#      default (16.4 on GitHub's macos-15 image).
#   3. A scan for the newest stable Xcode, only with
#      CMUX_CI_XCODE_ALLOW_BELOW_FLOOR=1. The SDK 15 Ghostty CLI helper in
#      ci-macos.yml's swift-package-tests is the one caller; it needs an Xcode
#      below the floor and is not a Swift build.
#      A fork running CI in its own repository (GITHUB_REPOSITORY_OWNER is not
#      manaflow-ai) also scans, with a warning, when its hosted image lacks the
#      pool pin: a newer image Xcode costs a fork cache misses, never a failed
#      job (docs/ci-runners.md, fork contract). The floor still applies.
#
# Whatever is selected must be at least the Xcode major in .xcode-version, or
# the script stops with one ::error:: naming the found and required versions
# (CMUX_CI_XCODE_ALLOW_BELOW_FLOOR=1 lifts this too). Without the floor, a job
# on the wrong image compiles with the old Swift and reports hundreds of
# unrelated compile errors instead.
set -euo pipefail

SELECT_XCODE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT_XCODE_REPO_ROOT="$(dirname "$SELECT_XCODE_SCRIPT_DIR")"
XCODE_VERSION_FILE="${CMUX_XCODE_VERSION_FILE:-$SELECT_XCODE_REPO_ROOT/.xcode-version}"
XCODE_PINS_FILE="${CMUX_CI_XCODE_PINS_FILE:-$SELECT_XCODE_REPO_ROOT/scripts/ci/xcode-pins.txt}"
ALLOW_BELOW_FLOOR="${CMUX_CI_XCODE_ALLOW_BELOW_FLOOR:-0}"

APPLICATIONS_DIR="${CMUX_XCODE_APPLICATIONS_DIR:-/Applications}"
REQUIRED_SDK_MAJOR="${CMUX_CI_REQUIRED_MACOS_SDK_MAJOR:-}"
# A ceiling excludes unvalidated newer SDKs while retaining older-runner fallback.
MAX_SDK_MAJOR="${CMUX_CI_MAX_MACOS_SDK_MAJOR:-}"

case "$MAX_SDK_MAJOR" in *[!0-9]*)
  echo "CMUX_CI_MAX_MACOS_SDK_MAJOR must be numeric, got: $MAX_SDK_MAJOR" >&2
  exit 1
  ;;
esac

sdk_major() {
  local v="$1" maj
  maj="${v%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$maj"
}

# Prints the Xcode version (e.g. 26.3) of a developer dir, or nothing.
xcode_version_of() {
  local line
  line="$(DEVELOPER_DIR="$1" xcodebuild -version 2>/dev/null | head -n 1 || true)"
  case "$line" in
    "Xcode "*) printf '%s' "${line#Xcode }" ;;
  esac
}

required_xcode_major() {
  local version major
  if [ ! -f "$XCODE_VERSION_FILE" ]; then
    echo "::error::Cannot read the required Xcode version: $XCODE_VERSION_FILE is missing" >&2
    exit 1
  fi
  version="$(tr -d '[:space:]' < "$XCODE_VERSION_FILE")"
  major="${version%%.*}"
  case "$major" in ''|*[!0-9]*)
    echo "::error::.xcode-version must start with a numeric Xcode major, got: $version" >&2
    exit 1
    ;;
  esac
  printf '%s' "$major"
}

# Stops unless the selected Xcode is at least the .xcode-version major.
check_xcode_floor() {
  local selected_dir="$1" found found_major required
  [ "$ALLOW_BELOW_FLOOR" = "1" ] && return 0
  required="$(required_xcode_major)"
  found="$(xcode_version_of "$selected_dir")"
  found_major="${found%%.*}"
  case "$found_major" in ''|*[!0-9]*)
    echo "::error::Could not read the Xcode version of $selected_dir (xcodebuild -version); cmux requires Xcode $required (.xcode-version)" >&2
    exit 1
    ;;
  esac
  if [ "$found_major" -lt "$required" ]; then
    echo "::error::Found Xcode $found at $selected_dir; cmux requires Xcode $required (.xcode-version). This runner's image does not carry the Xcode pinned for its pool in scripts/ci/xcode-pins.txt." >&2
    exit 1
  fi
}

runner_macos_major() {
  local version
  version="$(sw_vers -productVersion 2>/dev/null || true)"
  version="${version%%.*}"
  case "$version" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$version"
}

# Prints the Xcode version pinned for a macOS major, or nothing.
pool_pin_for() {
  [ -f "$XCODE_PINS_FILE" ] || return 0
  awk -v major="$1" '$1 !~ /^#/ && NF >= 2 && $1 == major { print $2; exit }' "$XCODE_PINS_FILE"
}

# Prints the developer dir of an installed Xcode whose version is exactly $1.
# Xcode_<version>.app is tried first; other names (a fleet Mac's Xcode.app, a
# point-release suffix) match by what xcodebuild reports, not by path.
find_xcode_version() {
  local want="$1" app dev
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    dev="$app/Contents/Developer"
    [ -d "$dev" ] || continue
    if [ "$(xcode_version_of "$dev")" = "$want" ]; then
      printf '%s' "$dev"
      return 0
    fi
  done < <(
    [ -d "$APPLICATIONS_DIR/Xcode_$want.app" ] && printf '%s\n' "$APPLICATIONS_DIR/Xcode_$want.app"
    find "$APPLICATIONS_DIR" -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort
  )
  return 1
}

installed_xcodes() {
  local app dev listed=""
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    dev="$app/Contents/Developer"
    [ -d "$dev" ] || continue
    listed="$listed $(basename "$app")=$(xcode_version_of "$dev")"
  done < <(find "$APPLICATIONS_DIR" -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort)
  printf '%s' "${listed# }"
}

validate_sdk_constraints() {
  local selected_dir="$1" sdk_version="$2" actual_major
  [ -n "$REQUIRED_SDK_MAJOR$MAX_SDK_MAJOR" ] || return 0
  if [ -n "$REQUIRED_SDK_MAJOR" ]; then
    case "$REQUIRED_SDK_MAJOR" in *[!0-9]*)
      echo "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR must be numeric, got: $REQUIRED_SDK_MAJOR" >&2
      exit 1
      ;;
    esac
  fi
  if ! actual_major="$(sdk_major "$sdk_version")"; then
    echo "Could not parse macOS SDK version for $selected_dir: $sdk_version" >&2
    exit 1
  fi
  if [ -n "$REQUIRED_SDK_MAJOR" ] && [ "$actual_major" != "$REQUIRED_SDK_MAJOR" ]; then
    echo "Selected Xcode at $selected_dir has macOS SDK $sdk_version; required major is $REQUIRED_SDK_MAJOR" >&2
    exit 1
  fi
  if [ -n "$MAX_SDK_MAJOR" ] && [ "$actual_major" -gt "$MAX_SDK_MAJOR" ]; then
    echo "Selected Xcode at $selected_dir has macOS SDK $sdk_version; maximum major is $MAX_SDK_MAJOR" >&2
    exit 1
  fi
}

select_developer_dir() {
  local selected_dir="$1" sdk_version="$2" label="$3"

  check_xcode_floor "$selected_dir"
  validate_sdk_constraints "$selected_dir" "$sdk_version"
  echo "$label (DEVELOPER_DIR): $selected_dir (macOS SDK $sdk_version)"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$selected_dir" >> "$GITHUB_ENV"
  fi
  export DEVELOPER_DIR="$selected_dir"

  # Ordinary CI also aligns the system xcode-select default because some app-host
  # subprocesses ignore DEVELOPER_DIR. Shared-machine semantic workloads must not
  # mutate that host-global selector, so their reviewed environment sets the skip.
  if [[ "${CMUX_CI_SKIP_XCODE_SELECT:-0}" == "1" ]]; then
    echo "Skipping host-global xcode-select update; DEVELOPER_DIR is pinned for this workload"
  elif xcode-select -s "$selected_dir" 2>/dev/null; then
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
  if [ "$ALLOW_BELOW_FLOOR" != "1" ] && POOL_MAJOR="$(runner_macos_major)"; then
    POOL_VERSION="$(pool_pin_for "$POOL_MAJOR")"
    PINNED_VERSION="$(xcode_version_of "$PINNED_DEVELOPER_DIR")"
    if [ -n "$POOL_VERSION" ] && [ "$PINNED_VERSION" != "$POOL_VERSION" ]; then
      echo "::warning::This job pins Xcode $PINNED_VERSION, but scripts/ci/xcode-pins.txt pins Xcode $POOL_VERSION for macOS $POOL_MAJOR runners. Jobs on one pool with different Xcodes cannot share compilation caches or products."
    fi
  fi
  exit 0
fi

# A fork's own CI runs on GitHub-hosted images whose Xcodes move without
# notice. It keeps working on the newest stable Xcode instead of failing.
runs_in_fork_repository() {
  [ -n "${GITHUB_REPOSITORY_OWNER:-}" ] && [ "$GITHUB_REPOSITORY_OWNER" != "manaflow-ai" ]
}

POOL_DEVELOPER_DIR=""
if [ "$ALLOW_BELOW_FLOOR" != "1" ]; then
  if ! POOL_MAJOR="$(runner_macos_major)"; then
    echo "::error::Could not read this runner's macOS version (sw_vers), so no Xcode can be chosen from scripts/ci/xcode-pins.txt" >&2
    exit 1
  fi
  POOL_VERSION="$(pool_pin_for "$POOL_MAJOR")"
  if [ -z "$POOL_VERSION" ]; then
    if runs_in_fork_repository; then
      echo "::warning::No Xcode is pinned for macOS $POOL_MAJOR runners in scripts/ci/xcode-pins.txt; this fork uses the newest stable Xcode on its image instead."
    else
      echo "::error::No Xcode is pinned for macOS $POOL_MAJOR runners. Add a line to scripts/ci/xcode-pins.txt, or pin CMUX_CI_XCODE_APP for this job." >&2
      exit 1
    fi
  elif ! POOL_DEVELOPER_DIR="$(find_xcode_version "$POOL_VERSION")"; then
    POOL_DEVELOPER_DIR=""
    if runs_in_fork_repository; then
      echo "::warning::This macOS $POOL_MAJOR runner has no Xcode $POOL_VERSION, the version scripts/ci/xcode-pins.txt pins for its pool; this fork uses the newest stable Xcode on its image instead, so it cannot reuse main's compilation caches. Installed: $(installed_xcodes)"
    else
      echo "::error::This macOS $POOL_MAJOR runner has no Xcode $POOL_VERSION, the version scripts/ci/xcode-pins.txt pins for its pool. Installed: $(installed_xcodes)" >&2
      exit 1
    fi
  fi
fi

if [ "$ALLOW_BELOW_FLOOR" != "1" ] && [ -n "$POOL_DEVELOPER_DIR" ]; then
  POOL_SDK_VER="$(DEVELOPER_DIR="$POOL_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  if [ -z "$POOL_SDK_VER" ]; then
    echo "::error::Pool Xcode developer dir has no usable macOS SDK: $POOL_DEVELOPER_DIR" >&2
    exit 1
  fi
  select_developer_dir "$POOL_DEVELOPER_DIR" "$POOL_SDK_VER" "Selected Xcode $POOL_VERSION pinned for macOS $POOL_MAJOR runners"
  exit 0
fi

if [ -n "$REQUIRED_SDK_MAJOR" ]; then
  case "$REQUIRED_SDK_MAJOR" in ''|*[!0-9]*)
    echo "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR must be numeric, got: $REQUIRED_SDK_MAJOR" >&2
    exit 1
    ;;
  esac
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
  if [ -n "$MAX_SDK_MAJOR" ]; then
    if ! actual_major="$(sdk_major "$sdk_ver")"; then
      echo "Ignoring $app with unparsable macOS SDK version: $sdk_ver" >&2
      continue
    fi
    if [ "$actual_major" -gt "$MAX_SDK_MAJOR" ]; then
      echo "Skipping $app -> macOS SDK $sdk_ver; maximum major is $MAX_SDK_MAJOR"
      continue
    fi
  fi
  if [ -n "$REQUIRED_SDK_MAJOR" ]; then
    if ! actual_major="$(sdk_major "$sdk_ver")"; then
      echo "Ignoring $app with unparsable macOS SDK version: $sdk_ver" >&2
      continue
    fi
    if [ "$actual_major" != "$REQUIRED_SDK_MAJOR" ]; then
      echo "Skipping $app -> macOS SDK $sdk_ver; required major is $REQUIRED_SDK_MAJOR"
      continue
    fi
  fi
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
  if [ -n "$REQUIRED_SDK_MAJOR" ]; then
    echo "No Xcode.app found under $APPLICATIONS_DIR with macOS SDK major $REQUIRED_SDK_MAJOR" >&2
    exit 1
  fi
  echo "No Xcode.app found under $APPLICATIONS_DIR" >&2
  exit 1
fi

select_developer_dir "$BEST_DIR" "$BEST_VER" "Selected Xcode"
