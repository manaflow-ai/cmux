#!/usr/bin/env bash
# The swift-package-tests lane of ci-macos.yml as one script, so the same code
# runs on a GitHub runner and as a fleet ci-step (`cmux-ci run`, hq#794) from a
# fresh checkout of the commit on a mini.
#
# Usage: package-test-lane.sh [run|select|bonsplit|packages|ghostty-sha]
#          [--event[=]NAME] [--full-suite[=]true|false]
#
#   run       (default) select, then set up what the selection needs (Xcode,
#             GhosttyKit.xcframework, Rust) and run the Bonsplit and package
#             tests.
#   select    choose the packages. Under Actions it writes the step outputs
#             (selected_packages, selected_count, bonsplit, needs_ghosttykit,
#             needs_rust, changed_files) to GITHUB_OUTPUT.
#   bonsplit  run the Bonsplit package tests.
#   packages  run the packages listed in the file SELECTED_PACKAGES.
#   prebuild-one PACKAGE LOG
#             build PACKAGE and its tests into LOG; the packages phase runs
#             several of these at once before its serial test pass.
#   ghostty-sha  print the GhosttyKit revision a download would use (empty
#             when a ghostty submodule checkout provides it).
#
# --event and --full-suite default to EVENT_NAME and FULL_SUITE. Run from the
# repository root; every helper path is relative to it.
set -euo pipefail

phase=run
case "${1:-}" in
  run|select|bonsplit|packages|ghostty-sha) phase="$1"; shift ;;
  prebuild-one) phase="$1"; prebuild_package="$2"; prebuild_log="$3"; shift 3 ;;
esac
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

