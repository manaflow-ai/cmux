# cmux NEXT nightly: artifact verification and rollback

cmux NEXT installs update themselves from one Sparkle feed,
`https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml`. A bad
nightly reaches every install within one update check. This page covers the
advisory static verifier and the manual command that takes a bad build off
that feed.

## Pull a bad build

```bash
gh workflow run nightly-next-rollback.yml -R manaflow-ai/cmux --ref nightly-next \
  -f reason="New Tab is blank on launch"
```

This takes the newest build off the feed. The feed then serves the build
before it, whose signed DMG is still on the `nightly-next` release. A pull
always has one: every publication keeps the live feed's newest earlier build
beside the new one, so the feed holds at least two builds that passed the
publish gate (`write-feed` in `scripts/ci/publish-nightly-next-r2.py`), and the
release asset prune never deletes the two newest builds
(`ROLLBACK_FLOOR` in `scripts/prune_nightly_release_assets.py`). The run
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

## Artifact verification

The scheduled verifier is static and post-publication. It downloads the exact
DMG named by the feed, records its SHA-256 receipt, and checks the feed length, stapler tickets,
Gatekeeper policy, and build number. It does not launch the app, invoke the
bundled CLI, or mutate the feed. Runtime behavior belongs to the path-routed
daemon/app integration tests.

`nightly-next-canary.yml` runs from `main` every 15 minutes. Each feed build is
checked once through an Actions cache; `workflow_dispatch -f build=N` checks a
specific build. A scheduled pass is written through
`nightly-next-verdict.yml` for the existing train and release-ring machinery.
A failed static check remains a visible failed workflow; rollback remains a
manual operator action through `nightly-next-rollback.yml`.

### Switches

`NIGHTLY_NEXT_CANARY=off` disables the advisory artifact monitor. Any other
accepted value (`report`, `enforce`, `auto`, or unset) keeps the static monitor
enabled; the former report-week/enforce resolver is retained for compatibility
and no longer launches code or pulls a build from the feed.

### Release rings: Dev before Nightly

The app's Update Channel setting picks a ring, and each ring accepts its own
`sparkle:channel` tag and every slower ring's (`UpdateRing.swift`): Dev
accepts `cmux-next-dev` and `cmux-next`, Nightly and every build from before
rings accept only `cmux-next`. Sparkle never offers an item whose tag the
updater does not allow.

Repository variable `NIGHTLY_NEXT_DEV_RING` (`scripts/ci/nightly_next_ring.py`):

| `NIGHTLY_NEXT_DEV_RING` | Effect |
| --- | --- |
| `on` | A new build is published as `cmux-next-dev`, so only Dev gets it. It moves to `cmux-next` once its durable verdict (`verdicts/<build>.json`, the one the train uses) is `pass`: `nightly-next-verdict.yml` retags the live feed after each verdict, and `republish-nightly-deltas` tags the earlier builds it lists from the same verdicts. A build the artifact verifier failed, skipped or never checked stays on Dev. The old cmux NIGHTLY-identity feed copies only builds already on `cmux-next`. |
| unset, `off` or anything else | Every item is `cmux-next`, as before rings. The next verdict or publication puts any Dev item back on Nightly. |

With `on`, Nightly gets nothing new while the artifact verifier passes no build, so turn
it on only while the verifier passes.

```bash
gh variable set NIGHTLY_NEXT_DEV_RING -R manaflow-ai/cmux --body on
gh variable delete NIGHTLY_NEXT_DEV_RING -R manaflow-ai/cmux   # back to one ring
```

### Fix-forward

A pull stops a bad build spreading but can't move a Mac that already has it.
So every real pull (not a dry run), made by an operator, runs
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
later run) gets `verify-recovered-nightly-next`'s static DMG check. The
post-publication artifact verifier checks it.

## How a cmux NEXT nightly is built and published

| Stage | Where | What |
| --- | --- | --- |
| Promote | main's `nightly.yml` `promote-nightly-next` | Moves branch `nightly-next` to a green `feat-cmux-next` head. `cmux-next.yml` requests it after a green push run. |
| Decide | `nightly.yml` `decide`, on the `nightly-next` push | Reads the holds below and picks the track (`nightly-next`), the `release-next` environment, and the feed. |
| Build, sign, notarize | `build-nightly-app`, `build-sign-notarize-nightly` | Release build, Developer ID signing, Apple notary. A submission still in Apple's queue leaves a recovery artifact, which a later run (`recover-nightly-next-notarization`) continues. |
| Verify | `verify-signed-nightly` and `verify-final-dmg-nightly` (no secrets; they run at the same time on two runners) | Signature, sidecar and SSH daemon contracts; the other job statically verifies the final DMG bytes and size budget. The verified DMG digests go to publication. |
| Publish | `publish-nightly` (`release-next`) | Uploads only the tested DMG bytes to the `nightly-next` GitHub release, reads `NIGHTLY_NEXT_WRITER` live, runs `nightly-next-guard.py` on every appcast and R2 key, then writes `appcast-arm64.xml` to R2 bucket `cmux-nightly-next` and moves the `nightly-next` tag. |
| Deltas | `generate-nightly-deltas` | Adds a delta from the previous build and rewrites the feed, unless the live feed already serves a different build. |
| Old identity | `publish-nightly-identity-legacy` | Re-signs the build as cmux NIGHTLY for installs from before cmux NEXT (`NIGHTLY_NEXT_LEGACY_FEED_BASE`). |

`NIGHTLY_NEXT_WRITER=linux` moves building and publishing to cmuxterm-hq's
`nightly-next-linux.yml`, which uses the same bucket and guard. A pull works
the same way for either writer. Static artifact verification runs in the
Mac pipeline.

## Holds

| Variable | Meaning |
| --- | --- |
| `NIGHTLY_NEXT_WRITER` | Which pipeline publishes nightly-next: `mac` (this repo's `nightly.yml`), `linux` (cmuxterm-hq) or `none` (stop the line). Read at `decide` and again right before the first write. Unset means `mac`, so only the Mac pipeline publishes then; an empty or unreadable value refuses. |
| `NIGHTLY_NEXT_NOTARY_PAUSED` | `1` stops any nightly-next build that carries the browser-data import before notarization (cx-f58x: Apple status 7000). While `NIGHTLY_NEXT_BROWSER_DATA_IMPORT` is `compiled-out`, builds compile the import out and still notarize and publish. |
| `NIGHTLY_NEXT_SUBMISSIONS_PAUSED` | `1` stops every nightly-next notary submission while Apple's queue is stuck. A continuation run can still publish a build Apple has already accepted. |
| `CMUX_NEXT_PRODUCTION_HOLD` | Not part of the nightly. It holds the cmux-api production deploy (`backend.yml` `promote-gates`). |
