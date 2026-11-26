#!/usr/bin/env bash
# The Cloud journey in CI (backend.yml journey-* jobs, cmux-platform's deploys): TARGET is a
# cloud-journey.ts --backend name (preview-N, staging, prod). Runs it as the agent test account's own
# team, then as PRODUCT_TEAM when set (the never-pause path a product team takes), and writes each
# run's step table to the job summary. No agent test account in this environment (an empty pair: a missing or
# misnamed secret, as backend.yml journey-preview's CMUX_JOURNEY_DEV_STACK_* was, cmuxterm-hq#8702) is an
# error and exit 1, verdict not-run: a journey never skips silently. A baseline (below) still exits 0.
#
# Around a deploy (cmux-vm.yml; cloud-machine-channel-journey.yml for the Cloud machine
# channel): JOURNEY_PHASE=baseline before it (never fails the job), then
# JOURNEY_PHASE=after: exit 3 when a step that passed on the baseline fails now (the deploy's own red,
# which rolls the Worker back), 1 for a red that was already red before, 0 when green.
#
# A run that fails is run once more, about 15 s later, on a new machine, and the second run's steps
# are the ones judged: staging's VM API answers 502 vm_unavailable / 503 for a minute or two at a time
# (cmux-vm.yml runs 42598365007, 42595583910, 42576481526: the baseline green 90 s earlier, no step of the
# deploy's own), and each such blip rolled a good Worker back and left its deploy unproven. A real
# regression fails both runs and still rolls back. Two runs of about 70 s fit the 5 min the gate allows.
# The first run's failure stays in the summary and in a warning, so a flake is never silent.
#
# Every run but a baseline ends with one annotation titled "Cloud journey verdict", message
# `target=TARGET result=pass|red|regressed|not-run`: NOW's cloud_deploy_gate (cmuxterm-hq
# tools/fleet-reconcilers/now_cloud_deploy_gate.py) counts a deploy as proven only by a pass verdict in
# its run, because a step's own conclusion is green on "not run" and on an old red.
set -euo pipefail
: "${TARGET:?TARGET is a cloud-journey.ts --backend name}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${RUNNER_TEMP:-$(mktemp -d)}/cloud-journey"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
verdict() { # result
  [ "${JOURNEY_PHASE:-}" = baseline ] && return 0
  echo "::notice title=Cloud journey verdict::target=$TARGET result=$1"
  # The same verdict as step outputs, for cmux-vm.yml's journey-proof-<env> jobs (cloud-journey-proof-record.sh).
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "verdict=$1"; echo "verdict_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$GITHUB_OUTPUT"
  fi
}
if [ -z "${CMUX_DOGFOOD_STACK_EMAIL:-}" ] || [ -z "${CMUX_DOGFOOD_STACK_PASSWORD:-}" ]; then
  echo "::error title=Cloud journey cannot run::this job's environment holds no agent test account: CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD are empty (a missing or misnamed secret, or an environment that does not hold the pair)"
  printf 'Cloud journey on `%s` not run: no agent test account in this environment (a missing or misnamed secret).\n' "$TARGET" >> "$summary"
  verdict not-run
  # A baseline never fails its job; the run after the deploy fails on the same empty pair.
  [ "${JOURNEY_PHASE:-}" = baseline ] && exit 0
  exit 1
