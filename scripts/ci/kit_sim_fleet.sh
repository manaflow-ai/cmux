#!/usr/bin/env bash
# cmux-next-ios-kit.yml's simulator test build on the build fleet: the kit job's wait for it, and the pool run.
#
#   kit_sim_fleet.sh wait   kit-tests: is the kit-sim-fleet job's build ready? Writes hit=true|false and, on a hit,
#                           products=<artifact name> to $GITHUB_OUTPUT. The pool reads that artifact by name; nothing
#                           is downloaded or uploaded again. Never fails: no build means the Mac builds it (fallback).
#                           env: RUN (repos/O/R/actions/runs/ID), ATTEMPT, JOB (the job's name), ARTIFACT,
#                           BOUND (seconds, default 420), POLL (seconds between reads, default 15).
#   kit_sim_fleet.sh pool   One fleet pool run of the kit's simulator tests on PRODUCTS (RUN_ID/ARTIFACT), with the
#                           Mac simulator step's skips. Writes verdict=pass|fail|none, cases= and seconds= to
#                           $GITHUB_OUTPUT and the job summary. Exits 0 whatever the run did: the caller acts on the
#                           verdict. env: CONTROLLER, HEAD_SHA, PRODUCTS, LABEL (the summary's heading); CI_CLIENT
#                           (a ci-client.py to use instead of the controller's) is for tests.
#   kit_sim_fleet.sh reach  Can this runner reach the controller? Writes reach=yes|no. Two tries of
#                           REACH_TIMEOUT (default 5) s; the controller answers in milliseconds from the tailnet.
#                           `cmux-linux` is also served by GCP pool runners (cmux-runner-pool-s1a-*) that are not on
#                           the tailnet, so a submit from there timed out and read as no verdict (run 45912028627).
#                           A no is where the caller hands the submit to an owned Mac, never a verdict about the
#                           controller (cmuxterm-hq docs/handbook/unreachable-from-here-read-as-down.md).
#                           env: CONTROLLER.
#   kit_sim_fleet.sh supply Does the Linux simsdk pool, which runs the pool's tests, have runners? Writes live=yes|no
#                           from the controller's /v1/capabilities "simsdk" (cmuxterm-hq ci_step_simsdk_supply.go: false
#                           for 30 min after a simsdk run got no runner, and the controller then refuses a simsdk step).
#                           A no skips the Mac's pack and 813 MB upload (437 s in run 45996304968, for a pool run that
#                           ended "got no runner"); the Mac's own simulator tests run as always. Fails open: no answer,
#                           or no "simsdk" in it (an older controller), is yes. env: CONTROLLER, REACH_TIMEOUT.
#
# Every command whose exit is read runs as `cmd || rc=$?`: a workflow step is `bash -e`, so a bare failing command
# would end the step before its status is read (review of cmux#59111).
set -uo pipefail

out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }
summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# A read of the GitHub API, retried once after a failure; fails only when both tries did.
read_api() {
  local answer
  if answer="$(gh api "$@" 2>/dev/null)"; then printf '%s' "$answer"; return 0; fi
  sleep "${RETRY_SLEEP:-3}"
  gh api "$@" 2>/dev/null
}

fallback() {
  echo "no simulator test build from the build fleet ($1); Mac fallback"
  out "hit=false"
  exit 0
}

