# cmux NEXT nightly: canary and rollback

cmux NEXT installs update themselves from one Sparkle feed,
`https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml`. A bad
nightly reaches every install within one update check. This page covers the
canary that keeps a bad build off that feed and the command that takes one
off it.

## Pull a bad build

```bash
gh workflow run nightly-next-rollback.yml -R manaflow-ai/cmux --ref nightly-next \
  -f reason="New Tab is blank on launch"
```

This takes the newest build off the feed. The feed then serves the build
before it, whose signed DMG is still on the `nightly-next` release. The run
takes about a minute. Its summary names the pulled build and the build the
feed now serves. Choose the target with one of these:

| Input | Effect |
| --- | --- |
| *(none)* | Pulls the newest build. |
| `-f bad_build=N` | Pulls build N and every newer build. |
| `-f to_build=N` | Serves build N and pulls everything above it. |
| `-f dry_run=true` | Prints the plan and writes nothing. |

The Actions page has the same inputs: open **nightly-next rollback**, choose
**Run workflow**, then choose branch `nightly-next`. The `release-next`
environment, which holds the feed's R2 token, deploys only to that branch. A
run on another branch does nothing.

The run refuses when:

- it would leave the feed empty;
- the build it would serve has no DMG;
- the feed changed while it was planning (run it again).

### What a pull does to installed Macs

Sparkle offers an item only when its `sparkle:version` is above the running
build (`AppcastSelector`, `SUStandardVersionComparator`). A feed can never move
an installed app down. So after a pull:

- New installs and Macs that have not taken the bad build yet get the previous
  build. The bad build stops spreading.
- A Mac already on the bad build keeps it. The app can roll back to the build
  it kept before updating (`updates.keepPreviousVersions`) through its
  `updates.rollback` control method, which refuses when the kept build can't
  read the stores on disk. Today only a DEV build's CLI reaches it
  (`cmux app call updates.rollback '{}'`); a Release CLI command is a follow-up.
- To bring every Mac forward, publish a build above the bad one. Revert the bad
  change on `feat-cmux-next` and let promotion publish it. It gets a new, higher
  build number, so every install updates to it. Every real pull starts this
  for you (see Fix-forward below).

Putting the old bytes back at a higher version would mean re-signing and
re-notarizing them, because `CFBundleVersion` is inside the signature. That
waits on Apple just like a fixed build does, so the fix-forward build is the
path.

The next nightly's delta lane may list the pulled build as the newest item
below it, with a delta from it. That's harmless: every Mac on or below the
pulled build updates to the newer build.

## Canary

The canary launches the signed app and checks:

1. The app opens a visible window.
2. `cmux tab new-page` adds a tab to the app's `snapshot.get`.
3. The app's own acpmux starts a session of acpmux's test agent
   (`cmux-tui/crates/acpmux/tests/fake_agent.py`), and the agent answers a
   prompt. No account or network is needed.
4. The app is still running 60 s after launch, and no `cmux*` or `acpmux*`
   crash report was written.

It is `scripts/smoke-signed-app-cli.sh <app> --canary`, an extension of the
signed-app CLI smoke. The checks
(`scripts/cmux-next/signed-app-canary-checks.py`) use only what a Release
control socket serves, plus the readiness soak's control and acpmux clients.
Release builds have no `debug.*` methods, so the canary checks the app's model
through its Release control socket.

### Before publication (Mac writer)

`nightly.yml`'s `verify-signed-nightly` job runs the canary on the exact signed
app it then publishes, on a Blacksmith macOS runner. It never runs on a
person's Mac.

### After publication (either writer)

`nightly-next-canary.yml` runs from main every 15 minutes. For each feed build
it has not checked yet, it downloads the exact DMG the feed names and checks
the length the feed gives, the notary tickets, Gatekeeper, and that the app's
build number matches. Then it runs the canary on the app inside, using the
harness from the build's own commit (`CMUXCommit`). That covers builds from the
Linux writer and recovered builds too. A build fails only when it fails two
attempts in a row. Each build gets one verdict (an Actions cache key per
build). `workflow_dispatch -f build=N` checks a build again.

