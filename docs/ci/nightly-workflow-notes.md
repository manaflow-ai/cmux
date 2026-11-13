# nightly.yml notes

Long comments moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit
(tests/test_ci_workflow_file_size.py). Each note's line in the workflow reads `# Why: docs/ci/nightly-workflow-notes.md#note-N`.

## note-1

build-sign-notarize-nightly, the notarize step's timeout:

Main and RC wait at most 40m (usually a few minutes). Published nightly-next waits 20m: an Accepted build is stapled and published by this run, and one still in Apple's queue is handed to a later nightly-next run through the recovery artifact below, which publishes the newest Accepted build. Nightly-next runs one at a time, so a longer wait held every newer build behind one stalled submission (submission 5912557e stayed In Progress for over 90m on 2026-10-14). The helper submitted before Codesign apps finishes first: at most 15m more in Apple's queue plus 20m of Gatekeeper propagation polling (notarize-computer-use-helper.sh), so the step budget covers both waits and the DMG's pending state is always written before a timeout. A helper Apple still holds after 15m is not a failure: the DMG ticket covers it, and that is checked (cx-urd.68), and a slow DMG is handed off. Outside notary tests, the DMG that ships is a second DMG built around the app stapled from the first ticket, with its own submission and the same wait (CMUX_STAPLE_APP_IN_DMG); a slow second DMG is handed off the same way (the next run continues the accepted first one).

## note-2

refresh-test-compilation-cache, its runner matrix:

Match the admission job's runner and Xcode. The cache key carries the toolchain and the build paths, so a mismatch is a miss, not a wrong hit. Pull requests are what restore this seed, so track the runner the admission job picks for `pull_request`, not the merge-queue one. On the 6 vCPU macOS 26 pool, use its 12 vCPU sibling: same image and Xcode, no pull-request queue (see seed-derived-data.yml). Nightly seeds no macOS 15 pool: no nightly job runs on macOS 15.

## note-3

publish-nightly, the Chromium runtime pack and R2 upload:

The nightly-next track writes only its own bucket prefix with its own scoped token (release-next secrets), after the guard has checked every appcast enclosure and object key. It never receives CF_R2_* . Chromium on demand: the pack the app's pin names goes up before the appcast that offers the app. A recovered build from another run has no pack artifact here, so this fails and nothing is offered. A republished build follows its source (steps.source.outputs.cef), not the switch.

## note-4

build-sign-notarize-nightly, the job's timeout:

Start the standalone Computer Use helper submission before Codesign apps so Apple's first wait overlaps useful work; finish it before the final DMG. The job budget covers both waits (see the notarize step). Sparkle delta generation runs after the full publication in a separate best-effort lane, so it cannot delay the first update users can install. A cx-f58x notary test waits up to 160 minutes for Apple (52c6c12d took over 90) because it has no recovery hand-off.

## note-5

republish-nightly-deltas, why it is its own job:

This job is separate from publish-nightly so the feed can advance first. On nightly-next its delta uploads are serialized in their own group, never publish-nightly's: GitHub replaces a group's pending job with a newly queued one, so a shared group let one run's deltas cancel another run's waiting publish. Its only feed write is a compare-and-swap on the bytes read (write-feed --same-build: only while the live feed serves this build), so a newer publish in between makes it a no-op. The classic and RC tracks replace release feeds with no compare-and-swap, so they keep publish-nightly's lock.

## note-6

build-nightly-app, the unsigned app upload's timeout and chunking:

A stalled upload once held the Mac 39 min (run 40460194731): 10 min, then one retry that replaces a partial upload. upload-artifact sends 8 MB blocks 5 at a time by default: the 413 MB app took 92-211 s (2-4.5 MB/s, a block every 3-17 s; runs 41430382728-41444184160) and the signers wait on this job's end. 32 at a time, as ci-macos.yml's product upload; same bytes.

## note-7

the signing jobs' Set up Node step:

Provide node/npm explicitly. The build/sign/notarize job can land on a self-hosted macOS runner (the iOS-CI minis match the same label) that has no npm on PATH, so `npm install --global create-dmg` failed with "npm: command not found" and turned nightly red. setup-node makes the job self-sufficient on any runner instead of assuming a preinstalled npm.
