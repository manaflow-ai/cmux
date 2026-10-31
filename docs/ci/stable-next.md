# cmux NEXT Stable

cmux NEXT Stable is the team's slower, harder-gated cmux NEXT. Once a night it takes the newest
cmux NEXT nightly build, runs the stable gates on that build's commit and on its signed bits,
re-signs the same bits as a separate app and publishes them to its own feed. The nightly
(`nightly-next` tick and train, `nightly.yml`) is unchanged.

| | cmux NEXT (nightly) | cmux NEXT Stable |
| --- | --- | --- |
| App | `cmux NEXT.app` | `cmux NEXT Stable.app` |
| Bundle id | `com.cmuxterm.app.nightly.cmux-next` | `com.cmuxterm.app.nightly.cmux-next-stable` |
| Icon | Nightly icon | regular cmux icon |
| Sign-in scheme | `cmux-next` | `cmux-next-stable` |
| Feed | `files-next.cmux.com/nightly-next/next/appcast-arm64.xml` | `files-next.cmux.com/nightly-next/stable/appcast-arm64.xml` |
| Item channel | `cmux-next` | `cmux-next-stable` |
| Cadence | every promotion | once a night, from 21:00 Pacific |

The bundle id keeps the `com.cmuxterm.app.nightly` prefix on purpose: `BuildIdentity` treats any
other `com.cmuxterm.app.<x>` id as a DEV build. Under that prefix the stable app behaves as a
nightly build with state roots of its own, so it runs beside cmux NEXT without sharing its daemon,
Chief home or preferences. The feed keeps `/nightly-next/` in its path because `UpdateFeedResolver`
classifies a feed by that segment; every update ring accepts `cmux-next-stable` items.

Same R2 bucket (`cmux-nightly-next`), same Sparkle key (`SPARKLE_NEXT_PRIVATE_KEY`) and the same
`release-next` environment as the nightly: no new secret. Version and build number are the
nightly's (`1.0.0-nightly.<build>`), so a Sentry release `cmux-next@<version>+<build>` covers both.

## The night

`stable-next.yml` on `main` ticks at minute 5 of every hour from 04:00 to 14:00 UTC. A tick
dispatches a publish run on `nightly-next` only while it is 21:00 to 06:59 in
America/Los_Angeles, no stable build was published since 21:00, no stable run is queued or
running, and fewer than 3 runs failed that night.

A run:

1. **plan**: picks the newest item on the cmux NEXT feed that Nightly apps are offered, or
   the `build` input. It skips any build listed in the stable feed's own `pulled.json`.
   - **Commit:** the build's signed release notes (`notes/<build>.json`, `head`) record
     `nightly.yml`'s `build_sha`, the commit the app was compiled from. That can trail the
     run's head, so the run's head is not used. Every gate tests this commit, and the re-sign
     step checks it against the bundle's own `CMUXCommit`.
   - **Refusals:** a build pulled from the cmux NEXT feed, or one with a `fail` verdict.
   - **Already shipped:** when the stable feed already has the build, the run stops (unless
     `force`).
2. **gates**, in parallel:
   - `crash-class`: the `cmux-next-crash-class.yml` rules on the whole tree, plus
     `stable_next.py crash-delta`. That compares the candidate against the commit the stable
     feed serves, and fails on any new counted or banned crash-class hit. The whole-tree
     ratchet is red on `feat-cmux-next` itself, so as a gate it would block every night on
     debt the last stable build already shipped.
   - `swift-suites`: one owned mini submits 4 shards at once. Together they cover every
     CmuxNext test target, by target name, and run with `package-test-lane.sh suite` as
     build-fleet steps on `macos-27` + `ram48` workers. Those are M4 Pro only, because no M6
     mini has `ram48`. Each shard retries once.
   - `perf-budgets`: `split-spring.sh --suite=budgets --gate` on an exclusive macOS 27 M4 Pro
     measure worker. It fails when a row's p95 is more than 10% over the
     `apple-m4-pro-macos27` baseline.
   - `sign`: Blacksmith macOS 26. It re-signs the nightly DMG as cmux NEXT Stable
     (`scripts/ci/stable-next-identity.sh`), notarizes and staples the result, and generates
     the Sparkle item.
   - `smoke-27` and `smoke-26`: the fresh-home launch smoke of the signed stable DMG. One
     runs on an owned M4 Pro mini on macOS 27, the other on Blacksmith macOS 26 (the sanity
     check). The app must stay up 30 s with Home rendered and no crash report.
   - `soak`: the build is still on the cmux NEXT feed and was never pulled, and Sentry shows
     no new unhandled issue first seen in its release.
     - A Sentry crash always fails the gate.
     - By default, a Sentry that cannot be read only warns. Set
       `STABLE_NEXT_SENTRY_GATE=enforce` once the token's issue read is proven.
     - No minimum soak time: the team asked for the newest nightly every night.