wait_for_build() {
  local bound="${BOUND:-420}" poll="${POLL:-15}" id state
  local deadline=$((SECONDS + bound)) last_look=0
  while :; do
    id="$(read_api "$RUN/artifacts?name=$ARTIFACT" --jq '[.artifacts[] | select(.expired | not)][0].id // empty')" \
      || fallback "the artifacts read failed twice"
    if [[ -n "$id" ]]; then
      echo "the build fleet's simulator test build is $ARTIFACT (artifact $id) after $SECONDS s; this Mac builds none"
      out "hit=true"
      out "products=$ARTIFACT"
      exit 0
    fi
    (( last_look )) && fallback "$JOB: $state, and no $ARTIFACT"
    state="$(read_api "$RUN/attempts/$ATTEMPT/jobs?per_page=100" --jq "[.jobs[] | select(.name == \"$JOB\")][0] | if . == null then \"absent\" elif .status == \"completed\" then .conclusion else .status end")" \
      || fallback "the jobs read failed twice"
    case "$state" in
      # Still coming: a job waiting for a runner or still building. Waited on up to the bound.
      queued|waiting|pending|requested|in_progress|absent) ;;
      # Ended. Its upload is listed before the job completes, but look once more for one that landed in between.
      *) last_look=1; continue ;;
    esac
    (( SECONDS >= deadline )) && fallback "none within $bound s; $JOB: $state"
    sleep "$poll"
  done
}

pool_run() {
  local dir="${RUNNER_TEMP:-/tmp}/sim-linux" client="${CI_CLIENT:-}" rc=0 step="" cases=0 verdict reason start seconds
  mkdir -p "$dir"
  if [[ -z "$client" ]]; then
    [[ -n "${CONTROLLER:-}" ]] || { verdict_out none 0 0 "no CMUX_FLEET_CONTROLLER variable"; return 0; }
    local root="${RUNNER_TEMP:-/tmp}/fleet-client" try
    mkdir -p "$root"
    for try in 1 2 3; do
      curl -fsS -m 30 "$CONTROLLER/v1/client/manifest" -o "$root/manifest.json" && break
      [[ $try == 3 ]] && { verdict_out none 0 0 "the controller did not answer from ${RUNNER_NAME:-this runner}"; return 0; }
      sleep 20
    done
    python3 - "$root" "$CONTROLLER" <<'PY' || { verdict_out none 0 0 "the fleet client did not download"; return 0; }
import hashlib, json, sys, urllib.request
from pathlib import Path
root, controller = Path(sys.argv[1]), sys.argv[2]
for name, digest in json.loads((root / "manifest.json").read_text())["files"].items():
    if "/" in name or name.startswith("."):
        raise SystemExit(f"bad client file name {name!r}")
    data = urllib.request.urlopen(f"{controller}/v1/client/files/{name}", timeout=30).read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"{name}: sha256 mismatch")
    (root / name).write_bytes(data)
PY
    client="$root/ci-client.py"
  fi
  export CMUX_CI_CONTROLLER="${CONTROLLER:-}"
  start=$(date +%s)
  # The pool's share of the bundles (scripts/ci/ios_sim_bundles.py: the Mac step's skips, and with "on" the bundles
  # that stay on the Mac). Exit 3: every bundle stays on the Mac, so there is no pool run and no verdict.
  local skips=() brc=0
  python3 -I "$(dirname "${BASH_SOURCE[0]}")/ios_sim_bundles.py" pool > "$dir/skips" || brc=$?
  mapfile -t skips < "$dir/skips"
  if [[ "$brc" == 3 ]]; then verdict_out none 0 0 "every simulator test bundle stays on the Mac"; return 0; fi
  [[ "$brc" == 0 ]] || { verdict_out none 0 0 "ios_sim_bundles.py failed (exit $brc)"; return 0; }
  python3 "$client" run --class simulator --os linux --script scripts/ci/ios-sim-linux-test.sh \
    --ref "$HEAD_SHA" --repo manaflow-ai/cmux --env "CMUX_IOS_PRODUCTS=$PRODUCTS" \
    --arg suite=kit "${skips[@]}" --arg timeout=1800 \
    --artifact artifacts/ios-sim-linux/result.tgz --timeout 2400 --queue-timeout 900 > "$dir/step.log" 2>&1 || rc=$?
  seconds=$(( $(date +%s) - start ))
  step="$(grep -o -E 'step [0-9a-f]{24}' "$dir/step.log" | head -1 | cut -d' ' -f2 || true)"
  if [[ -n "$step" ]]; then
    python3 "$client" artifact "$step" "$dir/result.tgz" \
      || python3 "$client" artifact --failed "$step" "$dir/result.tgz" || true
  fi
  if [[ -s "$dir/result.tgz" ]]; then
    mkdir -p "$dir/result"
    tar -xzf "$dir/result.tgz" -C "$dir/result" 2>/dev/null || true
  fi
  if [[ -f "$dir/result/summary.txt" ]]; then
    cat "$dir/result/summary.txt"
    grep -E -A400 '<failure|<error' "$dir/result/junit.xml" 2>/dev/null | head -80 || true
  else
    tail -n 40 "$dir/step.log" || true
  fi
  cases="$(grep -c '<testcase' "$dir/result/junit.xml" 2>/dev/null || true)"
  cases="${cases:-0}"
  if [[ "$rc" == 0 && "$cases" -gt 0 ]]; then verdict=pass; reason="step ${step:-?} passed $cases tests"
  elif [[ "$rc" == 1 && "$cases" -gt 0 ]]; then verdict=fail; reason="step ${step:-?} ran $cases tests and some failed"
  else verdict=none; reason="step ${step:-none} gave no verdict (exit $rc, $cases test cases)"; fi
  verdict_out "$verdict" "$cases" "$seconds" "$reason"
}

