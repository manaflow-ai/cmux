#!/usr/bin/env bash
# The swift-package-tests lane of ci-macos.yml as one script, so the same code
# runs on a GitHub runner and as a fleet ci-step (`cmux-ci run`, hq#794) from a
# fresh checkout of the commit on a mini.
#
# Usage: package-test-lane.sh [run|select|packages|ghostty-sha]
#          [--event[=]NAME] [--full-suite[=]true|false]
#
#   run       (default) select, then set up what the selection needs (Xcode,
#             GhosttyKit.xcframework) and run the package tests.
#   select    choose the packages. Under Actions it writes the step outputs
#             (selected_packages, selected_count, needs_ghosttykit,
#             changed_files) to GITHUB_OUTPUT.
#   packages  run the packages listed in the file SELECTED_PACKAGES.
#   prebuild-one PACKAGE LOG
#             build PACKAGE and its tests into LOG; the packages phase runs
#             several of these at once before its serial test pass.
#   ghostty-sha  print the GhosttyKit revision a download would use (empty
#             when a ghostty submodule checkout provides it).
#   suite PACKAGE_DIR FILTER[,FILTER...] [FILTER[,FILTER...]...]
#             a lane's focused gate: select Xcode (CMUX_CI_XCODE_APP), fetch
#             GhosttyKit when the package names it, build PACKAGE_DIR (a
#             Packages/ path) with its tests ONCE, then run `swift test
#             --skip-build --filter FILTER` for each filter in turn under the
#             hang watchdog. Filters come as comma lists, separate arguments,
#             or both. A failing suite does not stop the ones after it; the
#             summary lists every suite and the step fails when any failed. A
#             filter that runs no test fails, and so does one whose tests all
#             skipped or that skipped any for a missing same-tree cmux-tui
#             ("no result", never excused as a base red). The watchdog limits apply to
#             each suite (CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS, 900 s), so N
#             suites can take N times that; cmux-ci's --timeout covers the step.
#             Lanes: cmux-ci run --class light --script
#             scripts/ci/package-test-lane.sh --ref SHA --arg=suite
#             --arg=Packages/macOS/CmuxNext --arg=SuiteA,SuiteB,SuiteC
#             --env CMUX_CI_XCODE_APP=/Applications/Xcode_26.6.app
#   compile-tests MERGE_BASE_SHA
#             compile, without running, the test targets this commit's change
#             can break: scripts/ci/compile_test_plan.py over `git diff
#             MERGE_BASE_SHA HEAD` (the CmuxNext test targets that depend on a
#             changed target, and the lane's packages whose sources or path
#             dependencies changed). fleet-test-compile.yml runs it on pull
#             requests as an advisory check (fleet/compile-check compiles only
#             the app, which links no test target: #23360, #23163). Exit 0
#             when every planned target compiled (or none was
#             planned), 1 after "compile-tests: a test target did not
#             compile", anything else when there is no verdict. The marker is
#             printed as soon as a target fails, so a later package's setup
#             failure (any exit) never hides an earlier compile failure.
#
# --event and --full-suite default to EVENT_NAME and FULL_SUITE. Run from the
# repository root; every helper path is relative to it.
set -euo pipefail

phase=run
case "${1:-}" in
  run|select|packages|ghostty-sha) phase="$1"; shift ;;
  prebuild-one) phase="$1"; prebuild_package="$2"; prebuild_log="$3"; shift 3 ;;
  compile-tests)
    phase="$1"
    if [ "$#" -ne 2 ] || ! [[ "$2" =~ ^[0-9a-f]{40}$ ]]; then
      echo "usage: package-test-lane.sh compile-tests MERGE_BASE_SHA (the full sha of the change's merge base)" >&2; exit 2
    fi
    compile_base="$2"
    shift 2
    ;;
  suite)
    phase="$1"; suite_package="${2:-}"
    if [ "$#" -lt 3 ]; then
      echo "usage: package-test-lane.sh suite PACKAGE_DIR FILTER[,FILTER...] [FILTER...]" >&2; exit 2
    fi
    # A Packages/ path inside the checkout, and filters that are not options.
    if ! [[ "$suite_package" =~ ^Packages/[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]] || [[ "$suite_package" == *..* ]] \
      || [ ! -f "$suite_package/Package.swift" ]; then
      echo "package-test-lane.sh: suite needs a package directory under Packages/ (got '$suite_package')" >&2; exit 2
    fi
    shift 2
    suite_filters=()
    for suite_arg in "$@"; do
      if [[ "$suite_arg" == *$'\n'* ]]; then
        echo "package-test-lane.sh: a suite filter has a newline (got '$suite_arg')" >&2; exit 2
      fi
      # Split on commas, keeping empty fields so "A,,B" and "A," are refused.
      IFS=, read -r -a suite_parts <<< "$suite_arg,"
      for suite_filter in ${suite_parts[@]+"${suite_parts[@]}"}; do
        if ! [[ "$suite_filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_./:-]*$ ]]; then
          echo "package-test-lane.sh: suite needs test filters such as SuiteA,SuiteB (got '$suite_arg')" >&2; exit 2
        fi
        # A trailing '.' or '/' (`CmuxNextAppTests.`, copied from the route's
        # regex) matches no test, so the step built everything for nothing.
        case "$suite_filter" in
          *.|*/)
            echo "package-test-lane.sh: suite filter '$suite_filter' ends with '${suite_filter: -1}'; pass the target name (CmuxNextAppTests) or Target.Suite/test" >&2; exit 2 ;;
        esac
        suite_filters+=("$suite_filter")
      done
    done
    set --
    ;;
esac
# Swift Testing runs many test cases at once (up to twice the core count).
# The CmuxNext full run then oversubscribes the main actor: on 2026-10-04 a
# queued main-actor reload waited 55 s, past test deadlines. Cap the width at
# the physical core count unless the caller set one. The variable is
# experimental in swift-testing and is ignored by a toolchain without it.
if [ -z "${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-}" ]; then
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$(sysctl -n hw.physicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
  export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH
fi
event="${EVENT_NAME:-}"
full_suite="${FULL_SUITE:-false}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event) event="$2"; shift 2 ;;
    --event=*) event="${1#*=}"; shift ;;
    --full-suite) full_suite="$2"; shift 2 ;;
    --full-suite=*) full_suite="${1#*=}"; shift ;;
    *) echo "package-test-lane.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7):
# CMUX_SWIFT_SANITIZE=address|thread|undefined builds and tests under that
# sanitizer, in its own scratch folder so it never mixes with a normal build.
case "${CMUX_SWIFT_SANITIZE:-}" in
  ""|address|thread|undefined) ;;
  *) echo "package-test-lane.sh: CMUX_SWIFT_SANITIZE must be address, thread or undefined (got '$CMUX_SWIFT_SANITIZE')" >&2; exit 2 ;;
