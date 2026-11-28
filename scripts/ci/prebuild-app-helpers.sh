#!/usr/bin/env bash
# Build the Rust helpers that the cmux app target's late script phases bundle
# (diff sidecar and command palette Nucleo FFI) while xcodebuild compiles
# Swift.
#
# Those phases run after the cmux Swift compile although they do not read its
# output, so on CI their cargo builds (about 100 s) were the serial tail of the
# nightly build. This script overlaps the two local-source helpers and runs the same build scripts with the same Cargo
# target directories and the same toolchain-visible environment that Xcode gives
# the phases. When the phases then run, Cargo finds every unit fresh and the
# phases only copy, lipo, and sign.
#
# Correctness never depends on this script. If it fails, is slower than the
# Swift compile, or its environment differs from the phase's, the phase's own
# cargo invocation waits on Cargo's build-directory lock or rebuilds the dirty
# units exactly as it did before.
#
# usage: prebuild-app-helpers.sh --derived-data <path> --archs "<archs>"
#                                [--configuration <name>]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived_data=""
archs=""
configuration="Release"

while (($#)); do
  case "$1" in
    --derived-data) derived_data="$2"; shift 2 ;;
    --archs) archs="$2"; shift 2 ;;
    --configuration) configuration="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$derived_data" || -z "$archs" ]]; then
  echo "usage: $0 --derived-data <path> --archs \"<archs>\" [--configuration <name>]" >&2
  exit 2
fi
derived_data="$(mkdir -p "$derived_data" && cd "$derived_data" && pwd)"

# Xcode exports every build setting to script phases. rustc records
# MACOSX_DEPLOYMENT_TARGET in its dep-info and the cc crate reruns build scripts
# when SDKROOT changes, so both must match the phase's values or Cargo would
# rebuild. The project uses one deployment target for every configuration.
deployment_targets="$(
  grep -o 'MACOSX_DEPLOYMENT_TARGET = [0-9.]*' "$ROOT/cmux.xcodeproj/project.pbxproj" \
    | awk '{print $3}' | sort -u
)"
if [[ "$(printf '%s\n' "$deployment_targets" | wc -l | tr -d ' ')" != "1" ]]; then
  echo "error: expected one MACOSX_DEPLOYMENT_TARGET in the project, found: $deployment_targets" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET="$deployment_targets"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

# The diff sidecar keeps its Cargo target directory under the app target's
# TARGET_TEMP_DIR: $(PROJECT_TEMP_DIR)/$(CONFIGURATION)/$(TARGET_NAME).build.
target_temp_dir="$derived_data/Build/Intermediates.noindex/cmux.build/$configuration/cmux.build"
mkdir -p "$target_temp_dir"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cmux-helper-prebuild.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

run_helper() {
  local name="$1"
  shift
  local started
  started="$(date +%s)"
  if "$@" >"$scratch/$name.log" 2>&1; then
    echo "prebuilt $name in $(( $(date +%s) - started ))s"
  else
    local status=$?
    echo "prebuild of $name failed with status $status after $(( $(date +%s) - started ))s; the Xcode phase will build it" >&2
    tail -40 "$scratch/$name.log" >&2
    return "$status"
  fi
}

run_helper diff-sidecar env \
  TARGET_TEMP_DIR="$target_temp_dir" \
  CMUX_DIFF_SIDECAR_ARCHS="$archs" \
  CMUX_DIFF_SIDECAR_MIN_MACOS="$MACOSX_DEPLOYMENT_TARGET" \
  "$ROOT/scripts/build-diff-sidecar.sh" &
sidecar_pid=$!
run_helper nucleo-ffi env \
  CMUX_NUCLEO_FFI_ARCHS="$archs" \
  CMUX_NUCLEO_FFI_REQUIRE_CARGO=1 \
  "$ROOT/scripts/build-command-palette-nucleo-ffi.sh" &
nucleo_pid=$!
# cmux-cua remains in the authoritative Xcode phase. Its source checkout
# mutates a shared Git cache; cancelling an optional prebuild during checkout
# could leave a Git index lock that poisons the subsequent required build.

status=0
wait "$sidecar_pid" || status=1
wait "$nucleo_pid" || status=1
exit "$status"
