# feat-cmux-next CI feedback timing

This receipt covers the bounded controller timing sample collected on
2026-10-13/14 UTC. It joins current `feat-cmux-next` pull request heads to the
controller's GitHub timing records. It does not poll GitHub or use the retired
ci-dash JSON path.

## Baseline

Push to the last gating check was **15.8 minutes p50** and **48.0 minutes p90**
across 15 current heads with usable records. Queue and run time are separated
below; values are minutes, shown as p50 / p90.

| Job | Samples | Queue | Run | Wall when available |
| --- | ---: | ---: | ---: | ---: |
| cmux-next fast tier | 11 | 5.7 / 11.4 | 7.4 / 11.2 | 12.7 / 22.5 |
| Swift canary | 3 | 13.5 / 13.5 | 5.4 / 5.4 | 18.9 |
| Swift report-only | 19 | 0.05 / 1.57 | 4.2 / 7.8 | 5.0 / 8.5 |
| web `react-apps-check` | 4 | 8.0 / 9.0 | 14.5 / 14.7 | 14.7 / 14.9 |
| cmux-next checks | 32 | 0.05 / 0.08 | 3.7 / 4.8 | - |

The clearest admission outlier is PR #20366, run 38496711448. Its fast tier
was created at 01:44:04Z and finished at 02:35:10Z: **39.6 minutes queued** and
**11.35 minutes running**. Runner setup and completion consumed 338 seconds of
the run. Its Swift canary queued 13.5 minutes and ran 5.4 minutes. The same run
also had canceled report-only and checks attempts before the final attempt.

## Changes and expected receipts

1. **Superseded PR attempts:** fast tier, Swift canary, and report-only Swift
   now use a pull-request concurrency key and cancel an older PR attempt. Push
   runs retain their branch queue semantics. Before: #20366 showed multiple
   report/check attempts (136s and 196s canceled before a 320s attempt). After:
   only the newest PR attempt remains eligible to consume a runner; the next
   controller sample must show one attempt per current head.
2. **React webviews:** `react-apps-check` previously ran `typecheck` inside
   `bun run build` and again in `bun run check`. The source build now runs
   `verify:tanstack-router` and `vite build`, while the dedicated check runs
   typecheck once. Bun's package cache is restored by the lockfile key on the
   Blacksmith Linux job. Before: run p50/p90 **14.5 / 14.7 minutes**. After:
   the next green receipts should show the duplicate typecheck removed; the
   first post-change record is the measured comparison.
3. **macOS admission:** the fast tier and canary remain minis first. The
   measured 39.6-minute wait is an admission/eviction problem, so this change
   coalesces stale PR work instead of routing native work away from minis.
   The next controller sample is the canary for queue p50/p90 and setup/complete
   overhead.

The retired persistent compile pilot is explicitly archived in
`docs/ci/mac-fleet.md`; current routing and capacity belong to `ci-runners.md`
and live controller receipts.