esac

# A sanitizer runtime adds a C personality routine, and the Rust static libraries the app
# links bring their own: ld's compact unwind encodes at most three ("Too many personality
# routines", CmuxNext under thread, 2026-10-09). The test binary keeps DWARF unwind instead.
sanitize_link_flags=(-Xlinker -no_compact_unwind)

# CMUX_SWIFT_TEST_DEBUG_INFO (dwarf|none): debug info of the test builds; the
# builds and the test runs below share it (scripts/ci/swift-test-debug-info.sh).
# shellcheck source=scripts/ci/swift-test-debug-info.sh
source "$(dirname "${BASH_SOURCE[0]}")/swift-test-debug-info.sh" || exit 2
# A reused .build drops its build outputs when a binary target's headers
# change (CCmuxAppFFI or GhosttyNextKit pin): scripts/ci/swiftpm-binary-module-guard.sh.
# shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/swiftpm-binary-module-guard.sh" || exit 2

lane_script="${BASH_SOURCE[0]}"
work="${RUNNER_TEMP:-}"
if [ -z "$work" ]; then
  work="$(mktemp -d -t package-test-lane.XXXXXX)"
fi

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1" >> "$GITHUB_OUTPUT"
  fi
}

# The selection needs the commit's first parent. A GitHub checkout fetches
# depth 2; a fleet step's worktree may be shallow, so fetch the parent there.
ensure_parent() {
  if git rev-parse -q --verify 'HEAD^1^{commit}' >/dev/null || [ "${GITHUB_ACTIONS:-}" = true ]; then
    return 0
  fi
  local remote
  remote="$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)"
  # Depth 2 only in a shallow checkout: in a full clone --depth writes
  # .git/shallow and truncates history for every worktree sharing it.
  local depth=()
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=2)
  git fetch --no-tags --no-write-fetch-head ${depth[@]+"${depth[@]}"} "$remote" "$(git rev-parse HEAD)" || true
}

# A package whose manifest names GhosttyKit.xcframework has a binaryTarget on
# the xcframework at the repository root: the lane downloads it first, and its
# `swift test` may exit 1 on a cosmetic binaryTarget diagnostic (test_package).
references_ghosttykit() {
  local dir
  dir="$(find Packages -mindepth 2 -maxdepth 2 -type d -name "$1" -print -quit)"
  [ -n "$dir" ] && grep -q 'GhosttyKit\.xcframework' "$dir/Package.swift" 2>/dev/null
}

# A same-repository pull request run (the workflow sets CMUX_PACKAGE_REUSE=1)
# keys each selected package's test inputs (scripts/ci/package_input_key.py)
# and, unless it is the full suite, drops the packages whose key passed on an
# earlier run of this branch (scripts/ci/reuse_package_results.py). The select
# step looks once; the run step selects again and drops the same packages.
# record_passed publishes the keys that pass for the next run to reuse.
package_keys="$work/package-input-keys.json"
reused_packages="$work/reused-packages.txt"
reuse_package_results() {
  [ "${CMUX_PACKAGE_REUSE:-0}" = 1 ] && [ -s "$selected" ] || return 0
  if [ ! -f "$package_keys" ] && ! python3 scripts/ci/package_input_key.py --packages-file "$selected" \
      --extra "xcode=${CMUX_CI_XCODE_APP:-}" --extra "macos=$(sw_vers -productVersion 2>/dev/null || true)" \
      --output "$package_keys"; then
    rm -f "$package_keys"
    return 0
  fi
  if [ "${CMUX_PACKAGE_REUSE:-0}" = 1 ] && [ "$full_suite" != "true" ] && [ "$event" = "pull_request" ]; then
    if [ ! -f "$reused_packages" ]; then
      python3 scripts/ci/reuse_package_results.py --repository "${GITHUB_REPOSITORY:-}" \
        --branch "${CMUX_PACKAGE_REUSE_BRANCH:-}" --current-run-id "${GITHUB_RUN_ID:-0}" \
        --selected "$selected" --keys "$package_keys" --reused "$reused_packages" || : > "$reused_packages"
    fi
    grep -vxF -f "$reused_packages" "$selected" > "$selected.remaining" || true
    mv "$selected.remaining" "$selected"
  fi
}

