#!/usr/bin/env bash
# Runs `swift test` with the given arguments. If it is still running after
# CMUX_NEXT_TEST_HANG_SECONDS (default 1200), samples the test processes so the
# log shows where they are stuck, kills them, and fails. Run from
# Packages/macOS/CmuxNext.
#
# After the run it names every red Swift Testing test in one ::error line and
# in the step summary, so a red stays visible when a log viewer truncates the
# step's output. A run that printed Swift Testing output but no "Test run
# with" summary line fails and names the tests that started and never
# finished (a crashed or killed test process).
set -uo pipefail
limit="${CMUX_NEXT_TEST_HANG_SECONDS:-1200}"
log="$(mktemp "${TMPDIR:-/tmp}/swift-test-log.XXXXXX")"
trap 'rm -f "$log"' EXIT
exec 3> >(tee "$log")
tee_pid=$!
swift test "$@" >&3 2>&1 &
test_pid=$!
# Only this run's processes: on a shared CI Mac other jobs run xctest and
# swiftpm-testing-helper as the same user.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}
(
  exec 3>&-
  # Killing the watcher also ends its sleep, so no orphan holds stdout open.
  sleep "$limit" &
  sleeper=$!
  trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
  wait "$sleeper"
  echo "::error title=cmux-next swift test hang::swift test still running after ${limit}s; sampling the test processes"
  tree="$(descendants "$test_pid")"
  for p in $tree; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in
      *xctest|*swiftpm-testing-helper)
        echo "=== sample $p"
        sample "$p" 5 -mayDie 2>&1 | head -n 800 ;;
    esac
  done
  for p in $tree; do
    kill "$p" 2>/dev/null
  done
  kill "$test_pid"
) &
watcher=$!
wait "$test_pid"
status=$?
exec 3>&-
# bash 3.2 cannot wait for a process substitution; tee then ends on its own.
wait "$tee_pid" 2>/dev/null || true

# Prints the ::error lines and the step summary for the run's log. Exits 3
# when Swift Testing output has no "Test run with" summary line.
report() {
  awk -v summary_file="${GITHUB_STEP_SUMMARY:-}" '
    function name_of(line) {
      sub(/^[^ ]+ Test /, "", line)
      sub(/ (started\.|recorded an issue at .*|passed after .*|with [0-9]+ test cases? passed after .*|failed after .*|skipped.*)$/, "", line)
      return line
    }
    function join(list, count,    out, i, max) {
      max = count > 100 ? 100 : count
      for (i = 1; i <= max; i++) out = out (i > 1 ? "; " : "") list[i]
      if (count > max) out = out "; and " (count - max) " more"
      return out
    }
    /^✘ Test .* recorded an issue at / {
      name = name_of($0)
      if (!(name in red)) {
        at = $0; sub(/.* recorded an issue at /, "", at); sub(/:[0-9]+: .*$/, "", at)
        red[name] = 1; reds[++red_count] = name " " at
      }
    }
    /^◇ Test .* started\.$/ && !/^◇ Test case passing / {
      name = name_of($0)
      if (!(name in started)) { started[name] = 1; starts[++start_count] = name }
    }
    /^✔ Test / || /^✘ Test .* failed after / || /^➜ Test / { finished[name_of($0)] = 1 }
    /^[^ ]+ Test run with [0-9]+ tests? / { has_summary = 1 }
    END {
      if (red_count > 0) {
        printf "::error title=cmux-next swift test reds::%d red tests: %s\n", red_count, join(reds, red_count)
        if (summary_file != "") {
          printf "### %d red Swift tests\n\n", red_count >> summary_file
          for (i = 1; i <= red_count; i++) printf "- `%s`\n", reds[i] >> summary_file
        }
      }
      if (start_count > 0 && !has_summary) {
        for (i = 1; i <= start_count; i++) if (!(starts[i] in finished)) open_tests[++open_count] = starts[i]
        printf "::error title=cmux-next swift test ended early::no \"Test run with\" summary line (crash, kill or truncation); %d tests started and never finished: %s\n", open_count, join(open_tests, open_count)
        if (summary_file != "") {
          printf "### No Swift Testing summary line: %d unfinished tests\n\n", open_count >> summary_file
          for (i = 1; i <= open_count; i++) printf "- `%s`\n", open_tests[i] >> summary_file
        }
        exit 3
      }
    }
  ' "$log"
}
report
report_status=$?

if kill -0 "$watcher" 2>/dev/null; then
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  # A missing summary line fails the run even when swift test exited 0.
  if (( report_status == 3 && status == 0 )); then exit 1; fi
  exit "$status"
fi
# The watcher fired: always fail, whatever status the killed run reported.
exit $(( status == 0 ? 1 : status ))