fi
phase="${JOURNEY_PHASE:-}"
status=0
regressed=0
# JOURNEY_RUST=1 (backend.yml journey-staging): the journey's core again on the shipped client,
# `cmux cloud journey` in CMUX_PATH (cmux-tui cli/cloud_journey.rs; cmuxterm-hq ARCHITECTURE-2026-11 M1b):
# create machine, running, first exec, model stub, pass Claude login, start agent, send chat, reply,
# delete. Its red is the job's red, retried once like the TS run. The rest of the journey (listed, pause
# and resume, carrier, later turns, daemon restart, clean room, gateway, GitHub) is still the TS script's.
# The summary ends with both drivers' times for the steps they share, from the same job and runner.
rust_run() { # label, ts dir, extra args...
  local label="$1" ts="$2"; shift 2
  local dir="$ts-rust"
  local args=(cloud journey --backend "$TARGET" --out "$dir")
  if [ "${JOURNEY_MODEL:-}" = stub ]; then args+=(--model-stub "$here/../../tests/fixtures/model-stub/model_stub.py"); fi
  if ! "$CMUX_PATH" "${args[@]}" "$@"; then
    { printf '### %s%s, Rust driver (first run, failed; run again)\n\n' "${phase:+$phase: }" "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
    echo "::warning title=Cloud journey retried::$TARGET ${phase:+$phase }$label (Rust driver) failed once; running it again"
    rm -rf "$dir.first" && mv "$dir" "$dir.first" && mkdir -p "$dir"
    sleep "${JOURNEY_RETRY_DELAY_S:-15}"
    if "$CMUX_PATH" "${args[@]}" "$@"; then :; else status=1; fi
  fi
  { printf '### %s%s, Rust driver (cmux cloud journey)\n\n' "${phase:+$phase: }" "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
  python3 -I - "$ts/journey.json" "$dir/journey.json" >> "$summary" 2>/dev/null <<'PY' || true
import json, sys
ts, rs = (json.load(open(p))["steps"] for p in sys.argv[1:3])
t = {s["step"]: s for s in ts}
rows, tt, rt = [], 0, 0
for s in rs:
    o = t.get(s["step"])
    if not o or s["status"] != "pass" or o["status"] != "pass" or s["step"] == "sign in (agent test account)":
        continue
    rows.append(f"| {s['step']} | {o['ms']} | {s['ms']} |")
    tt += o["ms"]; rt += s["ms"]
print("Driver times, the steps both passed (same job, same runner):\n\n| step | TS ms | Rust ms |\n|---|---:|---:|")
print("\n".join(rows)); print(f"| **total** | **{tt}** | **{rt}** |\n")
PY
}
run() { # label, extra args...
  local label="$1"; shift
  local dir="$out/${phase:+$phase-}$label"
  mkdir -p "$dir"
  local args=(--backend "$TARGET" --out "$dir")
  # The credentialed staging job supplies a Linux cmux-tui so the link path is exercised.
  # Keep the existing sync skip for app-less jobs, and let the caller select the model used
  # by the guest chat (the staging smoke uses the local model stub, never a real credential).
  if [ -n "${CMUX_PATH:-}" ]; then args+=(--cmux "$CMUX_PATH"); else args+=(--skip sync); fi
  if [ -n "${JOURNEY_MODEL:-}" ]; then args+=(--model "$JOURNEY_MODEL"); fi
  if ! bun "$here/cloud-journey.ts" "${args[@]}" "$@"; then
    { printf '### %s%s (first run, failed; run again)\n\n' "${phase:+$phase: }" "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
    echo "::warning title=Cloud journey retried::$TARGET ${phase:+$phase }$label failed once; running it again (first run's steps in the job summary)"
    rm -rf "$dir.first" && mv "$dir" "$dir.first" && mkdir -p "$dir"
    sleep "${JOURNEY_RETRY_DELAY_S:-15}"  # sleep-ok: backoff before the one retry
    if bun "$here/cloud-journey.ts" "${args[@]}" "$@"; then :; else status=1; fi
  fi
  { printf '### %s%s\n\n' "${phase:+$phase: }" "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
  # The send's Chrome trace (Perfetto), where journey-live uploads it: $RUNNER_TEMP/<target>/send-trace.json for the
  # test team's run, send-trace-<phase-label>.json for the others. Tracing never fails the journey.
  if [ -f "$dir/send-trace.json" ] && [ -n "${RUNNER_TEMP:-}" ]; then
    local name=send-trace.json
    [ "${phase:+$phase-}$label" = test-team ] || name="send-trace-${phase:+$phase-}$label.json"
    { mkdir -p "$RUNNER_TEMP/$TARGET" && cp "$dir/send-trace.json" "$RUNNER_TEMP/$TARGET/$name"; } || true
  fi
  if [ "${JOURNEY_RUST:-}" = 1 ] && [ -n "${CMUX_PATH:-}" ]; then rust_run "$label" "$dir" "$@"; fi
  if [ "$phase" = after ]; then
    # Only exit 3 is a proven green-to-red step. Exit 4 is a capacity-only red (no machine available, or rate
    # limited: cloud-journey.ts capacityOnly), the platform's load and never the deploy's; any other nonzero exit
    # is the compare itself failing. Neither rolls the deploy back.
    local rc=0
    bun "$here/cloud-journey.ts" --compare "$out/baseline-$label/journey.json" "$dir/journey.json" > "$dir/compare.txt" 2>&1 || rc=$?
    cat "$dir/compare.txt" >> "$summary"
    if [ "$rc" = 3 ]; then regressed=1
    elif [ "$rc" = 4 ]; then echo "::warning title=Cloud journey::capacity-only red (no machine available or rate limited); not rolling back"
    elif [ "$rc" != 0 ]; then echo "::warning title=Cloud journey::compare failed (exit $rc); not rolling back"; fi
  fi
}
run test-team
if [ -n "${PRODUCT_TEAM:-}" ]; then
  run product-team --team "$PRODUCT_TEAM"
fi
if [ "$phase" = baseline ]; then exit 0; fi
if [ "$regressed" = 1 ]; then verdict regressed; exit 3; fi
if [ "$status" = 0 ]; then verdict pass; else verdict red; fi
exit "$status"
