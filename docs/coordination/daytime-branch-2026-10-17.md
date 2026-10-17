# cmux-next daytime integration branch — 2026-10-17

Status: ACTIVE pilot
Owner: Leo
Shared branch: `leo/daytime-2026-10-17`

This branch is a temporary integration lane for the cmux-next feature work. It
is based on the active feature branch and reconciles back to that branch at the
end of the day. `main` is not the target for this pilot.

## Starting point

- Starting checkout branch: `run-attach-linux`
- Starting commit: `00e3f3a2d5f44f5f70d9aa30b028fc6645dd077a`
- Reconciliation target: `origin/run-attach-linux` (refresh immediately before freeze)
- Remote branch: `origin/leo/daytime-2026-10-17`

The feature branch remains the product authority. The daytime branch is an
append-only working lane and does not promote changes to `main`.

## Ownership ledger

Claim a narrow file, package, test area, or benchmark scope before editing it.
Claims are exclusive until the owner records a handoff. Use the exact commit
SHA, command, host, and receipt in each row.

| ID | Owner | Scope | Commit(s) | State | Checks / receipt |
| --- | --- | --- | --- | --- | --- |
| `DAY-000` | Leo | Inherited feature-branch history | `00e3f3a` | accepted | Starting-point receipt above |
| `DAY-001` | Leo | Pilot branch policy and ledger | pending | active | This document |
| `DAY-002` | `/root/perf_practices_research` | Cross-repo regression/perceived-performance patterns | analysis-only | verified | Chromium, Firefox, rustc-perf, AndroidX, and existing cmux-next workflows |
| `DAY-003` | `/root/cmux_next_async_perf` | Async workspace-switch benchmark lane | analysis-only | verified | Existing tab-switch/frame-pacing benches; no native build run |
| `DAY-004` | `/root/fleet_health_repair` | Fleet health and supported repair audit | analysis-only | verified | `fleet up`, `xcode-pin-audit`, Tailscale ping receipts; no mutation applied |
| `DAY-005` | Codex threads `01a1470a-8f11-77c0-8d28-b4006b0bac08` and `01a143d8-1958-7c41-8bfb-7bcf247edce6` | Cross-root fleet/PR coordination | pending | sent | Explicitly authorized messages sent; acceptance/ownership receipt pending |

## Fast-forward rules

1. The shared branch is append-only during the workday.
2. Never force-push, reset, amend, or rebase commits already published to the
   shared branch.
3. Refresh `origin/leo/daytime-2026-10-17` before every push. A rejected push
   means another writer advanced the branch; stop, inspect, synchronize, and
   retry with a fast-forward update.
4. Shared-branch advancement is serialized. Agents may use isolated worktrees,
   but only one writer updates the remote branch at a time.
5. No overlapping scope without a recorded handoff. Keep unrelated cleanup out
   of a work slice.
6. Run the smallest meaningful check after each slice and record the exact
   command and receipt. A green local check is not final integration evidence.

## Low-churn performance policy

Performance work stays asynchronous and warning-only while the feature branch
is moving. The first lane should reuse existing cmux-next infrastructure:

- extend the existing frame-pacing/tab-switch bench with cold, warm, and
  prefetched workspace transitions;
- record action-to-visible, first-frame, settled-frame, p50/p95/p99 frame
  overrun, dropped frames, repaint/hitch counts, and a transient/settled
  surface invariant;
- archive JSON plus a short Markdown summary keyed by source SHA, host, display,
  and tagged app;
- compare against the same host/display using rolling medians and warn only;
- schedule one or two runs per day, skip cleanly when the owned display or
  worker is busy, and promote a signal to a blocking check only after repeated
  stable evidence.

Missing metrics remain unknown. They are not converted to zero, and a skipped
measurement does not become a green performance claim.

### Reference patterns

These patterns keep measurement asynchronous and make noise visible without
blocking ordinary feature work:

- [Chromium performance waterfalls](https://chromium.googlesource.com/chromium/src.git/+/master/docs/speed/perf_waterfall.md)
  and [perf trybots](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/speed/perf_trybots.md)
  separate continuous trend collection from on-demand same-device A/B runs.
- [Firefox Talos and Perfherder](https://firefox-source-docs.mozilla.org/testing/perfdocs/perf-sheriffing.html)
  alert post-hoc against historical windows and explicit noise thresholds.
- [AndroidX Macrobenchmark metrics](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-metrics)
  names cold/warm journeys and reports initial/full display plus p50/p95/p99
  frame timing and overrun instead of one wall-clock number.
- cmux-next's existing `cmux-next-frame-pacing.yml`,
  `scripts/ci/frame-pacing/` summarizer, and browser-parity perf harness already
  provide the lowest-churn local pattern: one-at-a-time scheduled runs, JSON
  artifacts, warning-only thresholds, and explicit known-failure reasons.

The proposed adaptation is a workspace-switch scenario in the existing runner,
not a new required check: cold/warm/prefetched labels, first visible frame,
settled frame, p50/p95/p99 overrun, dropped frames, repaint or hitch counts,
and a transient/settled invariant. Promote only repeated, low-variance signals
to a blocking gate after the feature branch has enough history.

## Regression tracking

For behavioral regressions, commit the red test before the fix, prove that the
test executed and failed, then commit the fix and rerun the same focused test.
Record the repro, expected invariant, red-test SHA, fix SHA, rollback SHA,
test-selector output, and any target-wiring receipt. `reload.sh` alone does not
establish test coverage.

## Fleet health receipt

The first health audit found capacity and observability issues rather than a
need for broad repair:

- `fleet --no-fetch up all` reported 31 hosts, with no-pong results on
  cmux18/19/20/21/22/23/24 and Xcode-selection failures on cmux20/22/23;
- direct Tailscale pings to cmux18 and cmux20 succeeded, indicating that the
  no-pong result is currently a fleet-observability/configuration bug rather
  than proof that those hosts are down;
- the Xcode-selection failures have no fleet CLI dry-run or install path and
  require the fleet/Xcode owner;
- no repair was applied; `fleet tailscale-unstick` can mutate state and is not
  safe to run broadly without host-specific ownership and evidence.

Read-only receipts: `/tmp/fleet-up-all.txt` (23:52 PDT),
`/tmp/fleet-runner-status.txt` (23:54 PDT), `/tmp/xcode-audit-3.txt` (23:56
PDT), and `/tmp/fleet-up-targeted.txt` (23:59 PDT). No fleet state changed.

## End-of-day reconciliation

At freeze time:

1. Stop new edits and record the shared-branch SHA.
2. Fetch `origin/run-attach-linux` and inspect the complete daytime diff.
3. Merge the current feature-branch tip into the daytime branch without
   rewriting the shared history. Resolve conflicts using the ownership ledger.
4. Run the required checks against the exact reconciled SHA and preserve the
   receipts.
5. Keep the result on the feature lineage. Do not merge or compare it to
   `main` as part of this pilot.
