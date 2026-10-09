#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <package-path>" >&2
  exit 2
fi

package_path="$1"
if [[ "${CMUX_CI_REQUIRED_MACOS_SDK_MAJOR:-}" == "export-settings" ]]; then
  set -x
  CMUX_UPDATE_MDM_SCHEMA=1 swift test --package-path "$package_path" --filter ManagedPreferencesManifestTests
  CMUX_UPDATE_ACTION_SURFACES=1 swift test --package-path "$package_path" --filter SettingsSchemaExportTests
  for file in docs/mdm/com.manaflow.cmux.json docs/mdm/com.manaflow.cmux.plist docs/mdm/managed-preferences.md schemas/settings/settings-schema.json; do
    echo "BEGIN_ARTIFACT:$file"
    base64 < "$file" | tr -d "\n"
    echo
    echo "END_ARTIFACT:$file"
  done
  exit 0
fi
suite_timeout_seconds="${CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS:-300}"
if ! [[ "$suite_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
# Same stall rule as the package loop in ci-macos.yml: after the build, no test
# starting or finishing for this long is a hang.
stall_seconds="${CMUX_SWIFT_TEST_STALL_SECONDS:-180}"
if ! [[ "$stall_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_STALL_SECONDS must be a positive integer" >&2
  exit 2
fi
# Suites run in parallel, still one process per suite (process-global state
# stays inside one suite). 1 restores the serial run. The processes share one
# .build: SwiftPM's scratch-directory lock would make every `swift test` wait for
# the one before it (measured 2026-10-08: three 8 s suites took 27 s, 9 s with
# --ignore-lock), so parallel runs pass --ignore-lock. --skip-build writes no
# build output; the only shared write is the .build/debug symlink, which a
# losing process reports as a warning.
suite_jobs="${CMUX_SWIFT_TEST_SUITE_JOBS:-8}"
if ! [[ "$suite_jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_SUITE_JOBS must be a positive integer" >&2
  exit 2
fi
lock_args=()
[ "$suite_jobs" -eq 1 ] || lock_args=(--ignore-lock)
# CMUX_SWIFT_TEST_DIRECT=1 runs each suite from the built test bundle the way
# `swift test` runs it (run_swift_test_bundle.py), without a SwiftPM process per
# suite: that process cost 1-2 s of startup per suite and opened .build/build.db,
# where 8 parallel suites hit "database is locked". Fleet 2026-10-09
# (CmuxNext at 2914cce3af0e, 1339 suites): the same suites passed both ways and
# the summed suite time halved. 0 keeps one `swift test --skip-build --filter`
# per suite (fallback until 2026-10-16).
direct="${CMUX_SWIFT_TEST_DIRECT:-1}"
if [ "$direct" != 0 ] && [ "$direct" != 1 ]; then
  echo "CMUX_SWIFT_TEST_DIRECT must be 0 or 1 (got '$direct')" >&2
  exit 2
fi
# CMUX_SWIFT_TEST_SHARD=i/n (1-based) splits one package's suites across n
# fleet steps: each shard builds, then runs every n-th suite of the sorted list,
# starting at the i-th. Round-robin over a sorted list is deterministic and keeps
# shard sizes within one suite of each other.
shard_index=1 shard_count=1
if [ -n "${CMUX_SWIFT_TEST_SHARD:-}" ]; then
  if ! [[ "$CMUX_SWIFT_TEST_SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] \
    || [ "${BASH_REMATCH[1]}" -gt "${BASH_REMATCH[2]}" ]; then
    echo "CMUX_SWIFT_TEST_SHARD must be i/n with 1 <= i <= n (got '$CMUX_SWIFT_TEST_SHARD')" >&2
    exit 2
  fi
  shard_index="${BASH_REMATCH[1]}" shard_count="${BASH_REMATCH[2]}"
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evidence_dir="$(mktemp -d)"
trap 'rm -rf "$evidence_dir"' EXIT
# The cmux-next web bundles are build output (cx-vn5) that the package reads at
# test time: without them AgentPaneView.init returns nil and the pane suites crash.
case "$(cd "$package_path" && pwd -P)" in
  */Packages/macOS/CmuxNext)
    (cd "$script_dir/../.." && "${CMUX_ENSURE_WEB_BUNDLES:-scripts/ci/ensure-web-bundles.sh}")
    # The live-daemon suites find this tree's hosted cmux-tui through
    # `pin-cmux-tui.sh path` (about 60 git processes, 7-10 s) and fetch a
    # missing build (20-50 s for an unpublished tree), once in every suite
    # process. Resolve and fetch once for the run, in the background while
    # the suites are listed; the tests read CMUX_NEXT_TUI_TREE_PATH and
    # never fetch again. They never wait for an unpublished tree.
    if [ -z "${CMUX_NEXT_TUI_TREE_PATH:-}" ]; then
      (
        cd "$script_dir/../.." || exit 0
        export CMUX_TUI_TREE_WAIT_SECONDS="${CMUX_TUI_TREE_WAIT_SECONDS:-0}"
        tree_path="$(bash scripts/cmux-next/pin-cmux-tui.sh path 2>/dev/null)" || exit 0
        if [ -n "$tree_path" ] && [ ! -x "$tree_path" ]; then
          bash scripts/cmux-next/pin-cmux-tui.sh fetch >&2 \
            || echo "pin-cmux-tui.sh fetch failed; the live-daemon suites will skip." >&2
        fi
        printf '%s' "$tree_path" > "$evidence_dir/tui-tree-path"
      ) &
      tree_path_job=$!
    fi
    ;;
esac
# Keep process-global test state inside one suite. Some packages otherwise
# finish every assertion but leave the aggregate Swift Testing runner waiting.
swift test list --package-path "$package_path" > "$evidence_dir/discovered-tests.txt"
python3 "$script_dir/require_swift_test_execution.py" \
  --list-filters "$evidence_dir/discovered-tests.txt" > "$evidence_dir/filters.txt"
# swift build copies String Catalogs into the resource bundles uncompiled; without
# the compiled <lang>.lproj tables, localization suites fail (cmux-next.yml and
# package-test-lane.sh run the same step after their build).
if [ -n "$(find "$package_path/Sources" -name '*.xcstrings' -print -quit 2>/dev/null)" ]; then
  compile_catalogs="${CMUX_COMPILE_STRING_CATALOGS:-$script_dir/../cmux-next/compile-string-catalogs.sh}"
  (cd "$package_path" && "$compile_catalogs")
fi
if [ -n "${tree_path_job:-}" ]; then
  wait "$tree_path_job" || true
  tree_path="$(cat "$evidence_dir/tui-tree-path" 2>/dev/null || true)"
  [ -z "$tree_path" ] || export CMUX_NEXT_TUI_TREE_PATH="$tree_path"
fi
if [ "$direct" -eq 1 ]; then
  # Everything the suites need from SwiftPM and the toolchain, resolved once:
  # which listed tests are XCTest (the rest are Swift Testing), the test
  # bundle, and the two runners with the platform paths SwiftPM sets.
  swift test list --package-path "$package_path" --skip-build --disable-swift-testing \
    > "$evidence_dir/xctest-tests.txt"
  bin_path="$(swift build --package-path "$package_path" --show-bin-path)"
  bundles=()
  for candidate in "$bin_path"/*.xctest; do
    [ -d "$candidate" ] && bundles+=("$candidate")
  done
  if [ "${#bundles[@]}" -ne 1 ]; then
    echo "error: expected one .xctest bundle in $bin_path, found ${#bundles[@]}; no .xctest bundle to run directly (set CMUX_SWIFT_TEST_DIRECT=0 to use swift test)." >&2
    exit 1
  fi
  test_bundle="${bundles[0]}"
  xctest_tool="$(xcrun --find xctest)"
  testing_helper="$(dirname "$(xcrun --find swift-test)")/../libexec/swift/pm/swiftpm-testing-helper"
  platform_path="$(xcrun --sdk macosx --show-sdk-platform-path)"
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  for tool in "$xctest_tool" "$testing_helper"; do
    if [ ! -x "$tool" ]; then
      echo "error: $tool is not executable; cannot run suites directly (set CMUX_SWIFT_TEST_DIRECT=0 to use swift test)." >&2
      exit 1
    fi
  done
  package_dir="$(cd "$package_path" && pwd -P)"
  echo "Running suites directly from $test_bundle (CMUX_SWIFT_TEST_DIRECT=1)."
fi

# Run every suite, so one early failure or hang does not hide the rest, then
# list each suite's result and exit with the first failure's status (first in
# suite order, whatever order the suites finish in).
suites=()
position=0
while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  if [ $((position % shard_count + 1)) -eq "$shard_index" ]; then
    suites+=("$suite")
  fi
  position=$((position + 1))
done < <(if [ "$shard_count" -eq 1 ]; then cat "$evidence_dir/filters.txt"; else LC_ALL=C sort -u "$evidence_dir/filters.txt"; fi)
suite_count=${#suites[@]}
if [ -n "${CMUX_SWIFT_TEST_SHARD:-}" ]; then
  echo "Swift test shard $shard_index/$shard_count: $suite_count of $position suites"
fi

# attempt_suite SUITE EXECUTION_LOG SINK...: one watchdog-guarded swift test of
# SUITE. The output replaces EXECUTION_LOG (the --log check reads the last
# attempt) and goes through the SINK command (the suite log, and the console
# when suites run one at a time). Exits with the watchdog's status.
attempt_suite() {
  local suite="$1" execution="$2"
  shift 2
  # stdin from /dev/null keeps the child off the caller's input; 3>&- keeps the
  # scheduler's completion pipe out of the test processes. On a stall the
  # watchdog names the tests still running, samples them, and also kills
  # swiftpm-testing-helper, which runs in its own process group.
  local command
  if [ "$direct" -eq 1 ]; then
    command=(python3 "$script_dir/run_swift_test_bundle.py"
      --bundle "$test_bundle" --xctest "$xctest_tool" --helper "$testing_helper"
      --platform "$platform_path" --sdk "$sdk_path" --cwd "$package_dir"
      --tests "$evidence_dir/discovered-tests.txt" --xctest-tests "$evidence_dir/xctest-tests.txt"
      --filter "$suite")
  else
    command=(swift test --package-path "$package_path" --skip-build
      ${lock_args[@]+"${lock_args[@]}"} --filter "$suite")
  fi
  python3 "$script_dir/hung_test_watchdog.py" \
    --timeout-seconds "$suite_timeout_seconds" --stall-seconds "$stall_seconds" \
    --label "$suite" \
    -- "${command[@]}" \
    < /dev/null 3>&- 2>&1 | tee "$execution" | "$@"
}

# run_suite INDEX SINK...: run suite INDEX with one retry on a timeout, then the
# execution check, and write its status to suite-INDEX.status. Always returns 0.
run_suite() {
  local index="$1"
  shift
  local suite="${suites[$index]}"
  local execution="$evidence_dir/suite-$index.execution.log"
  local suite_status=0 started=$SECONDS
  attempt_suite "$suite" "$execution" "$@" || suite_status=$?
  # --ignore-lock skips the scratch lock, but `swift test --skip-build` still
  # opens .build/build.db (SQLite); when another suite's process holds it,
  # SwiftPM gives up before any test runs ("database is locked", then "no tests
  # found"). That is contention, not a result: try again, at most 3 times.
  local locked_retries=0
  while [ "$suite_status" -ne 0 ] && [ "$locked_retries" -lt 3 ] \
    && grep -Fq 'unable to attach DB' "$execution" && grep -Fq 'database is locked' "$execution"; do
    locked_retries=$((locked_retries + 1))
    echo "SwiftPM build database was locked by another suite; retrying $suite ($locked_retries/3)." | "$@"
    suite_status=0
    attempt_suite "$suite" "$execution" "$@" || suite_status=$?
  done
  if [ "$suite_status" -eq 124 ]; then
    echo "Swift test suite timed out; retrying $suite once." | "$@"
    suite_status=0
    attempt_suite "$suite" "$execution" "$@" || suite_status=$?
  fi
  if [ "$suite_status" -eq 0 ]; then
    python3 "$script_dir/require_swift_test_execution.py" --log "$execution" 2>&1 | "$@" \
      || suite_status=$?
  fi
  echo "$((SECONDS - started))" > "$evidence_dir/suite-$index.seconds"
  echo "$suite_status" > "$evidence_dir/suite-$index.status"
}

if [ "$suite_jobs" -eq 1 ]; then
  # One at a time: stream each suite's output as it runs.
  for ((index = 0; index < suite_count; index++)); do
    echo "swift test $package_path --skip-build --filter ${suites[$index]}"
    run_suite "$index" cat
  done
else
  echo "Running $suite_count Swift test suites, $suite_jobs at a time; each suite's output prints when it finishes."
  # Each finished suite writes its index to this pipe; the scheduler reads it,
  # prints that suite's whole log under its header, and starts the next suite.
  # Opened read-write so neither side blocks on open (bash 3.2 has no wait -n).
  mkfifo "$evidence_dir/finished"
  exec 3<>"$evidence_dir/finished"
  next=0 running=0 done_count=0
  while [ "$done_count" -lt "$suite_count" ]; do
    while [ "$running" -lt "$suite_jobs" ] && [ "$next" -lt "$suite_count" ]; do
      (
        run_suite "$next" tee -a "$evidence_dir/suite-$next.log" > /dev/null \
          || echo 1 > "$evidence_dir/suite-$next.status"
        echo "$next" >&3
      ) &
      next=$((next + 1))
      running=$((running + 1))
    done
    IFS= read -r finished <&3
    running=$((running - 1))
    done_count=$((done_count + 1))
    finished_status="$(cat "$evidence_dir/suite-$finished.status" 2>/dev/null || echo 1)"
    finished_seconds="$(cat "$evidence_dir/suite-$finished.seconds" 2>/dev/null || echo '?')"
    echo "swift test $package_path --skip-build --filter ${suites[$finished]}" \
      "($done_count/$suite_count, exit $finished_status, ${finished_seconds}s)"
    cat "$evidence_dir/suite-$finished.log" 2>/dev/null || true
  done
  wait
  exec 3>&-
fi

first_failure=0
results=()
for ((index = 0; index < suite_count; index++)); do
  suite="${suites[$index]}"
  suite_status="$(cat "$evidence_dir/suite-$index.status" 2>/dev/null || echo 1)"
  if [ "$suite_status" -eq 0 ]; then
    results+=("PASS $suite")
  else
    [ "$first_failure" -ne 0 ] || first_failure="$suite_status"
    if [ "$suite_status" -eq 124 ]; then
      results+=("FAIL (timed out) $suite")
    else
      results+=("FAIL (exit $suite_status) $suite")
    fi
  fi
done

failed=0
for result in ${results[@]+"${results[@]}"}; do
  [[ "$result" == PASS* ]] || failed=$((failed + 1))
done
echo "Swift test suites: $(( ${#results[@]} - failed )) passed, $failed failed"
for result in ${results[@]+"${results[@]}"}; do
  echo "  $result"
done
exit "$first_failure"
