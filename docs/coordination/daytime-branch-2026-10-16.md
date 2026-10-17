# cmux daytime integration branch — 2026-10-16

Status: ACTIVE pilot
Owner: Leo
Shared branch: `leo/daytime-2026-10-16`

This is a temporary integration lane for the 2026-10-16 workday. Work can
accumulate here without opening a pull request for every small slice. The
branch is reconciled once at the end of the day, then it goes through the
normal integration gate.

## Starting point

- Starting checkout branch: `feat/titlebar-command-toolbelt`
- Starting commit: `7f62f3ca141510ff0bc46c01c17b8dde582eec43`
- Reconciliation target: `origin/main` (refresh immediately before freeze)
- Remote branch: `userfork/leo/daytime-2026-10-16`

The starting commit is inherited work. It is recorded here so the first
reconciliation can distinguish pre-pilot history from work added during the
pilot.

## Pilot goal contract

User-visible outcome: establish a fast daytime integration lane for cmux and
use the first end-of-day reconciliation to decide whether it is safe to keep.

Acceptance criteria for this pilot:

- every daytime change has an owner, scope, commit, and focused check;
- the shared branch advances only by serialized fast-forward updates;
- current fleet capacity and a safe cadence for occasional performance tests
  have evidence-backed answers;
- workspace-switching performance has a per-requirement verdict for first load,
  fade-in, cache reuse, prefetching, and bottlenecks;
- recent cmux-next regression patterns have concrete prevention and tracking
  follow-ups;
- the end-of-day branch is reconciled against current `main` and evaluated at
  the exact reconciled SHA.

Non-goals for this first run: broad refactors, native builds from the MacBook
Air, or silently promoting a green local check to a merge decision.

### Investigation tracks

| Track | Owner | Status | Required evidence |
| --- | --- | --- | --- |
| Fleet capacity and periodic perf bandwidth | `fleet_capacity` | verified | live fleet/queue receipts and cadence recommendation |
| Regression prevention and tracking | `regression_guardrails` | verified | existing guards, recent failure patterns, prioritized gaps |
| Workspace-switching performance | `workspace_switch_perf` | partial | code/test trace; end-to-end cold/warm receipt still needed |

## Ownership ledger

Claim a file, package, test area, or other narrow scope before editing it.
Claims are exclusive until the owner records a handoff. A claim is not a
substitute for reviewing the resulting diff.

| ID | Owner | Scope | Commit(s) | State | Checks / receipt |
| --- | --- | --- | --- | --- | --- |
| `DAY-000` | Leo | Inherited checkout history before the pilot | `7f62f3c` | accepted | Starting-point receipt above |
| `DAY-001` | Leo | Pilot branch policy and ledger | `7451d1f` | complete | `git diff --check`; remote head matched at setup |
| `DAY-002` | `fleet_capacity` | Fleet health and periodic measurement capacity | — | verified | `cmux-ci status` `4988866be9b60607`; workers `41de3f8a3888e2df`; storage `b848ecdc05038b31`; fleet `a8be0769366407b8` |
| `DAY-003` | `regression_guardrails` | Regression prevention and tracking model | — | verified | `cmux-testing` policy; CI guard shards; signposts/tests; red-first history `c943cc9` → `346df1` |
| `DAY-004` | `workspace_switch_perf` | Workspace-switch lifecycle and performance evidence | — | partial | cmux-next `00e3f3a`; lifecycle `18fb52fe90a`; warm reuse found; cold fade/prefetch/bottleneck receipt missing |
| `DAY-005` | `pilot_review` | Independent pilot review | — | needs-work | branch clean at `2d00440`; start `7f62f3c` ancestor; stale-frame and live-fetch gaps recorded below |

Add one row per work slice. Use the commit SHA after committing, and record
focused checks in the final column. If two slices need the same scope, record a
handoff before the second slice starts.

## Evidence and open gaps

- Fleet capacity supports occasional measurements, not blanket fan-out. Use
  `cmux-ci run --class exclusive --measurement --label measure` only when the
  live queue is low, reserve one idle exclusive worker, and keep the default
  cadence to one or two runs per day or at least 30–60 minutes apart. Stop if
  queue depth grows. Do not target reserved, drained, or unhealthy minis.
- Regression coverage already includes red-test→fix discipline, pbxproj wiring,
  non-tolerant workspace-switch CI, lifecycle signposts, and focused tests.
  Record every revert/re-land as a ledger item with repro, invariant, receipt,
  and rollback metadata. `reload.sh` alone is not test evidence.
- Warm workspace switching parks and reuses content under `WarmSetBudget`, and
  the root switch is synchronous. There is no generic crossfade; a narrow
  one-frame paint hold exists for agent/page content. Cold first-frame timing,
  prefetch effectiveness, and bottleneck budgets remain unknown until a tagged
  benchmark records first-frame, settle, interaction, repaint, hitch, and
  dropped-frame metrics. Missing metrics stay unknown; they are not zero.
- The existing perceived-speed and sidebar receipt harnesses are useful
  follow-ups but are not ancestors of this branch. The first reconciliation
  must link or import the selected harness before claiming performance coverage.

## Fast-forward rules

1. The shared branch is append-only during the workday.
2. Never force-push, force-with-lease, reset, amend, or rebase commits that
   have already reached the shared branch.
3. Before pushing, refresh the shared ref and require a fast-forward update.
   A rejected push means another writer advanced the branch; stop, inspect the
   new commits, and resynchronize before continuing.
4. Keep each commit coherent and attributable. Include the ledger ID in the
   commit body when practical.
5. Do not edit a claimed scope without a recorded handoff. Keep unrelated
   cleanup out of a work slice.
6. Run the smallest meaningful check after each coherent slice and record the
   result in the ledger. A green local check is evidence for the slice, not the
   final integration result.
7. During the pilot, shared-branch advancement is serialized. Agents may work
   in isolated worktrees, but only one writer updates the remote branch at a
   time.

## End-of-day reconciliation

At freeze time:

1. Stop new edits and record the final shared-branch SHA.
2. Fetch `origin/main` and inspect the complete pilot diff from the recorded
   starting point.
3. Merge current `origin/main` into the shared branch without rewriting the
   branch history. Resolve conflicts with the ownership ledger as the source
   of truth.
4. Run the required checks against the exact reconciled SHA and record their
   receipts here.
5. Finish with the normal guarded integration boundary: one review PR or the
   repository's guarded merge path. Do not treat a push or a local green check
   as completion.

The first pilot succeeds if we can identify every change and owner, reconcile
against current `main` without losing work, and produce exact-head hosted
evidence for the final integration decision.