verdict_out() {
  echo "${LABEL:-fleet pool}: $1 in $3 s: $4"
  summary "### iOS simulator tests, ${LABEL:-fleet pool}: $1" "$4; submit to result $3 s"
  out "verdict=$1"; out "cases=$2"; out "seconds=$3"
}

reach() {
  local here="${RUNNER_NAME:-this runner}" try
  [[ -n "${CONTROLLER:-}" ]] || { echo "no CMUX_FLEET_CONTROLLER variable"; out "reach=no"; return 0; }
  for try in 1 2; do
    if curl -fsS -m "${REACH_TIMEOUT:-5}" -o /dev/null "$CONTROLLER/v1/client/manifest" 2>/dev/null; then
      echo "the controller answers from $here"
      out "reach=yes"
      return 0
    fi
    [[ $try == 1 ]] && sleep "${RETRY_SLEEP:-2}"
  done
  echo "::notice title=fleet pool::no route to the controller from $here (not a tailnet peer); an owned Mac submits the pool run"
  summary "### Fleet pool submit: no route from $here" "Not a tailnet peer; the owned-Mac job submits instead. Not a verdict about the controller."
  out "reach=no"
}

supply() {
  local caps live
  [[ -n "${CONTROLLER:-}" ]] || { echo "no CMUX_FLEET_CONTROLLER variable; packing as before"; out "live=yes"; return 0; }
  caps="$(curl -fsS -m "${REACH_TIMEOUT:-5}" "$CONTROLLER/v1/capabilities" 2>/dev/null)" \
    || { echo "no answer from the controller's capabilities; packing as before"; out "live=yes"; return 0; }
  live="$(printf '%s' "$caps" | python3 -c 'import json,sys
try: v = json.load(sys.stdin).get("simsdk")
except Exception: v = None
print("no" if v is False else "yes")' 2>/dev/null)" || live=yes
  if [[ "$live" == no ]]; then
    echo "::notice title=fleet pool::the Linux simsdk pool has no runners (the controller's capabilities: simsdk false); no pack, no upload, no pool run; the Mac's simulator step runs the tests"
    summary "### iOS simulator tests, fleet pool: skipped" "The Linux simsdk pool has no runners (controller capabilities simsdk=false). The Mac's own simulator step runs them."
    out "live=no"
    return 0
  fi
  echo "the Linux simsdk pool is live (or the controller did not say otherwise)"
  out "live=yes"
}

case "${1:-}" in
  supply) supply ;;
  wait) wait_for_build ;;
  pool) pool_run ;;
  reach) reach ;;
  *) echo "usage: $0 wait|pool|reach|supply" >&2; exit 2 ;;
esac