3. **publish**: only the DMG whose sha256 both smokes tested goes up. Its name carries the
   run id, so a retry never collides with an earlier attempt's write-once object. The DMG
   uploads write-once to R2, then the feed is written: the new item plus the two newest earlier stable
   builds, checked by `nightly-next-guard.py appcast`, and written by compare-and-swap against
   the bytes that were read.
4. **report**: a failed publish run opens the `cmux NEXT Stable blocked` issue, or comments on
   it if it is open (label `stable-next-blocked`, assigned to `vars.STABLE_NEXT_OWNER`). The
   next published build closes it.

There is no run-level concurrency group. With one, a rollback would wait hours behind a run's
gates, or a dispatch could replace a pending rollback. The tick starts at most one publish run,
and every feed write (publish or rollback) is a compare-and-swap.

A rollback records each pulled build in `nightly-next/stable/pulled.json`, so the next night
does not re-publish it while it is still the newest nightly. Pulling the only stable build
needs `allow_empty`.

No job uses an M6 mini. Owned macOS jobs take `CI_SIDE_LANE_RUNNER` (std class, M4 Pro) and fail
on any other chip. Signing stays on Blacksmith, like the nightly's.

The repository rule against new CI gates (CLAUDE.md, Lawrence 2026-10-23) is about push, pull
request and nightly paths. This workflow adds nothing to them: it runs only on its schedule, a
dispatch, or a push to `stable-next-dry-run`.

## Commands

```bash
# Tonight's run, now (nightly-next only):
gh workflow run stable-next.yml -R manaflow-ai/cmux --ref nightly-next -f mode=publish
# A given build, or again after a stable build shipped tonight:
gh workflow run stable-next.yml -R manaflow-ai/cmux --ref nightly-next -f build=4099184203401 -f force=true
# Dry run (every gate, ad-hoc signed copy, nothing published, no secrets):
git push origin <sha>:refs/heads/stable-next-dry-run
# Pull a bad stable build (the feed then serves the previous one):
gh workflow run stable-next-rollback.yml -R manaflow-ai/cmux --ref nightly-next -f reason="..." [-f bad_build=B | -f to_build=B] [-f dry_run=true] [-f allow_empty=true]
# Locally:
python3 scripts/ci/stable_next.py pick --feed next.xml --stable stable.xml --pulled pulled.json
python3 tests/test_stable_next.py
```

## Before the first publish

1. Land this on `feat-cmux-next`, and let a promotion carry it to `nightly-next`
   (`release-next` deploys only there).
2. Land `.github/workflows/stable-next.yml` and `stable-next-rollback.yml` on `main`. The
   schedule and both dispatches register only from the default branch; there the file only
   ticks.
3. Deploy the web change (`cmux-next-stable` in `web/app/lib/native-callback.ts`). Until it
   is deployed, sign-in from cmux NEXT Stable falls back to the `cmux` scheme.
4. Computer Use consent from cmux NEXT Stable needs a nightly that includes the
   `HostVerifier` entry. Every stable build is a nightly build, so it arrives with the first
   nightly after this lands.