On a failure it opens or comments on one `nightly-next canary failed` issue.
With `enforce` it also dispatches `nightly-next-rollback.yml` with
`bad_build` set to that build. A pull request that changes the canary runs it
on the newest feed build with the pull request's harness, and it never pulls
anything.

### Switches

Both canaries take their mode from one resolver,
`scripts/ci/nightly_next_canary_mode.py`, so they always agree. Each run's log
prints the mode and why.

| `NIGHTLY_NEXT_CANARY` | Effect |
| --- | --- |
| `report` | Both canaries run. A failure is an annotation and an issue; the build publishes and stays on the feed. |
| `enforce` | A pre-publication failure (two attempts) fails `verify-signed-nightly`, so `publish-nightly` publishes nothing. A post-publication failure pulls the build, which starts the fix-forward. |
| `off` | Skips both. |
| unset or `auto` (the default) | `report` until `NIGHTLY_NEXT_CANARY_ENFORCE_AFTER`, then `enforce`, if the report week was clean (below). |
| anything else | Fails the run: a typo never skips or enforces silently. |

The auto flip: `NIGHTLY_NEXT_CANARY_ENFORCE_AFTER` is an ISO date or time in
UTC, or `never`. Unset, it is the script's `DEFAULT_ENFORCE_AFTER`
(2026-10-27 16:00 UTC, one week of report mode). From that time on, auto
enforces only when the post-publication canary failed no build in the 7 days
before it, read from the `nightly-next canary failed` issue. A failure in
that week keeps auto in report until someone triages it and sets
`enforce`, or moves the date. The week is fixed, so the decision never flaps.
If the issue can't be read, the run stays in report and says so.

```bash
gh variable set NIGHTLY_NEXT_CANARY -R manaflow-ai/cmux --body enforce   # enforce now
gh variable set NIGHTLY_NEXT_CANARY -R manaflow-ai/cmux --body report    # never flip
gh variable set NIGHTLY_NEXT_CANARY_ENFORCE_AFTER -R manaflow-ai/cmux --body 2026-11-03   # move the flip
gh variable delete NIGHTLY_NEXT_CANARY -R manaflow-ai/cmux               # back to auto
```

### Release rings: Dev before Nightly

The app's Update Channel setting picks a ring, and each ring accepts its own
`sparkle:channel` tag and every slower ring's (`UpdateRing.swift`): Dev
accepts `cmux-next-dev` and `cmux-next`, Nightly and every build from before
rings accept only `cmux-next`. Sparkle never offers an item whose tag the
updater does not allow.

Repository variable `NIGHTLY_NEXT_DEV_RING` (`scripts/ci/nightly_next_ring.py`):

| `NIGHTLY_NEXT_DEV_RING` | Effect |
| --- | --- |
| `on` | A new build is published as `cmux-next-dev`, so only Dev gets it. It moves to `cmux-next` once its durable verdict (`verdicts/<build>.json`, the one the train uses) is `pass`: `nightly-next-verdict.yml` retags the live feed after each verdict, and `republish-nightly-deltas` tags the earlier builds it lists from the same verdicts. A build the canary failed, skipped or never checked stays on Dev. The old cmux NIGHTLY-identity feed copies only builds already on `cmux-next`. |
| unset, `off` or anything else | Every item is `cmux-next`, as before rings. The next verdict or publication puts any Dev item back on Nightly. |

With `on`, Nightly gets nothing new while the canary passes no build, so turn
it on only while the canary passes.

```bash
gh variable set NIGHTLY_NEXT_DEV_RING -R manaflow-ai/cmux --body on
gh variable delete NIGHTLY_NEXT_DEV_RING -R manaflow-ai/cmux   # back to one ring
```

### Fix-forward

A pull stops a bad build spreading but can't move a Mac that already has it.
So every real pull (not a dry run), from the canary or by hand, runs
`nightly-next-rollback.yml`'s `fix-forward` job
(`scripts/ci/nightly_next_fix_forward.py`). It:

