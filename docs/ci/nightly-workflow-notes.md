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

## note-8

the ranged artifact downloads on the signing Mac (`(parallel)` steps):

download-artifact reads an artifact's blob over one stream: 7m06s for the prepared app, 8m20s for publish-nightly's variants and 4m20s for the dSYMs (run 43300596948), 5m57s for the deltas job's DMG (run 43318988406), each while the job held the whole signing Mac. The `(parallel)` step reads it first through scripts/ci/download-run-artifact.py, in parallel ranges checked against the artifact's sha256 digest; the download-artifact step after it is the fallback. Each has its own timeout-minutes, so a range trickling under the stall bound cannot outlast the job, which would cancel it and skip the fallback (Codex review of #42332). The sign job takes the signing control's copy of the script first, because an unsigned resume builds an older tree. publish-nightly has actions: read so github.token can list the run's artifacts. The gh-based signing-inputs step keeps the job's timeout: its gh calls wait through rate limits (tests/test_gh_budget_wait.py).

## note-9

build-nightly-inputs (the job):

The web bundles and the third-party notices of a cmux-next nightly, built on Linux beside build-nightly-app instead of on its serial path (0.7 to 2.7 min each on the Mac). Neither needs macOS: the bundles are bun and node output, and the notices come from `cargo tree --target <apple triple>` and the Cargo.lock files. It starts with build-nightly-app, from the same resolved build commit, and uploads the bundles first: the Mac installs them right before xcodebuild, after its own checkout, helper starts and Chromium fetch. build-nightly-app takes each hand-off only when it matches its own checkout (nightly_inputs.py) and otherwise builds it itself, so it never waits on this job and a failure here costs only the time it would have saved. No secrets: it uploads two artifacts that the same run reads.

## note-10

build-nightly-app, Mark the kept Release DerivedData built (dedicated nightly-next builder):

cmux-next ships THIRD_PARTY_LICENSES.md for exactly what this nightly bundles: the daemon, app host and Cloud server come from this tree (pin-cmux-tui.sh tree mode), so the notices do too, with exact closures from `cargo tree`. build-nightly-inputs generates them on Linux beside this job; they are taken when generated at this commit, else generated here as before. The Release build copied the committed file; bundle-notices replaces that copy with this tree's. The sign job verifies the bundle against scripts/cmux-next/notices/bundle-map.json. The dedicated builder's next build may build on this DerivedData only after this one finished (nightly_build_state.py); a build that failed or was cancelled leaves it unmarked, so the next one starts clean.

## note-11

pick-nightly-sign-runner, owned:

An owned label (glaeda-...) or empty: the verify jobs then take the nightly build runner. They read it only while `attempt` is the run's own attempt (a re-run of failed jobs that keeps this job takes `alternate`). Outside attempt 1 of a push (the rescue's workflow_run watch) it stands only once the owned-pool-watch marker is uploaded, as pick-nightly-build-runner's does. The all-nightly reservation is the first owned choice for the secret-free verify and DMG-image jobs. It is deliberately an exact capability check: an unset, stale or foreign value falls through to the normal owned picker. Release-pool signing jobs consume sign_owned instead and keep their existing keychain and claim contract.

## note-12

sign-release-notes (the job):

Keep one open issue per failed publication boundary. A stale channel tag leaves the assets, release metadata, and feeds available, so the incident must say that explicitly instead of claiming installs stopped updating. R114 changelog (cmux-next track only): signed release notes for the in-app changelog. The content-signing environment (main, feat-cmux-next, nightly-next) holds only the Ed25519 content key; this job never sees the Sparkle key or R2 credentials. publish-release-notes uploads the result with release-next's scoped R2 token after the appcasts are live. !cancelled(): an ordinary publication skips recover-nightly-next-notarization, and GitHub skips a job with no status check below any skipped job (cx-urd.28).

## note-13

build-nightly-app, Set up Bun (cmux-next web bundles):

The cmux-next web bundles (agent pane, pages, Activity, webviews app) are built from this commit's sources, never taken from a committed copy (cx-vn5). build-nightly-inputs builds them on Linux beside this job with the same --force build; they are installed here, right before the Release build, only when their source key is this checkout's (nightly_inputs.py). Otherwise, or when that job has not uploaded them yet, this step builds them as before: it never waits. Nothing earlier reads them: optchat-chief compiles in the committed inspector page (build-web-bundles.sh only checks that page in-tree).