# record_passed PACKAGE...: write the input keys of these packages (each passed
# here or was reused) as passed-packages.json for the workflow to publish.
record_passed() {
  [ -f "$package_keys" ] && [ "$#" -gt 0 ] || return 0
  local directory="$work/passed-packages"
  mkdir -p "$directory"
  python3 - "$package_keys" "$directory/passed-packages.json" "$@" <<'PY'
import json, sys
keys = json.load(open(sys.argv[1], encoding="utf-8"))
passed = {package: keys[package] for package in sys.argv[3:] if package in keys}
json.dump(passed, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
  output "passed_packages=$directory"
}

select_packages() {
  PACKAGES=(
    CMUXAuthCore
    CmuxAuthRuntime
    CmuxIrohTransport
    CmuxIrxTransport
    CmuxUpdater
    CmuxPhonePush
  )

  changed="$work/changed-files.txt"
  selected="$work/selected-packages.txt"
  if { [ "$event" = "pull_request" ] || [ "$event" = "merge_group" ]; } \
    && git diff --no-renames --name-only HEAD^1 HEAD > "$changed" 2>/dev/null; then
    output "changed_files=$changed"
    selection_args=(--changed-files "$changed")
    if [ "$full_suite" != "true" ]; then
      # Match the router's candidate filtering even for mixed PRs.
      # A package edit plus a workflow edit must not become a full sweep.
      selection_args+=(--routed-inputs-only)
    fi
    python3 scripts/ci/select_package_tests.py "${selection_args[@]}" "${PACKAGES[@]}" > "$selected"
  else
    if [ "$full_suite" != "true" ]; then
      echo "::error::Diff unavailable for targeted package tests; refusing a full sweep."
      exit 1
    fi
    echo "Diff unavailable; running every package."
    printf '%s\n' "${PACKAGES[@]}" > "$selected"
  fi
  reuse_package_results
  count="$(wc -l < "$selected" | tr -d ' ')"
  output "selected_packages=$selected"
  output "selected_count=$count"

  needs_ghosttykit=false
  while IFS= read -r pkg; do
    if [ -n "$pkg" ] && references_ghosttykit "$pkg"; then
      needs_ghosttykit=true
    fi
  done < "$selected"
  output "needs_ghosttykit=$needs_ghosttykit"
  write_package_input_keys
  echo "Selected $count of ${#PACKAGES[@]} Swift packages."
}

# The receipt is the {package: key} map reuse_package_results computed (the same
# keys record_passed publishes); when reuse is off it is computed into its own
# file, so record_passed still publishes nothing.
write_package_input_keys() {
  [ -f "${selected:-}" ] || return 0
  local receipt_file="$package_keys" receipt
  [ -f "$receipt_file" ] || receipt_file="$work/package-input-receipt.json"
  if [ ! -f "$receipt_file" ] && ! python3 scripts/ci/package_input_key.py --root . --packages-file "$selected" \
      --extra "xcode=${CMUX_CI_XCODE_APP:-}" --extra "macos=$(sw_vers -productVersion 2>/dev/null || true)" \
      --output "$receipt_file"; then
    rm -f "$receipt_file"
    return 0
  fi
  receipt="$(tr -d "\n" < "$receipt_file")"
  output "package_input_keys=$receipt"
  # Fleet steps do not receive GITHUB_OUTPUT; this marker is copied back by the
  # workflow wrapper alongside the interface-fingerprint receipt.
  printf 'CMUX_PACKAGE_INPUT_KEYS=%s\n' "$receipt"
  PACKAGE_INPUT_KEYS_FILE="$receipt_file"
}

# The workflow's "Select Xcode" step already exported DEVELOPER_DIR through
# GITHUB_ENV. A fleet step selects here, without touching the mini's
# host-global xcode-select default.
select_xcode() {
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    local env_file="$work/xcode.env"
    : > "$env_file"
    GITHUB_ENV="$env_file" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
    DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$env_file" | tail -n 1)"
    test -n "$DEVELOPER_DIR"
    export DEVELOPER_DIR
  fi
  pin_sdkroot
}

# SDKROOT is the macOS SDK of the Xcode whose swiftc runs, for every phase.
# Without it an xcrun shim picks its own: on 2026-10-07 the /usr/bin/python3
# shim that starts hung_test_watchdog.py, with DEVELOPER_DIR=Xcode_26.6,
# exported SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk (Swift
# 6.4) to `swift test`, and every suite failed with "Invalid manifest" after a
# good build. An SDKROOT from the environment is replaced: it may be that leak.
pin_sdkroot() {
  local sdk
  sdk="$(env -u SDKROOT DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
    echo "::error title=No macOS SDK::package-test-lane.sh: xcrun found no macOS SDK in $DEVELOPER_DIR (got '$sdk')" >&2
    exit 1
  fi
  SDKROOT="$sdk"
  export SDKROOT
  echo "SDK: $SDKROOT"
}

# A `swift test` whose toolchain and SDK differ compiles no manifest and runs
# no test; say so instead of reporting an ordinary test failure.
toolchain_mismatch() {
  local hit
  hit="$(grep -m1 -oE 'SDK is not supported by the compiler|Invalid manifest|no tests found' "$1" || true)"
  [ -n "$hit" ] || return 1
  echo "::error title=Swift toolchain and SDK differ::$2: swift test reported '$hit' with DEVELOPER_DIR=${DEVELOPER_DIR:-unset} SDKROOT=${SDKROOT:-unset}; no test result here is valid"
}

# A fleet step has no ghostty submodule checkout, only the empty directory git
# leaves for the gitlink. `git -C ghostty` there walks up to the superproject,
# so test for the submodule's own .git instead; the gitlink names the same
# revision a checkout would.
resolve_ghostty_sha() {
  if [ -z "${GHOSTTY_SHA:-}" ] && [ ! -e ghostty/.git ]; then
    GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
    export GHOSTTY_SHA
  fi
}

# The workflow restores GhosttyKit.xcframework from the Actions cache first and
# removes an invalid one, so this downloads only on a miss.
ensure_ghosttykit() {
  if [ -f GhosttyKit.xcframework/Info.plist ]; then
    return 0
  fi
  rm -rf GhosttyKit.xcframework
  resolve_ghostty_sha
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
}

# Compile-avoidance shadow (RFC #15391): classify whether the pull request's
# package edits keep every importer-visible interface. Observation only; the
# script never fails and macOS status reads its receipt line.
interface_fingerprint() {
  case "$event" in
    pull_request|merge_group) ;;
    *) return 0 ;;
  esac
  [ -s "$changed" ] || return 0
  echo "::group::Package interface fingerprint"
  python3 scripts/ci/package_interface_fingerprint.py --changed-files "$changed" || true
  echo "::endgroup::"
}

