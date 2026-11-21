#!/usr/bin/env bash
# cmux-next.yml package-tests-fleet: run the lane's package tests for a feat-cmux-next pull
# request on the build fleet, and judge the step.
#
# Usage: next-package-tests-fleet.sh REF PACKAGES
#
#   REF       the full sha the run tests (the pull request's merge commit).
#   PACKAGES  the packages path_route selected (package-test-lane.sh select), space separated;
#             only for the summary: the fleet step selects again from the same diff
#             (package-test-lane.sh run), so the step and the route cannot disagree.
#
# ci.yml's macos job skips every feat-cmux-next pull request (static-preflight's next-line
# split), so this job is the only check that runs a changed package's `swift test` there.
# The step takes the light class, as the fast tier's package suites do. The verdict comes
# from the controller's record of the step, which must name REF: a pass is a step done at REF
# with exit 0 and a client that exited 0; a nonzero step exit is a fail; anything else (no
# client, no worker, a queue or run timeout, another commit) is no verdict, never a pass.
# Exit 0 only for a pass.
#
# CMUX_CI_CLIENT overrides the client path (tests/test_cmux_next_changed_package_tests.py).
set -uo pipefail

ref="${1:-}"
packages="${2:-}"
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/package-tests-fleet.log"

finish() {
  local verdict="$1" why="$2"
  echo "$why"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### cmux-next package tests on the build fleet: %s\n\nPackages: %s\n\n%s\n' \
      "$verdict" "${packages:-none}" "$why" >> "$GITHUB_STEP_SUMMARY"
  fi
  case "$verdict" in
    pass) exit 0 ;;
    fail) echo "::error title=Package tests on the build fleet::$why"; exit 1 ;;
    *) echo "::error title=Package tests on the build fleet: no verdict::$why"; exit 1 ;;
  esac
}

[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || finish unavailable "the commit to test is not a full sha ('$ref')"
[ -x "$client" ] || finish unavailable "$client is not installed on runner ${RUNNER_NAME:-unknown}"

status=0
"$client" run --class light --script scripts/ci/package-test-lane.sh --ref "$ref" \
  --arg=run --arg=--event=pull_request --no-supersede \
  --timeout 3000 --queue-timeout 1800 > "$log" 2>&1 || status=$?

id=""
echo "::group::package-test-lane.sh run on the build fleet"
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line"
  # The client names its step before the step's own log streams (6 to 64 hex).
  if [ -z "$id" ] && [[ "$line" =~ ^cmux-ci:\ step\ ([0-9a-f]{6,64})\  ]]; then id="${BASH_REMATCH[1]}"; fi
done < "$log"
echo "::endgroup::"

[ -n "$id" ] || finish unavailable "the client submitted no step (exit $status)"
json="$("$client" status "$id")" || finish unavailable "the controller's record of step $id could not be read"

# The step's own top-level fields, read with json (no first-match regex): ref, source_digest, state, exit_code.
fields="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    record = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(record, dict):
    sys.exit(1)
code = record.get("exit_code")
print("\x1f".join(str(record.get(key) or "") for key in ("ref", "source_digest", "state"))
      + "\x1f" + (str(code) if isinstance(code, int) and not isinstance(code, bool) else ""))
')" || finish unavailable "step $id's record is not a JSON object"
IFS=$'\x1f' read -r tested digest state code <<< "$fields"
[ -n "$tested" ] || finish unavailable "step $id's record names no tested commit"
[ "$tested" = "$ref" ] || finish unavailable "step $id tested $tested, not $ref"
if [ -n "$digest" ] && [ "$digest" != "$ref" ]; then
  finish unavailable "step $id checked out $digest, not $ref"
fi

if [ "$status" = 0 ] && [ "$state" = "done" ] && [ "$code" = 0 ]; then
  finish pass "every selected package passed at $ref (step $id)"
elif { [ "$state" = failed ] || [ "$state" = "done" ]; } && [[ "$code" =~ ^-?[0-9]+$ ]] && [ "$code" -ne 0 ]; then
  finish fail "a package test failed or did not build at $ref (step $id, exit $code); the errors are in its log above"
fi
finish unavailable "no verdict from step $id (client exit $status, step ${state:-unknown})"
