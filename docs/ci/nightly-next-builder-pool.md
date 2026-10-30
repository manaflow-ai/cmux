# nightly-next builder pool (the rolling build train)

cmux NEXT nightlies build on several Macs at once. One builds the newest promoted head; while it
builds, the next free builder takes the next head, and so on, for as long as commits keep coming.

## Who builds

- The builders are the hosts with the `nightly-next-builder` role in cmuxterm-hq
  `build-fleet/mini-fleet.json`. That file is the only list. Each runs one GitHub runner,
  `<host>-nightly-next`, with the labels `glaeda-trusted-light-xcode-26.6`,
  `glaeda-runner-nightly-next` and `glaeda-trusted-next-nightly`, and the admission hook
  `scripts/ci/nightly_builder.py admit` (only `nightly.yml` `build-nightly-app` on a push to
  `nightly-next`). cmuxterm-hq `build-fleet/nightly-builders/reconcile.py` installs, relabels
  and removes those runners from the manifest; its test keeps the manifest, the labels and the
  owned-pool rescue in agreement.
- `vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER` is the shared label `glaeda-runner-nightly-next`, so
  `build-nightly-app` runs on whichever builder is free. The owned-pool rescue never moves a job
  waiting on a `glaeda-runner-` label (#22645), so a waiting build stays on the pool.
- A dead builder only removes capacity: nothing names a builder, and its queued job goes to
  another one.

## When a head is built (the scheduler)

The scheduler is main's promote guard, not a clock:

1. Every automatic request (`scripts/cmux-next/request-nightly-next.sh`, from cmux-next.yml,
   cmux-tui-artifacts.yml and main's nightly-next tick) sets `promote_nightly_next_debounce`.
2. `waitingBuild()` in main's `scripts/ci/promote-nightly-next.mjs` holds that request while a
   nightly-next push run's `build-nightly-app` is queued for a builder or not created yet. So at
   most one build waits, and the next promotion is always the newest buildable head.
3. When a build ends, its `rearm-train` job dispatches main's tick, which asks for the newest
   buildable head again. Each finished feat-cmux-next run asks too.

Builds of successive heads overlap (one concurrency slot per run). Promotion still goes through
every guard: G1/G2 (or a12's train commit G1'/G2'), the release-surface ack. The pool never
builds a raw feat-cmux-next head, and train candidate refs (`nightly-train/*`) are not feed builds.

## What is published

- Build number = `<nightly-next run id><attempt, 2 digits>`, so a newer head always has a higher
  number, and the verdict, fix-forward and train base lookups keep mapping build to commit.
- `check-build` refuses any build that is not above the feed, before and inside the publication
  lock. An older head that finishes after a newer build published is therefore dropped, and
  `report-nightly-failure` drops it quietly: it reads the cmux NEXT feed and returns when a
  build there is above this run's.
- No in-flight build of an older head is cancelled; it stops only at those checks, which means
  a newer build has already published.
- Signing, notarizing, both canaries and publishing are unchanged and stay on GitHub-hosted
  runners. A builder is held only for `build-nightly-app` (about 10 minutes), so throughput is
  about one build per 10 minutes per builder.

## Warm builds

Each builder keeps its checkout, the content-keyed Xcode compilation cache
(`scripts/ci/nightly_build_state.py`, runner names `*-nightly-next`), SwiftPM checkouts and the
cargo targets. The shipped app never builds on retained DerivedData (stale autolink objects; see
"Start Release DerivedData empty" in nightly.yml).