# A fleet step starts from a worktree without submodules. Bonsplit is a local
# package of several packages and is read by the selector, so it has to be
# there before anything else. A GitHub checkout already has it.
ensure_bonsplit() {
  if [ ! -f vendor/bonsplit/Package.swift ]; then
    git submodule update --init vendor/bonsplit
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

select_packages() {
  PACKAGES=(
    CMUXAuthCore
    CmuxAcpmux
    CmuxBrowser
    CmuxCanvasUI
    CmuxCloud
    CmuxCloudMachines
    CmuxCloudTui
    CmuxComputerUse
    CmuxCore
    CmuxRemoteDaemon
    CmuxRemoteWorkspace
    CmuxRemoteSession
    CmuxAgentChat
    CmuxAgentSessionStore
    CmuxAuthRuntime
    CmuxWorkspacePresence
    CmuxIrohTransport
    CmuxIrxTransport
    CmuxHive
    CmuxCommandPalette
    CmuxControlSocket
    CmuxFoundation
    CmuxGit
    CmuxMobileTerminalKit
    CmuxMobileWorkspace
    CmuxNotifications
    CmuxSettings
    CmuxSettingsUI
    CmuxSidebarGit
    CmuxSurfaceCatalogModel
    CmuxSudoBroker
    CmuxSudoBrokerUI
    CmuxTerminal
    CmuxTerminalCore
    CmuxTerminalImport
    CmuxTerminalPrediction
    CmuxUpdater
    CmuxWorkspaces
    CMUXAgentLaunch
    CmuxAgentJournal
    CmuxFilePreviewCore
    CmuxSyntaxHighlighting
    CmuxAppKitSupportUI
    CmuxCanvas
    CmuxCloudBannerCore
    CmuxCloudImagePaste
    CmuxCloudTunnelCore
    CMUXDebugLog
    CmuxExtensionKit
    CmuxFeedback
    CmuxLiveEval
    CmuxPanes
    CmuxPhonePush
    CMUXProjectModel
    CmuxSidebar
    CmuxSidebarInterpreterService
    CmuxSimulator
    CmuxSwiftRender
    CmuxSwiftRenderUI
    CmuxTestSupport
    CmuxUpdaterUI
    CmuxWindowing
  )

  changed="$work/changed-files.txt"
  selected="$work/selected-packages.txt"
  run_bonsplit=false
  if { [ "$event" = "pull_request" ] || [ "$event" = "merge_group" ]; } \
    && git diff --no-renames --name-only HEAD^1 HEAD > "$changed" 2>/dev/null; then
    output "changed_files=$changed"
    # vendor/bonsplit is a submodule, so a revision bump is the bare path.
    if grep -qE '^vendor/bonsplit(/|$)' "$changed" || grep -qxF '.github/workflows/ci.yml' "$changed"; then
      run_bonsplit=true
    fi
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
    run_bonsplit=true
    printf '%s\n' "${PACKAGES[@]}" > "$selected"
  fi
  if [ "$run_bonsplit" = true ]; then
    output "bonsplit=true"
  fi

  count="$(wc -l < "$selected" | tr -d ' ')"
  output "selected_packages=$selected"
  output "selected_count=$count"

  if grep -qxE 'CmuxTerminal|CmuxTerminalCore|CmuxCloudTui|CmuxCloud' "$selected"; then
    needs_ghosttykit=true
  else
    needs_ghosttykit=false
  fi
  if grep -qxF CmuxCommandPalette "$selected"; then
    needs_rust=true
  else
    needs_rust=false
  fi
  output "needs_ghosttykit=$needs_ghosttykit"
  output "needs_rust=$needs_rust"
  echo "Selected $count of ${#PACKAGES[@]} Swift packages."
}

# The workflow's "Select Xcode" step already exported DEVELOPER_DIR through
# GITHUB_ENV. A fleet step selects here, without touching the mini's
# host-global xcode-select default.
select_xcode() {
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    return 0
  fi
  local env_file="$work/xcode.env"
  : > "$env_file"
  GITHUB_ENV="$env_file" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$env_file" | tail -n 1)"
  test -n "$DEVELOPER_DIR"
  export DEVELOPER_DIR
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

install_rust() {
  ./scripts/install-rust-ci.sh
  # install-rust-ci.sh hands PATH to later workflow steps; this shell needs it now.
  export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$HOME/.cargo/bin:$PATH"
}

run_bonsplit_tests() {
  # Blacksmith macOS runners intermittently abort a package's test
  # runner at startup. Retry exactly once only for the known signal
  # 5/6 crash immediately after build and before test output, matching
  # the package loop below.
  # Output streams live through the hang watchdog, which fails a run
  # whose tests stop making progress (see the package loop below).
  log="$(mktemp -t bonsplit-test.XXXXXX)"
  run_swift_test() {
    test_status=0
    python3 scripts/ci/hung_test_watchdog.py \
      --stall-seconds "${CMUX_SWIFT_TEST_STALL_SECONDS:-180}" \
      --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
      --sample-seconds 5 --label Bonsplit --log "$log" \
      -- swift test --package-path vendor/bonsplit < /dev/null || test_status=$?
  }
  run_swift_test
  if [ "$test_status" -ne 0 ] \
    && grep -Fq 'Build complete!' "$log" \
    && grep -Eq 'Exited with unexpected signal code [56]([^0-9]|$)' "$log" \
    && ! grep -Eq '^(Test Suite|Test Case|◇ |↳ |✔ |✘ )' "$log"; then
    echo "Test runner crashed at startup (runner flake); retrying Bonsplit once."
    run_swift_test
  fi
  if [ "$test_status" -ne 0 ]; then
    exit "$test_status"
  fi
  python3 scripts/ci/require_swift_test_execution.py --log "$log"
}

# Sets pkgdir and swift_test_args for one package. The prebuild and the test
# pass share them, so the test pass finds the prebuilt products up to date.
package_args() {
  local pkg="$1"
  # Packages live under group folders (Packages/{Shared,iOS,macOS}/);
  # resolve the actual directory so this list stays group-agnostic.
  pkgdir="$(find Packages -mindepth 2 -maxdepth 2 -type d -name "$pkg" -print -quit)"
  if [ -z "$pkgdir" ]; then
    echo "package '$pkg' not found under Packages/*/ (renamed or moved?)"
    return 1
  fi
  swift_test_args=(--package-path "$pkgdir")
  # Preserve the notification workflow's warning gate without a
  # second package build or changing the existing startup retry.
  case "$pkg" in
    CMUXAgentLaunch|CmuxAgentJournal)
      swift_test_args+=(-Xswiftc -warnings-as-errors)
      ;;
  esac
}

# One package's build, for prebuild_packages. It never fails the lane: a
# package whose prebuild fails is built again by its `swift test`, which
# reports the error in that package's group as before.
prebuild_one() {
  local pkg="$1" log="$2" started=$SECONDS status=0
  package_args "$pkg" > "$log" 2>&1 || { echo "Prebuild skipped $pkg (not found)."; return 0; }
  python3 scripts/ci/run_with_timeout.py \
    --timeout-seconds "${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}" \
    -- swift build --build-tests "${swift_test_args[@]}" > "$log" 2>&1 < /dev/null || status=$?
  if [ "$status" -eq 0 ]; then
    echo "Prebuilt $pkg in $((SECONDS - started))s."
  else
    echo "Prebuild of $pkg exited $status after $((SECONDS - started))s; its swift test builds whatever is still missing (the GhosttyKit packages exit 1 here on the known binaryTarget diagnostic)."
  fi
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
  # The cmux-unit scheme only runs the cmuxTests app-host suite; it does
  # not execute the SPM package test targets. Run them here so package
  # tests (settings stores, secret-file migration, socket-control
  # convergence, etc.) are a real CI gate, not just compiled.
  # Scoped to packages that build headlessly via SwiftPM (no GhosttyKit /
  # app-target dependency). Add a package here once its `swift test`
  # is confirmed to resolve standalone. The GhosttyKit-referencing
  # packages (CmuxTerminalCore and the terminal packages stacked on
  # it) are the exception: their binaryTarget only needs the
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
  }
  if grep -qxF CmuxCommandPalette "$selected"; then
    # CmuxCommandPalette's nucleo FFI tests load the Rust dylib through
    # CMUX_NUCLEO_FFI_LIB (they skip when it is absent, so build it here
    # to keep the FFI parity suite a real gate).
    cargo build --manifest-path Native/CommandPaletteNucleoFFI/Cargo.toml --release
    export CMUX_NUCLEO_FFI_LIB="$PWD/Native/CommandPaletteNucleoFFI/target/release/libcmux_command_palette_nucleo_ffi.dylib"
  fi
  # Every selected package runs even after another one fails, so one
  # broken or hung package cannot hide the results of the packages
  # after it. test_package returns the package's status instead of
  # exiting; the summary at the end fails the lane.
  prebuild_packages
  test_package() {
    local pkg="$1"
    package_args "$pkg" || return 1
    case "$pkg" in
    # CmuxFoundation has several process-tree suites whose child
    # fixtures share global process resources; run each suite in its
    # own Swift Testing process just like the auth/transport suites.
    CmuxAgentChat|CmuxAuthRuntime|CmuxFoundation|CmuxIrohTransport|CmuxIrxTransport)
      ./scripts/ci/run-swift-testing-suites.sh "$pkgdir" || return $?
      ;;
    CmuxTerminal|CmuxTerminalCore|CmuxCloudTui|CmuxCloud)
      run_swift_test
      if [ "$test_status" -ne 0 ]; then
        if [ "$test_status" -eq 1 ] \
          && grep -Eq 'error:.*unexpected binary' "$log" \
          && python3 scripts/ci/require_swift_test_execution.py --log "$log" \
          && ! grep -Eq 'with [1-9][0-9]* failures?' "$log" \
          && ! grep -Fq 'Exited with unexpected signal code' "$log" \
          && ! grep -Eq '(^|[^a-zA-Z])error:' <<<"$(grep -v 'unexpected binary' "$log")"; then
          echo "Tolerated cosmetic GhosttyKit binaryTarget diagnostic; all tests passed."
        else
          return "$test_status"
        fi
      else
        python3 scripts/ci/require_swift_test_execution.py --log "$log" || return $?
      fi
      ;;
    *)
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

case "$phase" in
  prebuild-one)
    prebuild_one "$prebuild_package" "$prebuild_log"
    ;;
  ghostty-sha)
    resolve_ghostty_sha
    echo "${GHOSTTY_SHA:-}"
    ;;
  select)
    ensure_bonsplit
    ensure_parent
    select_packages
    ;;
  bonsplit)
    run_bonsplit_tests
    ;;
  packages)
    run_package_tests
    ;;
  run)
    ensure_bonsplit
    ensure_parent
    # Under Actions the select step already wrote the outputs; this run only
    # needs the files.
    GITHUB_OUTPUT="" select_packages
    select_xcode
    interface_fingerprint
    if [ "$needs_ghosttykit" = true ]; then
      ensure_ghosttykit
    fi
    if [ "$needs_rust" = true ]; then
      install_rust
    fi
    if [ "$run_bonsplit" = true ]; then
      run_bonsplit_tests
    fi
    SELECTED_PACKAGES="$selected" SELECTED_COUNT="$count" run_package_tests
    ;;
esac
