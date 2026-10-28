# Ship a cmux NEXT stable release in stages

Use this page for every cmux NEXT stable release, after the release workflow has published it
(`/release`, [skills/cmux-release](../../skills/cmux-release/SKILL.md)). It covers the staged
rollout, its crash-free gate per stage, a halt, a pull, kill switches and rollback. Nightly builds
have their own page: [nightly-next canary and rollback](../ci/nightly-next-canary.md).

## How a stage works

A stable install reads `https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml`
every 15 minutes. An appcast item can carry `<cmux:rolloutPercent>P</cmux:rolloutPercent>`. A
scheduled check takes the build only on P % of installs: each install has a random seed, and each
build puts it in one of 10,000 buckets (`CmuxUpdater` `StagedRollout`). A higher P keeps every install
that already had the build. `0` halts. An item with no element reaches every install. A value that
is not a number from 0 through 100 holds the build.

A check that the person starts (Check for Updates) is never held, the same as Sparkle's own phased
rollout. To stop those installs too, pull the build (below). cmux's own reads of the feed (the update
circle, the update sheet, and the swap of a waiting update for a newer one) follow the same stage, so
an install outside it is not shown the build.

The stage applies to the newest item. If a feed lists an older item for everyone and a newer item at
a stage, an install outside the stage stays where it is until the newer item reaches it; Sparkle does
not fall back to the older item. The stable feed lists one item, so this does not apply to it.

Only builds that contain `StagedRollout` read the element. An install on an older build (classic
cmux, or cmux NEXT from before the staged-rollout change) takes the item at its next check, whatever
P says.

## The stages and their gates

| Stage | Bake time | Sessions at least | Crash-free sessions at least | Drop below the previous release at most |
| --- | --- | --- | --- | --- |
| 1 % | 24 h | 300 | 99.5 % | 0.1 points |
| 5 % | 24 h | 1,500 | 99.7 % | 0.1 points |
| 20 % | 24 h | 5,000 | 99.8 % | 0.1 points |
| 50 % | 24 h | 10,000 | 99.8 % | 0.1 points |
| 100 % | - | - | - | - |

The numbers are in `scripts/cmux-next/release/stage-rollout.py` (`STAGES`, `BAKE_HOURS`, `GATES`).
The gate reads Sentry release health for the release `cmux-next@<version>+<build>` in environment
`release-next`, from the time the stage started. Also read the hang and lag-spike numbers of
`scripts/cmux-next/stability-health.py --env release-next` before each step; the tool does not gate
on them.

## Start the rollout at 1 %

Before you push the tag, set the repository variable that makes the release workflow publish the
item at 1 %:

```bash
gh variable set CMUX_STABLE_ROLLOUT_START_PERCENT -R manaflow-ai/cmux --body 1
```

release.yml's "Generate Sparkle appcast" step then writes `<cmux:rolloutPercent>1` into the new item
before anything uploads the feed, so no scheduled check ever sees the build at 100 %. Without the
variable the item has no element and reaches every install at once (the behavior before staged
rollouts); then set the stage by hand at once, as below.

Every later step edits the feed of the release. The stable release publishes one feed,
`appcast.xml` (also copied to `https://files.cmux.com/stable/appcast.xml`). If a release also has
thin feeds (`appcast-arm64.xml`, `appcast-x86_64.xml`), pass every one of them to each command.

```bash
TAG=v1.2.0 BUILD=300   # the tag and its CFBundleVersion
ROLLOUT="$CMUX_CHECKOUT/scripts/cmux-next/release/stage-rollout.py"
mkdir -p /tmp/rollout-$TAG && cd /tmp/rollout-$TAG
gh release download "$TAG" -R manaflow-ai/cmux --pattern appcast.xml --clobber
python3 "$ROLLOUT" set appcast.xml --build "$BUILD" --percent 1            # prints the plan
python3 "$ROLLOUT" set appcast.xml --build "$BUILD" --percent 1 --write
gh release upload "$TAG" -R manaflow-ai/cmux appcast.xml --clobber
```

After each upload, also put the same `appcast.xml` at `stable/appcast.xml` in R2 bucket
`cmux-binaries` with `scripts/ci/upload-r2-object.py`, as release.yml's "Upload release appcast to
R2" step does.

`show` prints the stage each file holds:

```bash
python3 "$ROLLOUT" show appcast.xml --build "$BUILD"
```

## Move to the next stage

```bash
SENTRY_AUTH_TOKEN=... python3 "$ROLLOUT" advance appcast.xml --build "$BUILD" \
  --release "cmux-next@1.2.0+$BUILD" --baseline "cmux-next@1.1.0+250" --write
gh release upload "$TAG" -R manaflow-ai/cmux appcast.xml --clobber
```

`advance` exits 1 and writes nothing when the stage has not baked or its gate fails; it prints what
missed. Exit 2 is a bad argument or feed, exit 3 a Sentry API error. Without `--write` it prints the
plan. `--force-bake` skips only the bake time, never the gate. `advance` refuses a halted (0 %) or
hand-set stage; restart with `set --percent 1` and let it bake. To check a gate on its own:
`stage-rollout.py gate --release cmux-next@1.2.0+300 --since 2026-11-02T12:00:00Z --stage 5`.

## Halt

A gate fails, or a report comes in: set the stage to 0 and upload the feeds. Scheduled checks stop
taking the build within one check (15 minutes). Installs that already have it keep it.

```bash
python3 "$ROLLOUT" set appcast.xml --build "$BUILD" --percent 0 --write
gh release upload "$TAG" -R manaflow-ai/cmux appcast.xml --clobber
```

## Pull the build

A halt still lets a person's own check install the build. To stop every new install, make the
previous release the latest one again: `releases/latest/download/appcast.xml` then serves that
release's feed, which does not list the bad build.

```bash
gh release edit v1.1.0 -R manaflow-ai/cmux --latest
```

Also put the previous release's `appcast.xml` back at `https://files.cmux.com/stable/appcast.xml`
(R2 bucket `cmux-binaries`, key `stable/appcast.xml`) with `scripts/ci/upload-r2-object.py`, as
release.yml's "Upload release appcast to R2" step does. Sparkle never moves an install down, so a
Mac already on the bad build keeps it until a higher build ships. Fix forward: a patch release with
a higher build number.

## Turn off one subsystem (kill switch)

A remote kill switch is a feature of kind `killSwitch` or `perfPath` in
`schemas/features/features.d`, turned off in the signed flags document with
`scripts/features/publish-flags.py --cohort default --off NAME --reason TEXT`.

**A remote kill switch does not reach a stable app yet** (pro-audit 19). The app fetches no flags
document in production: its composition root gives the updater no flags receiver and builds the
feature list with no remote values. The bundled daemon reads only the nightly document's
`DisabledFeatures`, on every channel. Until that is wired, turning a subsystem off on stable takes a
patch release with that feature's `release` default off, or the managed policy `DisabledFeatures` for
a managed fleet.

## Roll a Mac back

On a Mac with the bad build, the person runs **Roll Back to Previous Version…** in the command
palette. The app keeps the build it replaced (`updates.keepPreviousVersions`, default 1, an APFS
clone) and swaps it back, then stops offering the build it left. It refuses when the kept build
cannot read a store the daemons hold, or when the kept bundle is not signed by the same team, so a
rollback never drops data that an older build cannot read. Where the CLI reaches the app's control
socket, `cmux app call updates.rollback '{"check": true}'` reports the decision without rolling back.

## Record

For each stage, keep in the release issue: the stage, the time, the `advance` output (sessions and
crash-free rate) and the upload. A halt or pull also names the report or the Sentry issue that
caused it.
