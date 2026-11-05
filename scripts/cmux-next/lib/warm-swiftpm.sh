# shellcheck shell=bash
# Sourced by the cmux-next scripts that build Packages/macOS/CmuxNext in place
# outside the suite scripts: the regenerate-*-exports.sh exporters,
# check-action-surfaces.sh and scripts/measure/export-action-surfaces.sh. It
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
cmux_next_swift_args=(${swift_test_debug_info_args[@]+"${swift_test_debug_info_args[@]}"})

cmux_next_warm_build() {
  local pkgdir="$1" built_ref="$1/.build/.cmux-ci-built-ref"
  shift
  if [ -f "$built_ref" ]; then
    echo "ci-phase .build last built at $(cut -c1-12 "$built_ref")"
  else
    echo "ci-phase .build has no earlier build (cold or first use)"
  fi
  swiftpm_binary_module_guard "$pkgdir" || return $?
  swift build ${cmux_next_swift_args[@]+"${cmux_next_swift_args[@]}"} --package-path "$pkgdir" --build-tests "$@" || return $?
  git -C "$pkgdir" rev-parse HEAD > "$built_ref"
}
