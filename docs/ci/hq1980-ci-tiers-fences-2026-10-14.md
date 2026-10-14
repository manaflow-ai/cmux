# hq#1980 CI timing, tiers and fences

This is the bounded receipt for the seven-day `feat-cmux-next` follow-up. PR
metadata came from the GraphQL-backed `gh pr list` query, and CI timing came
from the local controller receipt in
[`feat-cmux-next-feedback-timing-2026-10-14.md`](feat-cmux-next-feedback-timing-2026-10-14.md).
No `ci-dash` utilization JSON or GitHub run-ledger polling was used.

## PR open to merge

The window is 2026-10-07 04:53Z through 2026-10-14 04:53Z, with 1,330 merged
PRs targeting `feat-cmux-next`. Open-to-merge wall time was **34.2 minutes p50
and 611.9 minutes p90**. The distribution is heavy-tailed: the p95 is 2,004.0
minutes, so the p90 is driven by human or batch waits as well as CI.

As a sensitivity check, the cohort opened during the same window was 1,265 PRs:
31.12 minutes p50 and 252.63 minutes p90. The merged cohort is the primary
receipt because it measures a complete open-to-merge outcome.

The same 1,330 PRs have GitHub Actions check-suite timestamps. Using the active
Actions window, from the earliest suite creation to the latest suite update
(excluding other check providers and post-merge updates), CI wait was **25.25
minutes p50 and 88.85 minutes p90**. The residual open-to-merge wait was **7.60
minutes p50 and 499.47 minutes p90**. This is a wall-time decomposition, not a
claim that every minute in the CI window was runner queue; the controller
receipt below supplies queue/run detail. 779 PRs had suite updates after merge,
so counting those would double-count the residual; they were excluded.

The controller's current exact-head sample separately measures push to the last
gating check at **15.8 minutes p50 and 48.0 minutes p90**. The next controller
receipt should join PR number, `created_at`, `runner_ready_at`, and last-gate
completion to reconcile that active-window measure with per-job queue time.

The fast-tier baseline was 5.7/11.4 minutes queue and 7.4/11.2 minutes run
(p50/p90, n=11). `react-apps-check` was 14.5/14.7 minutes run (n=4). PR #20366
was the admission outlier: 39.6 minutes queued, 11.35 minutes running, with
338 seconds in setup/completion overhead. Those receipts justify keeping the
fast tier on Linux and removing per-PR Swift admission.

## Two tiers

| Tier | Runs | Branch | Gate | Owner |
| --- | --- | --- | --- | --- |
| Fast | web subareas, web typecheck, deterministic Rust entries | every PR | required; p50 target <5 min | each changed-area owner |
| Batch cadence | Swift tests/canary, size cap, crash ratchet, Release/scheme/daemon and generated checks | `full-ci` batched integration branch and base pushes | required on the batch tip; roll forward or bisect the culprit | `@teamleaderleo` (batch sheriff) |

The fast Rust entries now run on Blacksmith Linux. Swift entries were removed
from `scripts/cmux-next/fast-tier.json`; the existing `ci-web.yml` jobs provide
the web and typecheck half of the fast tier. Ordinary PRs skip the Swift, size
cap and crash ratchet steps. The batch queue already stacks up to twelve PRs,
dispatches `cmux-next.yml` on `next-batch/*`, and bisects a red stack. The
sheriff rolls forward the next green prefix and names the first red PR.

## Familiar-intent warning

`.github/review-bot-rules/familiar-intent.md` and `.coderabbit.yaml` tell
CodeRabbit/cubic to warn and mention an `owner=` when a changed hunk touches
`@intent ... stability=familiar`. The trusted
`.github/workflows/intent-familiar-review.yml` hook makes that warning
deterministic and advisory. A body line `Intent-Delta:` suppresses the warning.
The PR template now includes `Intent-Delta: none` for the author to replace.

## Fence inventory

“Last catch” means the latest bounded receipt showing the fence stopped or
redirected work. `unknown` is intentional: no live receipt was found in the
known controller roots, so it must not be treated as proof that the fence is
useful.

| Fence | Source / effect | Last catch in bounded evidence |
| --- | --- | --- |
| PR concurrency (`cmux-next-pr-*`) | Cancels superseded PR attempts | 2026-10-13, #20366 had two canceled report/check attempts before the final attempt |
| Owned-pool runner refusal rescue | Watches accepted runs through completion and reruns late `Set up runner` refusals | 2026-10-13, #20308 run 38498502461 |
| Mini admission / side-lane labels | Keeps minis first; can defer a job behind a busy host | 2026-10-14 controller sample, local-mini queue p90 1,633 s |
| `reservation.json` host marker | Pauses claims while a named reservation is live or invalid | 2026-09-28 seed-efficiency observation; no newer live catch receipt |
| Host lock / exact lease | Serializes host mutation and expires a holder | unknown in the bounded controller sample |
| Warm-slot lease and reservation | Prevents a warm slot from being reused by another task | unknown in the bounded controller sample |
| Same-tree cmux-tui wait marker | Defers daemon/scheme work until the exact tree is published | historical receipts 37767816879 and 37769010617; no 7-day catch timestamp |
| Batch debounce (2 min quiet, 10 min hard max) | Coalesces PR events into one integration branch | 2026-10-14 batch-controller run; no red-catch event recorded |
| Cache reserve floor (`CMUX_CACHE_RESERVE_BYTES`) | Refuses cache writes below the fixed disk floor | source-only in this sample; no live catch receipt |

The follow-up metric that closes the largest gap is the controller join of
`runner_ready_at` and `wait_reason`, plus cleanup start/end for eviction
attribution. It is bounded instrumentation and does not change routing.
