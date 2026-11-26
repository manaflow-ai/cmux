# cmux NEXT nightly: artifact verification and rollback

cmux NEXT installs update themselves from one Sparkle feed,
`https://files-next.cmux.com/nightly-next/appcast-arm64.xml`. A bad
nightly reaches every install within one update check. This page covers the
artifact and latency verdicts, the Sentry health gate, and how to pull a bad build.

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

### Health gate: real-session health pulls a build

`nightly-next-health.yml` (`scripts/ci/nightly_next_health.py`) runs every 15
minutes. For each of the feed's three newest Nightly builds (so a build
superseded within one tick still gets a verdict), it reads Sentry release health
of that build and the Nightly build before it (environment `nightly-next`, release
`cmux-next@<short version>+<build>`): sessions by status and app hang events
over the last 24 h. It writes the build's verdict to
`https://files-next.cmux.com/nightly-next/next/health/<build>.json`, beside
`verdicts/<build>.json`:

| Verdict | When |
| --- | --- |
| `fail` | 2 or more crashed sessions and crash-free sessions under 99.5% and under the previous build's; or 3 or more app hangs and more than 0.2 hangs a session and more than twice the previous build's rate. |
| `pass` | 5 sessions, or 15 minutes since its first session, and nothing failed. Judged again on every tick while the build is newest. |
| `pending` | No session yet, or too few and too young for a pass. |
| `unknown` | Sentry could not be read; the file says why. |

An `unknown` because Sentry was not read means the gate is blind: it can never
pull a build. Job `blind` then opens one issue, "nightly-next health gate is
blind: Sentry is not read" (an open one is never repeated), and ends the run
red until a tick reads Sentry again. It refuses and pulls nothing. From
2026-11-19 to 2026-11-22 every verdict was `unknown` (Sentry HTTP 403: the
`SENTRY_AUTH_TOKEN` lacks `org:read` and `event:read`) while every run stayed
green.

A `fail` of the newest build pulls it through `nightly-next-rollback.yml` with
`bad_build` and `if_newest` set to it, so a build published meanwhile is never
pulled, and the pull starts the fix-forward like any other. Detection is one
tick (at most 15 minutes after the sessions reach Sentry) plus the run.

Repository variable `NIGHTLY_NEXT_HEALTH_GATE`: `off` runs nothing; `report`
writes verdicts and pulls nothing; unset or anything else pulls a failing
build.

The rollback drill's `health` step (`gh workflow run
nightly-next-rollback-drill.yml --ref nightly-next -f step=health`, after a
`publish`) runs the gate on the drill feed with a made-up failing reading
(20 sessions, 5 crashed), so its receipt's `feed_s` times judge, verdict write,
pull and serve on the production route.

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

The scheduled verifier runs after publication. It downloads the exact
DMG named by the feed, records its SHA-256 receipt, and checks the feed length, stapler tickets,
Gatekeeper policy, build number and source commit. A scheduled or manually dispatched pass also measures the verified app on the secret-free CI Mac.

`nightly-next-canary.yml` runs from `main` every 15 minutes. Each feed build is
checked once through an Actions cache; `workflow_dispatch -f build=N` checks a
specific build. A scheduled verdict is written through
`nightly-next-verdict.yml` for the existing train and release-ring machinery,
and the build is marked checked only after that dispatch is accepted: a failed
dispatch fails the run, and the next tick checks the build again. A tick also
checks a marked build again while its `verdicts/<build>.json` is missing, so a
verdict run that fails after the dispatch is repaired too. Only the
artifact check itself decides `pass` or `fail`, and it records `fail` only for
a definite rejection (length, a missing or invalid notary ticket, Gatekeeper
`rejected`, no app, the build number). A runner, download or tooling error
(missing Apple tools, a failed `hdiutil attach`, stapler or spctl unable to
reach Apple, an spctl failure with no rejection) records no verdict, so it is
retried rather than kept as a failure.
A failed static check remains a visible failed workflow; rollback remains a
manual operator action through `nightly-next-rollback.yml`.

### Felt latency in the canary verdict

After the static checks pass, the CI Mac runs the signed DMG through
`scripts/ci/launch_tti_check.py`. It restores Home, a terminal workspace with
2,000 lines of scrollback, and a workspace with one chat. Five warm terminal relaunches each supply:

| Timing in milliseconds | Start → end | Absolute floor |
| --- | --- | --- |
| First frame | Process start → first committed window frame | 150 ms |
| Typing echo | In-app key posted → first live terminal output decoded after input was accepted | 25 ms |

The comparison uses the newest **strictly earlier** feed build whose durable
artifact verdict passed. Each metric needs all five readings from both builds,
the same measurement profile, Mac model, chip and OS build. A median increase
greater than **all three** of 25% of the baseline median, the absolute floor,
and three times the larger median absolute deviation fails that metric.
Missing keys, unmatched machines and a previous pass without measurements show
as `unavailable`. The current samples still seed a later comparison.

The canary run summary shows both medians, ranges, delta and threshold. Its
`canary-latency-<build>-<attempt>` artifact and the `latency` field in
`verdicts/<build>.json` carry the samples and the advisory verdict. A latency
`fail` emits a warning. Static verification still decides ring promotion.
Five first frames on a signed Nightly ranged from 1,182.3 to 1,328.6 ms
(median 1,224.5 ms). A five-launch large-session run ranged from 993.6 to
2,225.3 ms. Five native key-to-echo measurements on a 120-workspace Mac
build had a median of 29.7 ms and a p90 of 43.5 ms. An earlier unattended run
missed all eight echoes. Both timings warn while the scheduled canary collects
comparable samples on signed Nightlies. [Native echo measurements](https://github.com/manaflow-ai/cmux/pull/47154#issuecomment-7040903643)

### Switches

`NIGHTLY_NEXT_CANARY=off` disables the advisory artifact monitor. Any other
accepted value (`report`, `enforce`, `auto`, or unset) keeps the static monitor
enabled; the former report-week/enforce resolver is retained for compatibility
and the artifact monitor never pulls a build from the feed.

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
