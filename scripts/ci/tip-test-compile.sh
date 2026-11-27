#!/usr/bin/env bash
# Compile, without running, the Swift test targets a feat-cmux-next push can
# break, on a fleet Mac in the controller's background class
# (.github/workflows/cmux-next-tip-test-compile.yml).
#
# 2026-10-21: 134f90c0596 and c515787a8b4 went straight to feat-cmux-next, each
# fine alone; together CmuxNextAgentPaneTests stopped compiling, and every
# agent's fleet test run was red until someone noticed. The only test compile
# was the advisory pull-request check (fleet-test-compile.yml), which a direct
# push never runs.
#
# It submits `package-test-lane.sh compile-tests BASE` with `cmux-ci run
# --background` (after every urgent, manual and agent job), then watches the
# step while it waits in the queue:
#   - a newer push's run of this workflow waiting behind this one (the
#     workflow's concurrency group holds it pending): this queued step answers
#     a question nobody asks any more, so it is cancelled (verdict superseded;
#     the newer run compiles from the last verified commit, so nothing goes
#     unchecked);
#   - still queued after TIP_QUEUE_LIMIT_SECONDS: cancelled (verdict none), so
#     the gateway runner it holds goes back to required compiles.
# A step that has started is never cancelled here.
#
# Env: REF, BASE (full shas), RUN_ID, GITHUB_REPOSITORY, WORKFLOW_FILE,
# GITHUB_TOKEN; CMUX_CI_CLIENT (default ~/.local/bin/cmux-ci);
# TIP_QUEUE_LIMIT_SECONDS (2700), TIP_POLL_SECONDS (30), TIP_STEP_TIMEOUT
# (2400); TIP_GH_API (a command taking an API path and printing its JSON;
# default curl with GITHUB_TOKEN; tests pass a fake). OUT_DIR (RUNNER_TEMP):
# writes verdict (pass, fail, superseded or none), report.md and the step log.
# Exit 0 except for fail (1): no verdict is never red.
set -uo pipefail

: "${REF:?}" "${BASE:?}" "${RUN_ID:?}" "${GITHUB_REPOSITORY:?}" "${WORKFLOW_FILE:?}"
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
queue_limit="${TIP_QUEUE_LIMIT_SECONDS:-2700}"
poll="${TIP_POLL_SECONDS:-30}"
step_timeout="${TIP_STEP_TIMEOUT:-2400}"
out="${OUT_DIR:-${RUNNER_TEMP:-/tmp}}"
log="$out/tip-test-compile.log"
marker='compile-tests: a test target did not compile'
mkdir -p "$out"
: > "$out/report.md"

gh_api() {
  if [ -n "${TIP_GH_API:-}" ]; then
    $TIP_GH_API "$1"
  else
    curl -fsS -m 20 -H "Authorization: Bearer ${GITHUB_TOKEN:?}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/$1"
  fi
}

finish() {
  echo "$1" > "$out/verdict"
  echo "verdict: $1"
  [ "$1" = fail ] && exit 1
  exit 0
}

if ! [ -x "$client" ]; then
  echo "::warning title=tip test-compile::$client is not installed on runner ${RUNNER_NAME:-?}; no verdict."
  finish none
fi

"$client" run --background --class light --script scripts/ci/package-test-lane.sh --ref "$REF" \
  --arg=compile-tests --arg="$BASE" --timeout "$step_timeout" > "$log" 2>&1 &
pid=$!
started=$SECONDS
step=""
why=""
while kill -0 "$pid" 2>/dev/null; do
  sleep "$poll"
  [ -n "$step" ] || step="$(sed -n 's/^cmux-ci: step \([0-9a-f]\{6,64\}\) .*/\1/p' "$log" | head -n 1)"
  [ -n "$step" ] || continue
  state="$("$client" status "$step" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
  [ "$state" = queued ] || continue
  # A newer run of this workflow waiting behind this one (pending in the concurrency group).
  newer="$(gh_api "repos/$GITHUB_REPOSITORY/actions/workflows/$WORKFLOW_FILE/runs?branch=feat-cmux-next&event=push&per_page=20" 2>/dev/null |
    RUN_ID="$RUN_ID" python3 -c '
import json, os, sys
runs = json.load(sys.stdin).get("workflow_runs", [])
me = int(os.environ["RUN_ID"])
print(next((r["head_sha"] for r in runs if r["id"] > me and r["status"] in ("pending", "queued", "waiting", "requested")), ""))' 2>/dev/null)"
  if [ -n "$newer" ]; then
    why="superseded"
    echo "tip test-compile: a newer push ($newer) waits behind this run; cancelling queued step $step"
  elif [ $((SECONDS - started)) -ge "$queue_limit" ]; then
    why="none"
    echo "::warning title=tip test-compile::step $step still queued after ${queue_limit}s (the fleet is busy); cancelled, no verdict. The next push compiles from the last verified commit."
  else
    continue
  fi
  "$client" cancel "$step" > /dev/null 2>&1 || true
  break
done
wait "$pid"
status=$?
cat "$log"
[ -z "$why" ] || finish "$why"

errors() {
  grep -E '^/.*\.swift:[0-9]+:[0-9]+: error:' "$log" | sed -E 's|^.*/(Packages/)|\1|' | sort -u | head -n 30
}
if grep -q "$marker" "$log"; then
  {
    echo "Test targets that did not compile at \`$REF\` (changes since \`$BASE\`):"
    echo
    echo '```'
    grep -E '^[A-Za-z0-9_]+ +[^ ]+ +FAILED' "$log" || true
    echo '```'
    echo
    echo 'First errors:'
    echo
    echo '```'
    errors
    echo '```'
  } > "$out/report.md"
  echo "::error title=tip test-compile::A Swift test target does not compile at $REF (see the errors above)."
  finish fail
fi
[ "$status" -eq 0 ] && finish pass
echo "::warning title=tip test-compile::No verdict (exit $status)."
finish none