1. maps the first pulled build and the build the feed now serves to their
   commits (a build number is `<run id><attempt>`; that run's head);
2. names the suspect: the newest change in the first pulled build (its pull
   request, or its direct push), with its owner;
3. dispatches `nightly-next-train.yml` on `NIGHTLY_NEXT_TRAIN_REF` (default
   `feat-cmux-next`) with that change quarantined, when the train workflow is
   there and declares a `pulled_build` input. It passes only the inputs the
   train declares: `pulled_build`, `good_build`, `quarantine` (the suspect's
   commit) and `reason`;
4. otherwise opens or comments on one `nightly-next fix-forward needed` issue
   with the range, the suspect and its owner, and how to fix forward by hand.

The train (train design, PRs 1 and 2) builds the tip without the suspect;
the higher build it publishes is what moves every Mac forward.

Before publication, a recovered build (one whose notarization finished in a
later run) gets `verify-recovered-nightly-next`'s DMG check. The
post-publication canary checks it.

## How a cmux NEXT nightly is built and published

| Stage | Where | What |
| --- | --- | --- |
| Promote | main's `nightly.yml` `promote-nightly-next` | Moves branch `nightly-next` to a green `feat-cmux-next` head. `cmux-next.yml` requests it after a green push run. |
| Decide | `nightly.yml` `decide`, on the `nightly-next` push | Reads the holds below and picks the track (`nightly-next`), the `release-next` environment, and the feed. |
| Build, sign, notarize | `build-nightly-app`, `build-sign-notarize-nightly` | Release build, Developer ID signing, Apple notary. A submission still in Apple's queue leaves a recovery artifact, which a later run (`recover-nightly-next-notarization`) continues. |
| Verify | `verify-signed-nightly` and `verify-final-dmg-nightly` (no secrets; they run at the same time on two runners) | Signature, sidecar and SSH daemon contracts, the canary; the other job verifies the final DMG bytes and size budget. The tested DMG digests go to publication. |
| Publish | `publish-nightly` (`release-next`) | Uploads only the tested DMG bytes to the `nightly-next` GitHub release, reads `NIGHTLY_NEXT_WRITER` and `NIGHTLY_NEXT_HOLD` live, runs `nightly-next-guard.py` on every appcast and R2 key, then writes `appcast-arm64.xml` to R2 bucket `cmux-nightly-next` and moves the `nightly-next` tag. |
| Deltas | `generate-nightly-deltas` | Adds a delta from the previous build and rewrites the feed, unless the live feed already serves a different build. |
| Old identity | `publish-nightly-identity-legacy` | Re-signs the build as cmux NIGHTLY for installs from before cmux NEXT (`NIGHTLY_NEXT_LEGACY_FEED_BASE`). |

`NIGHTLY_NEXT_WRITER=linux` moves building and publishing to cmuxterm-hq's
`nightly-next-linux.yml`, which uses the same bucket and guard. A pull works
the same way for either writer. The pre-publication canary runs only in the
Mac pipeline.

## Holds

| Variable | Meaning |
| --- | --- |
| `NIGHTLY_NEXT_WRITER` | Which pipeline publishes nightly-next: `mac` (this repo's `nightly.yml`), `linux` (cmuxterm-hq) or `none` (stop the line). Read at `decide` and again right before the first write. Never delete it: then both pipelines refuse. |
| `NIGHTLY_NEXT_HOLD` | `1` stops the Mac pipeline before building and again at publication. It was added after the 2026-10-10 launch SIGTRAP, and is transition-week only (until 2026-10-23), when `NIGHTLY_NEXT_WRITER` replaces it. Keep it at `0`. |
| `NIGHTLY_NEXT_NOTARY_PAUSED` | `1` stops any nightly-next build that carries the browser-data import before notarization (cx-f58x: Apple status 7000). While `NIGHTLY_NEXT_BROWSER_DATA_IMPORT` is `compiled-out`, builds compile the import out and still notarize and publish. |
| `NIGHTLY_NEXT_SUBMISSIONS_PAUSED` | `1` stops every nightly-next notary submission while Apple's queue is stuck. A continuation run can still publish a build Apple has already accepted. |
| `CMUX_NEXT_PRODUCTION_HOLD` | Not part of the nightly. It holds the cmux-api production deploy (`backend.yml` `promote-gates`). |
