# shellcheck shell=bash
# Sourced by the cmux-next scripts that build Packages/macOS/CmuxNext in place
# outside the suite scripts: the regenerate-*-exports.sh exporters,
# check-action-surfaces.sh, scripts/measure/export-action-surfaces.sh and
# scripts/measure/export-action-catalog-dump.sh. It
# keeps the suite scripts' contract with a .build that a fleet warm slot
# shares (hq build-fleet internal/warmscripts):
#   - swiftpm_binary_module_guard before the build, so a binary-target pin
#     change never reuses an old .pcm against a new header;
#   - the suites' swift_test_debug_info_args on every build and test, so this
#     build has their flags and neither side rebuilds the package after the
#     other;
#   - the commit in <package>/.build/.cmux-ci-built-ref after the build, so a
#     later test failure keeps the finished build.
# A script that sources this declares it on a comment line of its own,
#   # cmux-ci-warm-contract: swiftpm-v1
# and the fleet gives its step a warm slot only then.
#
# cmux_next_warm_build PKGDIR [ARG...]
#   The guard, the test build of PKGDIR (ARGs added, such as -j N: build
#   parallelism leaves the outputs alone), then the built ref. Returns the
#   guard's 75 (fetch failed, nothing built) or the build's status.
# cmux_next_swift_args
#   The flags every later build and test of PKGDIR passes.
#
# CMUX_NEXT_JOB_BUILT=plain: the calling CI job already built PKGDIR with a
# plain `swift build --build-tests` (cmux-next.yml's generated-files, swift-test
# and daemon-test jobs; the fast-tier seed is the same build). The warm
# contract's flags differ from that build's and its guard finds no header
# digest in it, so under the contract the first export threw the job's whole
# build away and built cold again: 23.5 min, then the settings check's base
# export, then its restore, past the job's 40 min cap on every pull request
# that changes CmuxNextSettings (cmuxterm-hq#9678, cmux#41472). With it the
# build and test flags are the job's own (only the CPU grant's --jobs is kept,
# which leaves the outputs alone) and the guard is skipped, as the job's own
# build skipped it, so a build here is incremental on the job's build.

# The helpers live in scripts/ci. The pull request autofix runs the base's
# scripts/cmux-next from a copy that has no scripts/ci beside it, so they then
# come from the checkout being built.
cmux_next_warm_ci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ci"
[ -f "$cmux_next_warm_ci_dir/swiftpm-binary-module-guard.sh" ] ||
  cmux_next_warm_ci_dir="$(git rev-parse --show-toplevel)/scripts/ci"
# shellcheck source=scripts/ci/swift-test-debug-info.sh
source "$cmux_next_warm_ci_dir/swift-test-debug-info.sh" || return 2
# shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
source "$cmux_next_warm_ci_dir/swiftpm-binary-module-guard.sh" || return 2
# A fleet step builds with its pool's pinned Xcode (scripts/ci/xcode-pins.txt), as
# run-swift-testing-suites.sh does since c80ce904, never the host's xcode-select default:
# on 2026-11-21 aws-m4pro-2 defaulted to Xcode 26.3, whose generated Bundle.module takes
# CmuxNext's MainActor default isolation, so regenerate-settings-exports.sh failed there
# on FileGridStrings.swift (cmux#47467). The host default stays as it is
# (CMUX_CI_SKIP_XCODE_SELECT); a caller's DEVELOPER_DIR wins.
if [ -n "${CMUX_CI_STEP_KEY:-}" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  cmux_next_xcode_env="$(mktemp)"
  GITHUB_ENV="$cmux_next_xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 \
    "${CMUX_SELECT_CI_XCODE:-$cmux_next_warm_ci_dir/../select-ci-xcode.sh}" >&2 || { rm -f "$cmux_next_xcode_env"; return 2; }
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$cmux_next_xcode_env" | tail -n 1)"
  rm -f "$cmux_next_xcode_env"
  if [ -z "$DEVELOPER_DIR" ]; then
    echo "error: select-ci-xcode.sh selected no Xcode for this fleet step" >&2
    return 2
  fi
  export DEVELOPER_DIR
fi
cmux_next_swift_args=(${swift_test_debug_info_args[@]+"${swift_test_debug_info_args[@]}"})
if [ "${CMUX_NEXT_JOB_BUILT:-}" = plain ]; then
  cmux_next_swift_args=()
  if [[ "${CMUX_CI_CPU_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
    cmux_next_swift_args=(--jobs "$CMUX_CI_CPU_BUDGET")
  fi
elif [ -n "${CMUX_NEXT_JOB_BUILT:-}" ]; then
  echo "CMUX_NEXT_JOB_BUILT must be plain or unset (got '${CMUX_NEXT_JOB_BUILT}')" >&2
  return 2
fi

cmux_next_warm_select_xcode() {
  [ "$(uname -s)" = Darwin ] || return 0
  # Fleet exporters do not have Actions' preceding Select Xcode step. Use
  # the same pool/explicit pin as package-test-lane.sh, never the host default.
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    local xcode_env status
    xcode_env="$(mktemp)" || return $?
    if GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 \
        bash "$cmux_next_warm_ci_dir/../select-ci-xcode.sh"; then
      DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
      rm -f "$xcode_env"
      [ -n "$DEVELOPER_DIR" ] || return 2
      export DEVELOPER_DIR
    else
      status=$?
      rm -f "$xcode_env"
      return "$status"
    fi
  fi
  # A Python/xcrun shim may have inherited the Command Line Tools SDK.
  # Resolve it from the selected compiler before either the guard or build.
  SDKROOT="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)" || return $?
  [ -n "$SDKROOT" ] && [ -d "$SDKROOT" ] || return 2
  export SDKROOT
  echo "Xcode: $DEVELOPER_DIR; SDK: $SDKROOT"
}

cmux_next_warm_build() {
  local pkgdir="$1" built_ref="$1/.build/.cmux-ci-built-ref"
  shift
  cmux_next_warm_select_xcode || return $?
  if [ -f "$built_ref" ]; then
    echo "ci-phase .build last built at $(cut -c1-12 "$built_ref")"
  else
    echo "ci-phase .build has no earlier build (cold or first use)"
  fi
  if [ "${CMUX_NEXT_JOB_BUILT:-}" != plain ]; then
    swiftpm_binary_module_guard "$pkgdir" || return $?
  fi
  swift build ${cmux_next_swift_args[@]+"${cmux_next_swift_args[@]}"} --package-path "$pkgdir" --build-tests "$@" || return $?
  git -C "$pkgdir" rev-parse HEAD > "$built_ref"
}