# Sets pkgdir and swift_test_args for one package. The prebuild and the test
# pass share them, so the test pass finds the prebuilt products up to date.
package_args() {
  local pkg="$1"
  pkgdir=""
  if [[ "$pkg" == */* ]]; then
    # A path is accepted only when it is exactly Packages/<group>/<name> with a
    # Package.swift (2026-10-04: a path looked up as a name compiled nothing).
    if [[ "$pkg" =~ ^Packages/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$ && "$pkg" != *..* && -f "${pkg%/}/Package.swift" ]]; then
      pkgdir="${pkg%/}"
    fi
  elif [[ "$pkg" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    # Packages live under group folders (Packages/{Shared,iOS,macOS}/);
    # resolve the actual directory so this list stays group-agnostic.
    pkgdir="$(find Packages -mindepth 2 -maxdepth 2 -type d -name "$pkg" -print -quit)"
    [ -z "$pkgdir" ] || [ -f "$pkgdir/Package.swift" ] || pkgdir=""
  fi
  if [ -z "$pkgdir" ]; then
    echo "package '$pkg' not found: give a name under Packages/*/ or a Packages/<group>/<name> path with a Package.swift"
    return 1
  fi
  swift_test_args=(--package-path "$pkgdir" ${swift_test_debug_info_args[@]+"${swift_test_debug_info_args[@]}"})
  if [ -n "${CMUX_SWIFT_SANITIZE:-}" ]; then
    swift_test_args+=(--sanitize="$CMUX_SWIFT_SANITIZE" --scratch-path "$pkgdir/.build-sanitize-$CMUX_SWIFT_SANITIZE"
      "${sanitize_link_flags[@]}")
  fi
  swiftpm_binary_module_guard "$pkgdir" "$pkgdir/.build${CMUX_SWIFT_SANITIZE:+-sanitize-$CMUX_SWIFT_SANITIZE}"
}

# record_built_ref PKGDIR: after a complete build of PKGDIR, name the commit in
# its .build. A fleet worker keeps a warm .build after a failed or cancelled step
# only when this marker was written for the step's commit during the step (hq
# build-fleet cmd/worker/step_warm.go); a half-written .build is rebuilt cold.
# Sanitizer builds use their own scratch path, which never stays warm.
record_built_ref() {
  [ -z "${CMUX_SWIFT_SANITIZE:-}" ] && [ -d "$1/.build" ] || return 0
  git rev-parse HEAD > "$1/.build/.cmux-ci-built-ref" 2>/dev/null || true
}

# One package's build. It exits non-zero when the package is not found or its
# build fails, so a compile step run on its own is never green without a
# compile (2026-10-04 false green). prebuild_packages ignores its status: a
# package whose prebuild fails is built again by its `swift test`, which
# reports the error in that package's group as before.
prebuild_one() {
  local pkg="$1" log="$2" started=$SECONDS status=0
  if ! package_args "$pkg" > "$log" 2>&1; then
    cat "$log" >&2
    echo "error: prebuild of $pkg compiled nothing: package not found." >&2
    return 2
  fi
  python3 scripts/ci/run_with_timeout.py \
    --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
    -- swift build --build-tests "${swift_test_args[@]}" > "$log" 2>&1 < /dev/null || status=$?
  if [ "$status" -eq 0 ]; then
    record_built_ref "$pkgdir"
    echo "Prebuilt $pkg in $((SECONDS - started))s."
    return 0
  fi
  # The GhosttyKit packages exit 1 on the known cosmetic binaryTarget
  # diagnostic after a complete build; anything else is a failed build.
  if [ "$status" -eq 1 ] && grep -q 'GhosttyKit\.xcframework' "$pkgdir/Package.swift" 2>/dev/null \
    && grep -Fq 'Build complete!' "$log" && grep -Eq 'unexpected binary' "$log"; then
    record_built_ref "$pkgdir"
    echo "Prebuilt $pkg in $((SECONDS - started))s (tolerated the GhosttyKit binaryTarget diagnostic)."
    return 0
  fi
  echo "Prebuild of $pkg exited $status after $((SECONDS - started))s (log: $log)." >&2
  return "$status"
}

# Every package is its own SwiftPM root with its own .build, so each selected
# package compiles its whole dependency closure from scratch, and most of a
# package's lane time is that build. Build and test one after another left the
# runner mostly idle: one package build rarely fills the cores. Build the
# selected packages CMUX_SWIFT_PACKAGE_BUILD_JOBS at a time first; the test
# pass below then finds each build up to date and runs the tests serially as
# before, so no two packages' tests ever overlap.
#
# A fleet step runs with the cores its worker granted it (CMUX_CI_CPU_BUDGET,
# hq build-fleet internal/cpubudget), and every swift build here passes --jobs
# of that grant (swift-test-debug-info.sh). Parallel package builds therefore
# split the grant: at most one build per 2 granted cores, each build getting
# its share as its own CMUX_CI_CPU_BUDGET (3 builds x 2 cores on a 6-core
# grant, where they ran 3 x 6 = 18 compile jobs before). A grant below 4
# leaves one build at a time: the test pass then builds each package in turn.
prebuild_packages() {
  local jobs="${CMUX_SWIFT_PACKAGE_BUILD_JOBS:-3}"
  if ! [[ "$jobs" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  local grant_env=()
  if [[ "${CMUX_CI_CPU_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
    local by_grant=$((CMUX_CI_CPU_BUDGET / 2))
    [ "$by_grant" -ge "$jobs" ] || jobs="$by_grant"
    [ "$jobs" -lt 1 ] || grant_env=(CMUX_CI_CPU_BUDGET="$((CMUX_CI_CPU_BUDGET / jobs))")
  fi
  if [ "$jobs" -le 1 ] || [ "${SELECTED_COUNT:-0}" -le 1 ]; then
    return 0
  fi
  local logs="$work/package-prebuild" started=$SECONDS
  mkdir -p "$logs"
  echo "::group::Prebuild $SELECTED_COUNT Swift packages, $jobs at a time${grant_env[0]:+ (${grant_env[0]} each)}"
  grep -v '^$' "$selected" \
    | env RUNNER_TEMP="$work" ${grant_env[@]+"${grant_env[@]}"} xargs -P "$jobs" -I '{}' \
      bash "$lane_script" prebuild-one '{}' "$logs/{}.log" || true
  echo "::endgroup::"
  echo "Prebuilt $SELECTED_COUNT Swift packages in $((SECONDS - started))s."
}

run_package_tests() {
  # No Xcode scheme executes the SPM package test targets. Run them here
  # so package tests (settings stores, secret-file migration, socket-control
  # convergence, etc.) are a real CI gate, not just compiled.
  # Scoped to packages that build headlessly via SwiftPM (no GhosttyKit /
  # app-target dependency). Add a package here once its `swift test`
  # is confirmed to resolve standalone. A GhosttyKit-referencing
  # package (references_ghosttykit) is the exception: its binaryTarget only needs the
  # xcframework present at the repo root (downloaded earlier in this
  # lane), and their test runners link a C stub for the @_silgen_name
  # symbol instead of the GhosttyKit archive.
  selected="$SELECTED_PACKAGES"
  test -f "$selected"
  echo "Testing $SELECTED_COUNT selected Swift packages."
  # SwiftPM emits an error-severity diagnostic while planning the
  # GhosttyKit binaryTarget (the xcframework's static archive is not
  # lib-prefixed: "unexpected binary name"/"unexpected binary
  # framework"). The build and every test still succeed, but the
  # diagnostic poisons the process exit code on a fresh .build. For
  # the GhosttyKit-referencing packages only, tolerate exactly that
  # case: a nonzero exit passes only when the all-tests-passed summary
  # is present, no test failures are reported, and the only error
  # lines are that known diagnostic. Everything else (compile errors,
  # test failures, crashes) still fails the lane.
  #
  # Every `swift test` below streams live and into "$log" through the
  # hang watchdog. Once the build is done, no test starting or
  # finishing for CMUX_SWIFT_TEST_STALL_SECONDS is a hang: the watchdog
  # names the unfinished tests, samples the xctest and
  # swiftpm-testing-helper stacks into the log, kills the tree and
  # exits 124, which fails the package. The longest single test in
  # these packages takes under a minute. The total limit is a backstop
  # for a run that keeps making slow progress.
  log="$(mktemp -t swift-package-test.XXXXXX)"
  run_swift_test() {
    test_status=0
    python3 scripts/ci/hung_test_watchdog.py \
      --stall-seconds "${CMUX_SWIFT_TEST_STALL_SECONDS:-180}" \
      --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
      --sample-seconds 5 --label "$pkg" --log "$log" \
      -- swift test "${swift_test_args[@]}" < /dev/null || test_status=$?
    if toolchain_mismatch "$log" "$pkg"; then
      [ "$test_status" -ne 0 ] || test_status=1
    fi
  }
  has_other_error() {
    awk '
      /unexpected binary/ { next }
      /^[[:space:]]*warning:/ { next }
      /:[0-9]+:[0-9]+:[[:space:]]+warning:/ { next }
      /(^|[^a-zA-Z])error:/ { found = 1 }
      END { exit found ? 0 : 1 }
    ' "$log"
  }
  # Every selected package runs even after another one fails, so one broken
  # or hung package cannot hide the results of the packages after it.
  # test_package returns the package's status instead of exiting; every
  # package gets a summary row, and the summary at the end fails the lane.
  if grep -Eqx 'CmuxNext|Packages/macOS/CmuxNext/?' "$selected"; then
    ensure_web_bundles
  fi
  prebuild_packages
  run_default_package_test() {
    # Blacksmith macOS runners intermittently abort a package's
    # test runner at startup (signal 5/6 immediately after "Build
    # complete!", zero test output). That is a runner flake, not a
    # test failure: retry exactly once, and only when no test
    # output was emitted.
    run_swift_test
    if [ "$test_status" -ne 0 ] \
      && grep -Fq 'Build complete!' "$log" \
      && grep -Eq 'Exited with unexpected signal code [56]([^0-9]|$)' "$log" \
      && ! grep -Eq '^(Test Suite|Test Case|◇ |↳ |✔ |✘ )' "$log"; then
      echo "Test runner crashed at startup (runner flake); retrying $pkg once."
      run_swift_test
    fi
    if [ "$test_status" -ne 0 ]; then
      return "$test_status"
    fi
    python3 scripts/ci/require_swift_test_execution.py --log "$log" || return $?
  }
  test_package() {
    local pkg="$1"
    package_args "$pkg" || return 1
    case "$pkg" in
    # These packages have process-tree suites whose child fixtures
    # share global process resources; run each suite in its own Swift
    # Testing process.
    CmuxAuthRuntime|CmuxIrohTransport|CmuxIrxTransport)
      ./scripts/ci/run-swift-testing-suites.sh "$pkgdir" || return $?
      ;;
    *)
      if ! references_ghosttykit "$pkg"; then
        run_default_package_test
        return $?
      fi
      run_swift_test
      if [ "$test_status" -ne 0 ]; then
        if [ "$test_status" -eq 1 ] \
          && grep -Eq 'error:.*unexpected binary' "$log" \
          && python3 scripts/ci/require_swift_test_execution.py --log "$log" \
          && ! grep -Eq 'with [1-9][0-9]* failures?' "$log" \
          && ! grep -Fq 'Exited with unexpected signal code' "$log" \
          && ! has_other_error; then
          echo "Tolerated cosmetic GhosttyKit binaryTarget diagnostic; all tests passed."
        else
          return "$test_status"
        fi
      else
        python3 scripts/ci/require_swift_test_execution.py --log "$log" || return $?
      fi
      ;;
    esac
  }

  summary=()
  passed=()
  if [ -f "$reused_packages" ]; then
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && passed+=("$pkg")
    done < "$reused_packages"
  fi
  failed=0
  first_failure_status=0
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    echo "::group::swift test $pkg"
    started=$SECONDS
    package_status=0
    test_package "$pkg" < /dev/null || package_status=$?
    echo "::endgroup::"
    seconds=$((SECONDS - started))
    if [ "$package_status" -eq 0 ]; then
      result=passed
      passed+=("$pkg")
    else
      failed=$((failed + 1))
      [ "$first_failure_status" -ne 0 ] || first_failure_status="$package_status"
      if [ "$package_status" -eq 124 ]; then
        # The watchdog already annotated the stall with the tests it
        # stopped; one annotation per package is enough.
        result=stalled
      else
        result="failed (exit $package_status)"
        echo "::error title=Swift package tests failed::$pkg failed with exit status $package_status after ${seconds}s"
      fi
    fi
    summary+=("$(printf '%-34s %-18s %6ss' "$pkg" "$result" "$seconds")")
  done < "$selected"

  table="$(
    printf '%-34s %-18s %7s\n' package result time
    printf '%s\n' ${summary[@]+"${summary[@]}"}
  )"
  printf 'Swift package test results:\n%s\n' "$table"
  record_passed ${passed[@]+"${passed[@]}"}
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Swift package tests\n\n```\n%s\n```\n' "$table" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$failed" -ne 0 ]; then
    echo "$failed of ${#summary[@]} Swift packages failed."
    exit "$first_failure_status"
  fi
}

# The cmux-next package tests read the web bundles, which are build output since cx-vn5:
# make them current before a CmuxNext build (scripts/ci/ensure-web-bundles.sh).
ensure_web_bundles() {
  echo "::group::cmux-next web bundles"
  bash scripts/ci/ensure-web-bundles.sh
  echo "::endgroup::"
}

# The live-daemon suites (FirstLaunchTests, ClassicImportTests,
# ClassicMigrationTests, ...) start this tree's hosted cmux-tui; without it
# they skip. Fetch it once, as run-swift-testing-suites.sh does: this head's
# tree, else the newest published tree when the head changes no cmux-tui input.
# Never waits for an unpublished tree, and a failed fetch only means those
# suites skip. CMUX_NEXT_TUI_TREE_PATH names the binary for the tests.
ensure_cmux_tui_tree() {
  [ -z "${CMUX_NEXT_TUI_TREE_PATH:-}" ] || return 0
  local pin=scripts/cmux-next/pin-cmux-tui.sh tree_path key
  [ -f "$pin" ] || return 0
  echo "::group::cmux-tui for the live-daemon suites"
  export CMUX_TUI_TREE_WAIT_SECONDS="${CMUX_TUI_TREE_WAIT_SECONDS:-0}"
  if tree_path="$(bash "$pin" path 2>/dev/null)" && [ -n "$tree_path" ]; then
    if [ ! -x "$tree_path" ] && ! bash "$pin" fetch >&2; then
      tree_path=""
      if key="$(bash "$pin" fallback-key 2>/dev/null)" && [ -n "$key" ] && CMUX_TUI_TREE_KEY="$key" bash "$pin" fetch >&2; then
        tree_path="$(CMUX_TUI_TREE_KEY="$key" bash "$pin" path 2>/dev/null)" || tree_path=""
        echo "This head's cmux-tui tree is not published; the live-daemon suites use the newest published tree $key."
      else
        echo "pin-cmux-tui.sh fetch failed; the live-daemon suites will skip."
      fi
    fi
    [ -z "$tree_path" ] || [ ! -x "$tree_path" ] || export CMUX_NEXT_TUI_TREE_PATH="$tree_path"
  fi
  echo "::endgroup::"
}

# On Linux a suite runs only for a package scripts/ci/swift-linux-packages.txt lists, with that row's
# ENV and only filters that name one of its test targets; it selects no Xcode and no macOS SDK.
# CMUX_PACKAGE_LANE_TEST_OS stands in for `uname -s` in the lane's tests (Linux or Darwin, on any host).
linux_list=scripts/ci/swift-linux-packages.txt
lane_os="${CMUX_PACKAGE_LANE_TEST_OS:-$(uname -s)}"
linux_suite_setup() {
  local dir targets envs row="" filter target ok pair
  if [ -f "$linux_list" ]; then
    row="$(awk -v p="$suite_package" '$1 == p { print; exit }' "$linux_list")"
  fi
  if [ -z "$row" ]; then
    echo "::error title=Not a Linux package::package-test-lane.sh: $suite_package is not in $linux_list; its suites run on macOS" >&2
    exit 2
  fi
  read -r dir targets envs <<< "$row"
  for filter in "${suite_filters[@]}"; do
    ok=0
    IFS=, read -r -a linux_targets <<< "$targets"
    for target in "${linux_targets[@]}"; do
      case "$filter" in "$target"|"$target".*|"$target"/*) ok=1 ;; esac
    done
    if [ "$ok" -ne 1 ]; then
      echo "::error title=Not a Linux test target::package-test-lane.sh: filter '$filter' names none of $suite_package's Linux test targets ($targets); it runs on macOS" >&2
      exit 2
    fi
  done
  if [ "${envs:--}" != - ]; then
    IFS=, read -r -a linux_envs <<< "$envs"
    for pair in "${linux_envs[@]}"; do
      [[ "$pair" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9_.:/-]*$ ]] || { echo "package-test-lane.sh: bad ENV '$pair' in $linux_list" >&2; exit 2; }
      export "${pair?}"
    done
  fi
  echo "Linux: $(swift --version 2>/dev/null | head -n 1) (${envs:--})"
}

# swift_filter FILTER: the --filter regex for FILTER. swift test matches it unanchored, so on Linux,
# where only the listed targets may run, it is anchored with its dots escaped and must end at a
# target, suite or test boundary: ListedTests never reaches ListedTestsExtra. The suite parser
# accepts only [A-Za-z0-9_./:-] in a filter, so '.' is its one regex metacharacter (no |, *, [, (,
# ^, $, +, ?, \). macOS passes FILTER as is.
swift_filter() {
  if [ "$lane_os" = Linux ]; then
    printf '^%s($|[./(])' "${1//./\\.}"
  else
    printf '%s' "$1"
  fi
}

run_suite() {
  if [ "$lane_os" = Linux ]; then
    linux_suite_setup
  else
    select_xcode
    echo "Xcode: $DEVELOPER_DIR"
  fi
  if grep -q 'GhosttyKit\.xcframework' "$suite_package/Package.swift"; then
    ensure_ghosttykit
  fi
  # CMUX_SWIFT_SUITE_CONFIGURATION=release builds the suites optimized (measurements of what the
  # user runs); @testable imports then need -enable-testing. The default stays debug.
  local configuration=(-c "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}" ${swift_test_debug_info_args[@]+"${swift_test_debug_info_args[@]}"})
  # Release keeps DEBUG defined, so test helpers behind #if DEBUG still build; the code is optimized.
  # The Xcode 26.6 optimizer crashes in CopyPropagation on CmuxNextSettingsTests (signal 6), so a
  # release suite build turns that one SIL pass off.
  if [ "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}" = release ]; then
    configuration+=(-Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation)
  fi
  # CMUX_SWIFT_SANITIZE (crash program phase 3): the suites build and run under the sanitizer in
  # its own scratch folder; the group line names it, so a sanitizer step's log shows it ran.
  if [ -n "${CMUX_SWIFT_SANITIZE:-}" ]; then
    configuration+=(--sanitize="$CMUX_SWIFT_SANITIZE" --scratch-path "$suite_package/.build-sanitize-$CMUX_SWIFT_SANITIZE"
      "${sanitize_link_flags[@]}")
  fi
  if [ "$suite_package" = Packages/macOS/CmuxNext ]; then
    ensure_web_bundles
    ensure_cmux_tui_tree
  fi
  local scratch="$suite_package/.build${CMUX_SWIFT_SANITIZE:+-sanitize-$CMUX_SWIFT_SANITIZE}"
  swiftpm_binary_module_guard "$suite_package" "$scratch"
  echo "::group::swift build --build-tests ${configuration[*]} $suite_package"
  local build_log build_status=0
  build_log="$(mktemp -t swift-suite-build.XXXXXX)"
  swift build --build-tests "${configuration[@]}" --package-path "$suite_package" < /dev/null 2>&1 \
    | tee "$build_log" || build_status=$?
  # Backstop for a stale module the guard did not see (a header outside a
  # binary target): one build from clean outputs, as a cold slot would do.
  if [ "$build_status" -ne 0 ] && swiftpm_stale_module_failure "$build_log"; then
    echo "::warning title=Stale precompiled module::$suite_package: the warm build read a stale explicit module; building again from clean outputs"
    swiftpm_purge_build_outputs "$scratch"
    swiftpm_binary_module_guard "$suite_package" "$scratch"
    build_status=0
    swift build --build-tests "${configuration[@]}" --package-path "$suite_package" < /dev/null || build_status=$?
  fi
  rm -f "$build_log"
  [ "$build_status" -eq 0 ] || exit "$build_status"
  record_built_ref "$suite_package"
  echo "::endgroup::"
  # swift build copies String Catalogs into the resource bundles uncompiled; without the
  # compiled <lang>.lproj tables, localization suites fail (cmux-next.yml runs the same step).
  # (xcstringstool is Xcode's: on Linux the listed packages have no catalogs, and their CI job proves it.)
  if [ "$lane_os" != Linux ] && [ -x scripts/cmux-next/compile-string-catalogs.sh ]; then
    (cd "$suite_package" && "$OLDPWD/scripts/cmux-next/compile-string-catalogs.sh")
  fi
  # One build serves every suite. Each suite runs in its own `swift test` so the
  # summary has a result per suite and one failure does not hide the others.
  # A suite none of whose tests ran (a trait skipped them: no display, no
  # pasteboard) reads "skipped", never "passed": Swift Testing's own summary
  # counts skipped tests, so a headless worker printed "passed" for suites
  # that never ran (aws-m4pro-6, 2026-10-26). CMUX_TEST_REQUIRE_GUI=1 (a job
  # that asked for a GUI session) fails on any skip.
  # A suite the lane named that ran none of its tests is no result, and a test
  # skipped because this tree's cmux-tui is missing ("needs the same-tree
  # cmux-tui", the live-daemon suites' trait) is no result too: either fails the
  # step, never "passed" or a green "skipped". The line says "required tests did
  # not run", which the per-test classifier (test_reds) reads as a run that is not whole, so
  # the base-red excuse never excuses it.
  local log filter status started result failed=0 first_failure_status=0 rows=()
  local ran skipped reason daemon_skips display_skips hint
  for filter in "${suite_filters[@]}"; do
    echo "::group::swift test --filter $filter"
    log="$(mktemp -t swift-suite-test.XXXXXX)"
    started=$SECONDS
    status=0
    python3 scripts/ci/hung_test_watchdog.py \
      --stall-seconds "${CMUX_SWIFT_TEST_STALL_SECONDS:-180}" \
      --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
      --sample-seconds 5 --label "$filter" --log "$log" \
      -- swift test "${configuration[@]}" --package-path "$suite_package" --skip-build --filter "$(swift_filter "$filter")" < /dev/null || status=$?
    if toolchain_mismatch "$log" "$filter in $suite_package"; then
      [ "$status" -ne 0 ] || status=1
    elif [ "$status" -eq 0 ]; then
      python3 scripts/ci/require_swift_test_execution.py --log "$log" --skip-report "$log.skips" || status=$?
    fi
    echo "::endgroup::"
    ran=0 skipped=0 display_skips=0 hint=""
    # Read from the log itself, whatever the exit status or CMUX_TEST_REQUIRE_GUI: a failing test or a GUI
    # skip beside a missing-cmux-tui skip must not hide the no-result line.
    daemon_skips="$(grep -cE '(Test|Suite) .+ skipped: "needs the same-tree cmux-tui' "$log" || true)"
    if [ "$daemon_skips" -gt 0 ]; then
      echo "::error title=Swift suite no result::$filter in $suite_package: required tests did not run: tests skipped because this tree's cmux-tui is missing (CMUX_NEXT_TUI_TREE_PATH=${CMUX_NEXT_TUI_TREE_PATH:-unset}); no result, never a pass or a base red"
    fi
    if [ "$status" -eq 0 ]; then
      read -r ran skipped < "$log.skips"
      if [ "$skipped" -gt 0 ]; then
        while IFS= read -r reason; do
          echo "$filter: skipped $reason"
          # The suites' own display traits: "the drag tests need a display", "needs an awake display ...",
          # "run on a GUI host", "no GUI login session".
          if printf '%s' "$reason" | grep -qiE 'display|screen|GUI'; then display_skips=$((display_skips + 1)); fi
        done < <(tail -n +2 "$log.skips")
      fi
      if [ "$skipped" -gt 0 ] && [ "${CMUX_TEST_REQUIRE_GUI:-}" = 1 ]; then
        status=1
      fi
    fi
    rm -f "$log.skips"
    if [ "$status" -eq 0 ] && { [ "$ran" -eq 0 ] || [ "$daemon_skips" -gt 0 ]; }; then
      failed=$((failed + 1))
      status=1
      [ "$first_failure_status" -ne 0 ] || first_failure_status="$status"
      if [ "$daemon_skips" -gt 0 ]; then
        result="no result (no cmux-tui)"
      else
        result="no result (0 ran)"
        # cmux-ci sends a step naming a listed display suite (scripts/ci/display-suites.txt) to a display
        # worker and marks it CMUX_CI_DISPLAY_ROUTED=1; the lane's hint is for a step routing did not reach.
        if [ "$display_skips" -gt 0 ] && [ "${CMUX_CI_DISPLAY_ROUTED:-}" = 1 ]; then
          hint="; this suite needs a display and was sent to a display worker, whose console session was lost (locked or logged out)"
        elif [ "$display_skips" -gt 0 ]; then
          hint="; this suite needs a display; rerun with CMUX_TEST_REQUIRE_GUI=1"
        fi
        echo "::error title=Swift suite no result::$filter in $suite_package: required tests did not run: none of its $skipped tests ran (all skipped)$hint; no result, never a pass or a base red"
      fi
    elif [ "$status" -eq 0 ] && [ "$skipped" -gt 0 ]; then
      result="passed, $skipped skipped"
    elif [ "$status" -eq 0 ]; then
      result=passed
    elif [ "$skipped" -gt 0 ] && [ "${CMUX_TEST_REQUIRE_GUI:-}" = 1 ]; then
      failed=$((failed + 1))
      [ "$first_failure_status" -ne 0 ] || first_failure_status="$status"
      result="failed ($skipped skipped)"
      echo "::error title=Swift suite skipped::$filter in $suite_package: $skipped tests skipped with CMUX_TEST_REQUIRE_GUI=1"
    else
      failed=$((failed + 1))
      [ "$first_failure_status" -ne 0 ] || first_failure_status="$status"
      if [ "$status" -eq 124 ]; then result="stalled/timeout"; else result="failed (exit $status)"; fi
      echo "::error title=Swift suite failed::$filter in $suite_package: $result after $((SECONDS - started))s"
    fi
    rows+=("$(printf '%-48s %-24s %6ss' "$filter" "$result" "$((SECONDS - started))")")
  done
  local table
  table="$(printf '%-48s %-24s %7s\n' suite result time; printf '%s\n' "${rows[@]}")"
  printf 'Swift suite results (%s):\n%s\n' "$suite_package" "$table"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Swift suites (%s)\n\n```\n%s\n```\n' "$suite_package" "$table" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$failed" -ne 0 ]; then
    echo "$failed of ${#suite_filters[@]} suites failed or gave no result."
    exit "$first_failure_status"
  fi
  echo "All ${#suite_filters[@]} suites passed."
}

# compile_one LOG SWIFT_BUILD_ARGS...: one `swift build` into LOG (and the step
# log), built again from clean outputs when it read a stale explicit module
# (the backstop run_suite has). Returns the build's status.
compile_one() {
  local log="$1" status=0
  shift
  swift build "$@" < /dev/null 2>&1 | tee "$log" || status=$?
  if [ "$status" -ne 0 ] && swiftpm_stale_module_failure "$log"; then
    echo "::warning title=Stale precompiled module::the warm build read a stale explicit module; building again from clean outputs"
    swiftpm_purge_build_outputs "$compile_scratch"
    swiftpm_binary_module_guard "$compile_pkgdir" "$compile_scratch"
    status=0
    swift build "$@" < /dev/null 2>&1 | tee "$log" || status=$?
  fi
  return "$status"
}

run_compile_tests() {
  # The merge base may be missing from a shallow step checkout: fetch that one commit.
  if ! git cat-file -e "$compile_base^{commit}" 2>/dev/null; then
    local depth=()
    [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
    git fetch --no-tags --no-write-fetch-head ${depth[@]+"${depth[@]}"} \
      "$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)" "$compile_base" \
      || { echo "compile-tests: could not fetch the merge base $compile_base" >&2; exit 3; }
  fi
  local changed="$work/compile-tests-changed.txt" plan="$work/compile-tests-plan.txt"
  git diff --no-renames --name-only "$compile_base" HEAD > "$changed" \
    || { echo "compile-tests: no diff from $compile_base" >&2; exit 3; }
  python3 scripts/ci/compile_test_plan.py --changed-files "$changed" > "$plan" \
    || { echo "compile-tests: compile_test_plan.py failed" >&2; exit 3; }
  echo "compile-tests: $(wc -l < "$changed" | tr -d ' ') files changed since ${compile_base:0:12}"
  if [ ! -s "$plan" ]; then
    echo "compile-tests: the change reaches no test target; nothing to compile."
    return 0
  fi
  echo "compile-tests plan (package, then its test targets; none listed is every one):"
  sed 's/^/  /' "$plan"
  select_xcode
  echo "Xcode: $DEVELOPER_DIR"
  local words target log status started failed=0 rows=() builds submodules submodule refused
  local debug_args=(${swift_test_debug_info_args[@]+"${swift_test_debug_info_args[@]}"})
  log="$(mktemp -t swift-compile-tests.XXXXXX)"
  # The plan on fd 9: nothing a build step reads from stdin can eat its lines.
  while read -r -a words <&9; do
    [ "${#words[@]}" -gt 0 ] || continue
    compile_pkgdir="${words[0]}"
    compile_scratch="$compile_pkgdir/.build"
    if grep -q 'GhosttyKit\.xcframework' "$compile_pkgdir/Package.swift"; then
      ensure_ghosttykit
    fi
    if [ "$compile_pkgdir" = Packages/macOS/CmuxNext ]; then
      ensure_web_bundles
    fi
    # A fleet step checks the commit out with every submodule deinitialized:
    # populate the ones this package reaches (run-swift-testing-suites.sh does too).
    submodules=()
    while IFS= read -r submodule; do
      [ -n "$(ls -A "$submodule" 2>/dev/null)" ] || submodules+=("$submodule")
    done < <(python3 scripts/ci/swift_package_submodules.py "$PWD" "$compile_pkgdir")
    if [ "${#submodules[@]}" -gt 0 ]; then
      git submodule update --init --depth 1 -- "${submodules[@]}"
    fi
    swiftpm_binary_module_guard "$compile_pkgdir" "$compile_scratch"
    if [ "${#words[@]}" -gt 1 ]; then
      builds=("${words[@]:1}")
    else
      builds=(--build-tests)
    fi
    for target in "${builds[@]}"; do
      started=$SECONDS
      status=0
      refused=0
      if [ "$target" = --build-tests ]; then
        echo "::group::swift build --build-tests $compile_pkgdir"
        compile_one "$log" --build-tests ${debug_args[@]+"${debug_args[@]}"} --package-path "$compile_pkgdir" || status=$?
      else
        echo "::group::swift build --target $target ($compile_pkgdir)"
        compile_one "$log" ${debug_args[@]+"${debug_args[@]}"} --package-path "$compile_pkgdir" --target "$target" || status=$?
        # A SwiftPM that will not build one test target on its own: build them
        # all, once, in place of this package's remaining targets.
        if [ "$status" -ne 0 ] && grep -qiE "no (target|module) named|unknown target" "$log"; then
          echo "::warning title=compile-tests::swift build --target $target was refused; building every test target of $compile_pkgdir instead"
          refused=1
          target=--build-tests
          status=0
          compile_one "$log" --build-tests ${debug_args[@]+"${debug_args[@]}"} --package-path "$compile_pkgdir" || status=$?
        fi
      fi
      echo "::endgroup::"
      if [ "$status" -eq 0 ]; then
        rows+=("$(printf '%-34s %-30s %-10s %6ss' "${compile_pkgdir##*/}" "${target#--}" compiled "$((SECONDS - started))")")
      else
        failed=$((failed + 1))
        rows+=("$(printf '%-34s %-30s %-10s %6ss' "${compile_pkgdir##*/}" "${target#--}" FAILED "$((SECONDS - started))")")
        echo "::error title=Test target did not compile::$compile_pkgdir: ${target#--} (exit $status)"
        # The verdict now, before any later setup can end the run.
        echo "compile-tests: a test target did not compile: ${compile_pkgdir##*/} ${target#--}"
      fi
      [ "$refused" -eq 0 ] || break
    done
    [ "$failed" -ne 0 ] || record_built_ref "$compile_pkgdir"
  done 9< "$plan"
  rm -f "$log"
  local table
  table="$(printf '%-34s %-30s %-10s %7s\n' package target result time; printf '%s\n' "${rows[@]}")"
  printf 'compile-tests results:\n%s\n' "$table"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Test target compile\n\n```\n%s\n```\n' "$table" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$failed" -ne 0 ]; then
    echo "compile-tests: a test target did not compile ($failed of ${#rows[@]})"
    exit 1
  fi
  echo "compile-tests: every planned test target compiled (${#rows[@]})"
}

# cmux NEXT's tests start acpmux daemons. A lane given no home of its own (a fleet step, `cmux-ci
# run`) gets one for this run, never the host's ~/.acpmux, and ends that home's daemons and agents
# and deletes it on exit (tests/test_ci_acpmux_job_home.py). An empty ACPMUX_SOCKET is unset.
end_own_acpmux_home() {
  local acpmux
  acpmux="$(PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin" command -v acpmux || true)"
  [ -z "$acpmux" ] || env -u ACPMUX_SOCKET ACPMUX_HOME="$own_acpmux_home" "$acpmux" daemon shutdown --end-agents >/dev/null 2>&1 || true
  rm -rf "$own_acpmux_home"
}
case "$phase" in
  suite|packages|run)
    if [ -z "${ACPMUX_HOME:-}" ]; then
      own_acpmux_home="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/acpmux-home.XXXXXX")"
      export ACPMUX_HOME="$own_acpmux_home" ACPMUX_SOCKET=
      trap 'status=$?; end_own_acpmux_home; exit "$status"' EXIT
    fi
    ;;
esac

case "$phase" in
  suite)
    run_suite
    ;;
  compile-tests)
    run_compile_tests
    ;;
  prebuild-one)
    prebuild_one "$prebuild_package" "$prebuild_log"
    ;;
  ghostty-sha)
    resolve_ghostty_sha
    echo "${GHOSTTY_SHA:-}"
    ;;
  select)
    ensure_parent
    select_packages
    ;;
  packages)
    run_package_tests
    ;;
  run)
    ensure_parent
    # Under Actions the select step already wrote the outputs; this run only
    # needs the files.
    GITHUB_OUTPUT="" select_packages
    select_xcode
    interface_fingerprint
    if [ "$needs_ghosttykit" = true ]; then
      ensure_ghosttykit
    fi
    SELECTED_PACKAGES="$selected" SELECTED_COUNT="$count" run_package_tests
    ;;
esac
