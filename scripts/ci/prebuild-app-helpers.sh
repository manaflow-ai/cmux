#!/usr/bin/env bash
# Build the Rust helper that the cmux app target's late script phase bundles
# (the diff sidecar) while xcodebuild compiles Swift.
#
# Those phases run after the cmux Swift compile although they do not read its
# output, so on CI their cargo builds (about 100 s) were the serial tail of the
# nightly build. This script overlaps the local-source helper and runs the same build script with the same Cargo
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

# Read what the authoritative "Build Diff Sidecar" phase uses from the
# project instead of assuming it: the app target that owns the phase (its
# TARGET_TEMP_DIR holds the Cargo target directory) and the sidecar's own
# macOS floor (CMUX_DIFF_SIDECAR_MIN_MACOS, which build-diff-sidecar.sh hands
# cargo as MACOSX_DEPLOYMENT_TARGET). rustc records that value in its
# dep-info, so a different one would make the phase rebuild. The project's
# targets have different deployment targets (cmux-next 26.0, the CLI 14.0),
# so a project-wide value does not exist.
read -r phase_target sidecar_min_macos < <(python3 - "$ROOT/cmux.xcodeproj/project.pbxproj" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
phase = re.search(r'(\w+) /\* Build Diff Sidecar \*/ = \{.*?shellScript = "(.*?)";\n', text, re.S)
if not phase:
    sys.exit("error: no 'Build Diff Sidecar' phase in the project")
floor = re.search(r'CMUX_DIFF_SIDECAR_MIN_MACOS=([0-9.]+)', phase.group(2))
target = None
for match in re.finditer(r'\w+ /\* [^*]+ \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};', text, re.S):
    body = match.group(1)
    if re.search(r'\b' + phase.group(1) + r' /\* Build Diff Sidecar \*/', body):
        target = re.search(r'\bname = "?([^";]+)"?;', body).group(1)
if not target or not floor:
    sys.exit("error: cannot find the target or the macOS floor of the 'Build Diff Sidecar' phase")
print(target, floor.group(1))
PY
)
if [[ -z "${phase_target:-}" || -z "${sidecar_min_macos:-}" ]]; then
  echo "error: cannot read the Build Diff Sidecar phase from the project" >&2
  exit 1
fi
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

# The diff sidecar keeps its Cargo target directory under the app target's
# TARGET_TEMP_DIR: $(PROJECT_TEMP_DIR)/$(CONFIGURATION)/$(TARGET_NAME).build.
target_temp_dir="$derived_data/Build/Intermediates.noindex/cmux.build/$configuration/$phase_target.build"
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
  CMUX_DIFF_SIDECAR_MIN_MACOS="$sidecar_min_macos" \
  "$ROOT/scripts/build-diff-sidecar.sh" &
sidecar_pid=$!
# cmux-cua remains in the authoritative Xcode phase. Its source checkout
# mutates a shared Git cache; cancelling an optional prebuild during checkout
# could leave a Git index lock that poisons the subsequent required build.

status=0
wait "$sidecar_pid" || status=1
exit "$status"
