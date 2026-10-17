# Asynchronous workspace-switch measurements

The `cmux-next frame pacing` side lane reuses one tagged build for fling and
workspace-switch measurements. It runs once daily at 09:37 UTC or on demand.
It has no pull-request trigger and supplies no required feature-branch check.
Performance limits emit warnings; a busy owned runner or GUI produces a skipped
JSON receipt. Bench errors are visible in the receipt and summary, and the
measurement step uses `continue-on-error`.

The existing scheduled target remains `feat-cmux-next`. GitHub runs cron
workflows only from the repository's default branch, so adding this workflow to
a feature branch does **not** activate its schedule. Once the workflow is present
on the default branch, its existing cron measures that configured target. During
the daytime pilot, dispatch the workflow from the implementation branch and set
`ref` to `leo/daytime-2026-10-17` (or the exact feature branch to measure):

```sh
gh workflow run cmux-next-frame-pacing.yml --repo manaflow-ai/cmux \
  --ref <branch-containing-this-workflow> \
  -f ref=leo/daytime-2026-10-17 -f workspace_runs=3
```

This reuses the existing trusted-ref resolver, owned-runner admission gate,
one-at-a-time workflow concurrency, and GUI token. There is no added runner or
paid fallback. A missing GUI-token helper skips measurement; a busy GUI retains
the existing 15-minute acquisition wait before skipping. Portable receipt tests run on the existing
Linux gate job. No benchmark is submitted by changing a feature branch.

## What each journey measures

| Arm | Preparation | Cache-state label |
|---|---|---|
| cold | Create a new, unvisited workspace; measure its first readiness | `new_workspace` |
| warm | Return home, wait one second, revisit the parked destination | `parked_revisit` |
| prefetched | Explicitly previsit the destination until ready, return home until ready, then revisit | `explicit_previsit` |

Cold is workspace cold; the app process and its prewarmed New Tab spare may be
warm. The prefetched arm is a **previsit simulation**. It does not establish that
cmux-next performs background workspace prefetching. These journeys currently
exercise the default New Tab content; the existing mixed terminal/Chromium
tab-switch bench remains available for those workloads.

`first_visible_ms` is the first RPC sample where the selected destination's
content is installed, in its drawable window, presentable, and has painted if a
page reports paint state. `settled_ms` requires this state to remain valid for
100 ms. Both are `surface_readiness_rpc_upper_bound`: action/RPC overhead and the
20 ms sampling interval are included. They are not display-presentation times,
and do not prove animation, stale-pixel, or fade-in quality. Each arm also records
`debug.frames` over at least 400 ms, p50/p95/p99 overruns relative to its measured
refresh period, missed-vsync intervals as a dropped-frame proxy, and transient
and settled content invariants. Unknown metrics remain `null`.

## Receipts and initial warnings

The existing `frame-pacing-<run-id>` artifact includes `workspace-switch.json`.
Admission skips upload `workspace-switch-skipped-<run-id>` instead. Schema v1
records the full **app source SHA**, harness SHA, app binary hash, host/OS,
display metadata, benchmark parameters, cache labels, raw frames, results and
limitations. Its fingerprint covers source, host, display and parameters; compare
like fingerprints/environment fields before drawing conclusions across runs.

Initial smoke limits warn on median first readiness above 500 ms cold or 150 ms
warm/prefetched, median settled readiness above 1000 ms, missed-vsync intervals
above 5%, missing frame evidence, timeouts, or settled invariant failures. They
remain warning-only for performance regressions and unknown/skipped runs. The
workflow additionally invokes `--strict-invariants`: a measured journey fails
only when it reports a settled content invariant violation (for example, the
selected workspace does not match the visible pane, or the selected tab's
content is not the shown content). A timeout has no settled verdict and stays
unknown. This gate checks selected-workspace/content coherence; it does not
claim to measure display-presentation timing, animation, or fade quality.
Collect repeated same-host, same-display receipts before calibrating the
performance limits; no live statistical polling or automatic baseline edits is
added.

For an already built, unused tagged artifact in an owned GUI session:

```sh
python3 scripts/cmux-next/bench_workspace_switch.py --tag <tag> \
  --app '<path>/cmux DEV <tag>.app' --sha <full-app-source-sha> \
  --harness-sha "$(git rev-parse HEAD)" --out artifacts/workspace-switch.json
python3 scripts/cmux-next/workspace_switch_receipt.py \
  --summary artifacts/workspace-switch.json
# Optional CI gate for a measured settled-content regression. Skips, missing
# receipts, and timeouts remain explicit non-blocking states.
python3 scripts/cmux-next/workspace_switch_receipt.py \
  --summary artifacts/workspace-switch.json --strict-invariants
python3 scripts/cmux-next/tests/test_workspace_switch_receipt.py
```

The driver launches and tears down only its tagged app and disposable daemon
workload. It refuses the user's `com.cmuxterm.app` bundle and an already running
tagged app, and verifies that the app socket PID matches the launched PID.
