# Nightly decoupling plan (cmux NEXT, 2026-11-10)

Leo, 2026-11-10: "is there a way to like... decouple nightly builds from all this nonsense? speed stuff up,
deduplicate things, skip or ignore things?"

## What the last runs show

Sample: the 16 finished `nightly-next` push runs of nightly.yml from 2026-11-09 16:03Z to 2026-11-10
02:52Z (each one the build stage), the sign runs they dispatched, and the 100 newest nightly.yml runs.

| Stage | Median | Worst | Notes |
|---|---|---|---|
| Release compile gate (cmux-next.yml) | 3 min (fleet verdict) | 20 min wait, then a Mac compile | While the controller was down, gh-events.cmux.com answered 530 and the fast check retried it for its whole 1200 s deadline |
| Tick to push run | 7 min (tick period) | 7 min | 46 of the 100 newest nightly.yml runs are 18 s promote dispatches |
| Wait for the build slot | 0 min | 30 min | 84 of 100 push runs were replaced while pending: latest-wins already works (concurrency group, GitHub replaces only a pending run) |
| Build stage (push run) | 32 min run, 17 min build-nightly-app | 148 min | Release compile itself 5 to 10 min. The rest: warm checkout 7 to 17 min (2 runs), web bundle restore 14 to 19 min (2), tree companion fetch 70 min (1), compilation cache restore 30 min on one large runner (1), runner setup 18 min (1) |
| Sign stage (dispatched sign run) | 51 min (42696304277) | 120 min | Before signing it repeats resolve (3 min), the app resume (3 min) and prepare-variant (2 min). Then sign and notarize 20, verify 7 (5 of them downloading the signed app) beside DMG verify 4, publish 9 |

Build-stage failures, 8 of 16:

| Cause | Runs | Status |
|---|---|---|
| "Bundle the cmux-tui client" failed after 33 to 45 min (42675465011: an x86_64 slice from files.cmux.com at 6 KB/s) | 42650828218, 42659768888, 42675465011 (and 42681840369 after 6 min) | Fixed for 42675465011's cause before this plan: nightly-next fetches the arm64 slice only. No failure in this step since 19:16Z |
| Sign dispatch refused with a 403 rate limit | 42726398544 | Open: #40071 waits through the limit |
| A light job found `scripts/ci/nightly-steps/ensure-gh.sh` missing after a checkout of a commit that has it (the runner reused a workspace a sparse checkout had used; the cause is not proven) | 42745665744 | Open, below |
| build-nightly-app and the helper both failed after 148 min (log truncated) | 42728280013 | Not diagnosed |
| Zig 0.16 from the host for a tree that needs 0.17 | 42745422648 (build_only) | Fixed by #40139 and #40131 |

The critical path from merge to feed is the gate, then the tick, then the build stage, then the sign
stage. Each stage keeps one run in flight and lets the newest pending one replace the rest, so the
publish period is the slower stage: the sign stage, 51 to 120 min. The best case from a merge to the feed is
about 3 + 7 + 32 + 51 = 93 min. The controller adds 20 min plus a Mac compile while it is down.

## Plan, biggest saving first

| # | Item | Saving | State |
|---|---|---|---|
| 1 | Receipts are a cache. When the results service is down (no connection, or the edge's 52x or 530, twice 30 s apart), the fast check hands the gate to the Mac fallback at once | 20 min, down to 0.5 min, on every feat-cmux-next push while the controller is down | This PR |
| 2 | Sign stage: skip the repeated resolve, app resume and prepare-variant work, and pass the build stage's outputs to the sign run as its inputs | about 8 of the sign stage's 51 min (16 %) | Next. It touches the build/sign handoff (dispatch-nightly-next-sign, decide's pipeline), so it gets its own PR and review |
| 3 | Verify the signed app on the runner that signed it, or hand it over through R2 instead of a GitHub artifact | 5 of the 7 min verify | Next |
| 4 | Pin toolchains to checksummed downloads, not Homebrew or apt: gh (ensure-gh.sh) as Zig already is (install-zig-ci.sh: reviewed versions, minisign, sha256) | A cold mini or light runner no longer depends on Homebrew or apt (`brew install gh` takes 1 to 2 min; `apt-get update` takes 30 to 60 s). It also removes a whole class of version drift | Small PR |
| 5 | Light jobs: a checkout that leaves tracked files missing (git ls-files --deleted) restores them before the first script runs. Or the runner that did it leaves the nightly light pool | One failed build stage in 16 (6 %), about 30 min each | Needs a step outside the `&ensure-gh` anchor (tests pin that step's text) |
| 6 | Skip refresh-compilation-cache and the probe when their inputs did not change | 0 on the nightly-next critical path: neither runs on a nightly-next push (schedule `17 */6` on main, or a dispatch only). It saves pool time only | Low priority |
| 7 | Latest-wins for queued push runs | Already in place (84 of 100 replaced while pending). Nothing to do. Never cancel a started run | Done |
| 8 | Promote loop: 46 of 100 runs are 18 s promote dispatches on main | Each one is about 20 s of a runner and no critical-path time. Folding the move into nightly-next-tick.yml would end them, but it touches the release-next environment on main | Low priority |
| 9 | A runner pool of the nightly's own, and a second signing host | The sign stage has one signer. Today signing_runner.py drains a mini or falls back to Blacksmith. A second owned signing host halves the wait behind an in-flight sign, worth up to 51 min when two builds are ready | Needs a host decision |
| 10 | #24563 (open, by its owner): promotion stops waiting for the Release compile gate at all | Removes the gate stage, 3 to 20 min | Its owner's PR. It conflicts, and the nightly build becomes the admission boundary |

## Rules kept

- A started nightly is never cancelled. Only a pending run is replaced, by GitHub's concurrency group.
- The in-flight runs 42756073283 and 42758905507 were not touched.
- build-nightly-app's Zig lines from #40139 are unchanged.
