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
#             filter that runs no test fails. The watchdog limits apply to
#             each suite (CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS, 900 s), so N
#             suites can take N times that; cmux-ci's --timeout covers the step.
#             Lanes: cmux-ci run --class light --script
#             scripts/ci/package-test-lane.sh --ref SHA --arg=suite
#             --arg=Packages/macOS/CmuxNext --arg=SuiteA,SuiteB,SuiteC
#             --env CMUX_CI_XCODE_APP=/Applications/Xcode_26.6.app
#
# --event and --full-suite default to EVENT_NAME and FULL_SUITE. Run from the
# repository root; every helper path is relative to it.
set -euo pipefail

phase=run
case "${1:-}" in
  run|select|packages|ghostty-sha) phase="$1"; shift ;;
  prebuild-one) phase="$1"; prebuild_package="$2"; prebuild_log="$3"; shift 3 ;;
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
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
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
  git fetch --no-tags --no-write-fetch-head --depth=2 "$remote" "$(git rev-parse HEAD)" || true
}

# A package whose manifest names GhosttyKit.xcframework has a binaryTarget on
# the xcframework at the repository root: the lane downloads it first, and its
# `swift test` may exit 1 on a cosmetic binaryTarget diagnostic (test_package).
references_ghosttykit() {
  local dir
  dir="$(find Packages -mindepth 2 -maxdepth 2 -type d -name "$1" -print -quit)"
  [ -n "$dir" ] && grep -q 'GhosttyKit\.xcframework' "$dir/Package.swift" 2>/dev/null
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

write_package_input_keys() {
  [ -f "${selected:-}" ] || return 0
  local receipt_file="$work/package-input-keys.json" receipt
  python3 scripts/ci/package_input_key.py --root . --packages-file "$selected" --output "$receipt_file"
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
  echo "::error title=Swift toolchain and SDK differ::$2: swift test reported '$hit' with DEVELOPER_DIR=$DEVELOPER_DIR SDKROOT=${SDKROOT:-unset}; no test result here is valid"
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
  swift_test_args=(--package-path "$pkgdir")
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
    echo "Prebuilt $pkg in $((SECONDS - started))s."
    return 0
  fi
  # The GhosttyKit packages exit 1 on the known cosmetic binaryTarget
  # diagnostic after a complete build; anything else is a failed build.
  if [ "$status" -eq 1 ] && grep -q 'GhosttyKit\.xcframework' "$pkgdir/Package.swift" 2>/dev/null \
    && grep -Fq 'Build complete!' "$log" && grep -Eq 'unexpected binary' "$log"; then
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
prebuild_packages() {
  local jobs="${CMUX_SWIFT_PACKAGE_BUILD_JOBS:-3}"
  if ! [[ "$jobs" =~ ^[0-9]+$ ]] || [ "$jobs" -le 1 ] || [ "${SELECTED_COUNT:-0}" -le 1 ]; then
    return 0
  fi
  local logs="$work/package-prebuild" started=$SECONDS
  mkdir -p "$logs"
  echo "::group::Prebuild $SELECTED_COUNT Swift packages, $jobs at a time"
  grep -v '^$' "$selected" \
    | RUNNER_TEMP="$work" xargs -P "$jobs" -I '{}' \
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

run_suite() {
  select_xcode
  echo "Xcode: $DEVELOPER_DIR"
  if grep -q 'GhosttyKit\.xcframework' "$suite_package/Package.swift"; then
    ensure_ghosttykit
  fi
  # CMUX_SWIFT_SUITE_CONFIGURATION=release builds the suites optimized (measurements of what the
  # user runs); @testable imports then need -enable-testing. The default stays debug.
  local configuration=(-c "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}")
  # Release keeps DEBUG defined, so test helpers behind #if DEBUG still build; the code is optimized.
  # The Xcode 26.6 optimizer crashes in CopyPropagation on CmuxNextSettingsTests (signal 6), so a
  # release suite build turns that one SIL pass off.
  if [ "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}" = release ]; then
    configuration+=(-Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation)
  fi
  if [ "$suite_package" = Packages/macOS/CmuxNext ]; then
    ensure_web_bundles
  fi
  echo "::group::swift build --build-tests ${configuration[*]} $suite_package"
  swift build --build-tests "${configuration[@]}" --package-path "$suite_package" < /dev/null
  echo "::endgroup::"
  # swift build copies String Catalogs into the resource bundles uncompiled; without the
  # compiled <lang>.lproj tables, localization suites fail (cmux-next.yml runs the same step).
  if [ -x scripts/cmux-next/compile-string-catalogs.sh ]; then
    (cd "$suite_package" && "$OLDPWD/scripts/cmux-next/compile-string-catalogs.sh")
  fi
  # One build serves every suite. Each suite runs in its own `swift test` so the
  # summary has a result per suite and one failure does not hide the others.
  local log filter status started result failed=0 first_failure_status=0 rows=()
  for filter in "${suite_filters[@]}"; do
    echo "::group::swift test --filter $filter"
    log="$(mktemp -t swift-suite-test.XXXXXX)"
    started=$SECONDS
    status=0
    python3 scripts/ci/hung_test_watchdog.py \
      --stall-seconds "${CMUX_SWIFT_TEST_STALL_SECONDS:-180}" \
      --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
      --sample-seconds 5 --label "$filter" --log "$log" \
      -- swift test "${configuration[@]}" --package-path "$suite_package" --skip-build --filter "$filter" < /dev/null || status=$?
    if toolchain_mismatch "$log" "$filter in $suite_package"; then
      [ "$status" -ne 0 ] || status=1
    elif [ "$status" -eq 0 ]; then
      python3 scripts/ci/require_swift_test_execution.py --log "$log" || status=$?
    fi
    echo "::endgroup::"
    if [ "$status" -eq 0 ]; then
      result=passed
    else
      failed=$((failed + 1))
      [ "$first_failure_status" -ne 0 ] || first_failure_status="$status"
      if [ "$status" -eq 124 ]; then result="stalled/timeout"; else result="failed (exit $status)"; fi
      echo "::error title=Swift suite failed::$filter in $suite_package: $result after $((SECONDS - started))s"
    fi
    rows+=("$(printf '%-48s %-18s %6ss' "$filter" "$result" "$((SECONDS - started))")")
  done
  local table
  table="$(printf '%-48s %-18s %7s\n' suite result time; printf '%s\n' "${rows[@]}")"
  printf 'Swift suite results (%s):\n%s\n' "$suite_package" "$table"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Swift suites (%s)\n\n```\n%s\n```\n' "$suite_package" "$table" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$failed" -ne 0 ]; then
    echo "$failed of ${#suite_filters[@]} suites failed."
    exit "$first_failure_status"
  fi
  echo "All ${#suite_filters[@]} suites passed."
}

case "$phase" in
  suite)
    run_suite
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