## note-14

publish-nightly, Read the Dev ring switch live:

Last check before the first write to the release or the feed. On nightly-next, NIGHTLY_NEXT_WRITER read live must be mac or unset: none and linux stand down; anything else, empty or unreadable refuses. A recovered build is checked again against the live feed: it must contain NIGHTLY_LEGACY_REQUIRED_COMMITS and descend from the commit the NEXT feed serves. A refusal publishes nothing and is not a failure. NIGHTLY_NEXT_DEV_RING read live with the same token (vars.* is the run's start-time snapshot, and a re-run keeps it): scripts/ci/nightly_next_dev_ring.sh.

## note-15

nightly-next-one, Read whether the kept Zig package cache is complete / Install compilation dependencies:

The Mac keeps ~/.cache/zig between jobs. "Cache Zig packages" restored 647 MB over it in 69-81 s on every run (runs 43390156751, 43395323737), so the one job skips the restore once a source archive of the same key completed with that cache: "Build the cmux-next source archive" runs `zig build --fetch=all` for Ghostty and ghostty-next into it, and "Mark the kept Zig package cache complete" then writes the key (scripts/ci/nightly-steps/zig-cache-kept.sh). Skipping a restore removes no package; a package missing since then is seeded from our mirror by zig-fetch-all.sh, as on any cache miss. The one job's "Install compilation dependencies" (scripts/ci/nightly-steps/one-job-compile-deps.sh) installs ghostty-next's Zig only when "Install Zig" has not already published CMUX_VT_ZIG (20 s per run).

## note-16

resolve-nightly-cmux-tui-client, Leave the build slot to a newer nightly-next push:

A loop retry (nightly_next_loop_retry) always leaves the slot when nightly-next moved past its commit: the newer push's run waits in the same group and builds the head (run 43395323737 waited 19 min behind retry 43395284047 of the older c31b2b678, dispatched 18 s before the push). It runs before any build job starts, so no started build is left. A push run leaves it only with vars.NIGHTLY_NEXT_SUPERSEDE_SKIP == '1'. tests/test_nightly_next_single_loop.py.

## note-17

nightly-next-one, Start the third-party notices / Finish the third-party notices:

The notices read no build output (git fetches of the pinned crates' sources, cargo tree): 95-134 s after the Release build in runs 43390156751 and 43395323737. The one job starts them after cargo is installed (scripts/ci/nightly-steps/app-third-party-notices.sh start), writing outside the checkout into the hand-off the notices step takes ($RUNNER_TEMP/nightly-inputs/notices, nightly_inputs.py install-notices), and joins them before that step. A failed background run packs no hand-off: the notices step then generates them itself, as before. tests/test_nightly_background_steps.py.

## note-18

nightly-next-one (the job):

nightly-next on one Mac, end to end (Leo, 2026-11-12: "Why isn't it just like the single machine does the thing end to end?"). With vars.NIGHTLY_NEXT_ONE_JOB=on, decide sets one_job and the split jobs skip: this one job compiles warm, prepares, signs, notarizes, verifies and writes the feed in one workspace, with the split jobs' own steps (YAML aliases, or a copy where the one job differs: note-15) and no artifact between them. tests/test_nightly_next_one_job.py.

## note-19

verify-final-dmg-nightly, Chief thread structure:

Leo, 2026-11-10, on a nightly whose Chief panel was an avatar column beside grey cards: "Where's the spec for that? Where's the iMessage". The same app, launched again from a fresh home: Chief and Home opened, their accessibility tree checked against tests/ui-structure/chief-thread.json (scripts/ci/nightly-steps/chief-thread-gate.sh; the publication tooling checkout adds tests/ui-structure for its spec, checker and accessibility dumper). A broken thread fails this job, so publish-nightly publishes none of this build; cannot-run never holds it. The step shares the launch smoke's condition through the `&final-arm64` anchor. tests/ui-structure/test_thread_structure.py tests the checker.
