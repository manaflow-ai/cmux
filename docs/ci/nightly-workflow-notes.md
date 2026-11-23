# nightly.yml notes

Long comments moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit
(tests/test_ci_workflow_file_size.py). Each note's line in the workflow reads `# Why: docs/ci/nightly-workflow-notes.md#note-N`.

## note-1

build-sign-notarize-nightly, the notarize step's timeout:

Main and RC wait at most 40m (usually a few minutes). Published nightly-next waits 20m: an Accepted build is stapled and published by this run, and one still in Apple's queue is handed to a later nightly-next run through the recovery artifact below, which publishes the newest Accepted build. Nightly-next runs one at a time, so a longer wait held every newer build behind one stalled submission (submission 5912557e stayed In Progress for over 90m on 2026-10-14). The step budget is far above the wait, so the DMG's pending state is always written before a timeout, and a slow DMG is handed off. Outside notary tests, the DMG that ships is a second DMG built around the app stapled from the first ticket, with its own submission and the same wait (CMUX_STAPLE_APP_IN_DMG); a slow second DMG is handed off the same way (the next run continues the accepted first one).

## note-2

refresh-test-compilation-cache, its runner matrix:

Match the admission job's runner and Xcode. The cache key carries the toolchain and the build paths, so a mismatch is a miss, not a wrong hit. Pull requests are what restore this seed, so track the runner the admission job picks for `pull_request`, not the merge-queue one. On the 6 vCPU macOS 26 pool, use its 12 vCPU sibling: same image and Xcode, no pull-request queue (see seed-derived-data.yml). Nightly seeds no macOS 15 pool: no nightly job runs on macOS 15.

## note-3

publish-nightly, the Chromium runtime pack and R2 upload:

The nightly-next track writes only its own bucket prefix with its own scoped token (release-next secrets), after the guard has checked every appcast enclosure and object key. It never receives CF_R2_* . Chromium on demand: the pack the app's pin names goes up before the appcast that offers the app. A recovered build from another run has no pack artifact here, so this fails and nothing is offered. A republished build follows its source (steps.source.outputs.cef), not the switch.

## note-4

build-sign-notarize-nightly, the job's timeout:

Sparkle delta generation runs after the full publication in a separate best-effort lane, so it cannot delay the first update users can install. A cx-f58x notary test waits up to 160 minutes for Apple (52c6c12d took over 90) because it has no recovery hand-off.

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

A loop retry (nightly_next_loop_retry) always leaves the slot when nightly-next moved past its commit: the newer push's run waits in the same group and builds the head (run 43395323737 waited 19 min behind retry 43395284047 of the older c31b2b678, dispatched 18 s before the push). It runs before any build job starts, so no started build is left. A push run leaves a moved head at once only with vars.NIGHTLY_NEXT_SUPERSEDE_SKIP == '1'.

Latest wins at the slot: a stale run waits here for a newer promotion when feat-cmux-next has moved past its commit. A stale run is a loop retry (it rebuilds a commit that just failed) or a push run that sat 5 min or more in the group behind another build. It waits up to 6 min (YIELD_MINUTES). Main's rolling rule counts a run in this step as no holder (LEAVE_SLOT_STEP in scripts/ci/nightly_next_rolling.py), so the finished build's tick or the 5-minute cron promotes the newest buildable commit, and this run leaves to it. If nothing is promoted in that time, it builds its own commit. A fresh push run never waits. Push run 43558081148 of a22a4eb1 (2026-11-14) waited 23 min behind another build, then built the old head beside 20 newer commits and failed. Its retry 43560964857 built a22a4eb1 again: 60.9 min from landing to the feed. tests/test_nightly_next_single_loop.py.

Latest wins at nightly-next-one's slot too (2026-11-14). With the one job on, resolve's check runs before the slot (nightly-next-one-push), and a push run P2(C) may then wait ~30 min there while D and E land; admitted, it built C. So nightly-next-one's first step after the whole-Mac claim, "Leave the push slot to a newer nightly-next push", runs the same script with IN_SLOT=1: a run that waited YIELD_STALE_MINUTES or more at the slot (since its resolve job ended), while feat-cmux-next has commits after its own, waits up to YIELD_MINUTES for the tick's promotion. Main's tick counts a run in that step as building nothing (nightly_next_rolling.LEAVE_ONE_STEP), so it promotes the newest buildable commit; that push's nightly-next-one queues behind this running one (no pending job is replaced), and this run leaves: it sets LEFT_SLOT=1 in the job's env, every later build and publish step has `!env.LEFT_SLOT` in its `if` (cleanup steps still run), the job ends green with output left=true, and published-build and attest-nightly-remote-daemon skip. Nothing is cancelled. A run admitted at once builds at once. tests/test_nightly_next_push_slot_at_build.py.

No wait at nightly-next-one's slot (2026-11-19). The signing Mac waited in that step for the tick's next pass: of 83.0 Mac-minutes held by 29 nightly-next runs that published no feed, 63.5 were in "Leave the push slot to a newer nightly-next push" (run 44014825385: 24.7 min, partly gh_budget_wait.sh's hour-long rate-limit wait). Leo: "if i wait for the nightly then i might as well just update to the thing". Now a stale run at the slot whose head has not moved asks main's tick at once (gh workflow run nightly-next-tick.yml, bounded, fail-open) and leaves with pending=true (output left_pending). wake-nightly-next-tick, on a nightly-only mini, then dispatches the loop's retry of that commit (scripts/ci/nightly-steps/slot-left-retry.sh) unless nightly-next already moved; the retry's resolve step leaves to the promotion, or builds the commit after YIELD_MINUTES, off the signing Mac. Main's tick counts that retry of its own head as no holder while a newer commit waits (nightly_next_rolling.retry_of). The loop's last retry (2) asks the tick and builds at once. Every gh call in the step is bounded (GH_CALL_SECONDS, 30 s) and never waits through a rate limit (GH_BUDGET_WAIT_MAX_SECONDS=0); an unanswered read keeps the slot and builds. tests/test_nightly_next_push_slot_at_build.py.

## note-17

nightly-next-one, Start the third-party notices / Finish the third-party notices:

The notices read no build output (git fetches of the pinned crates' sources, cargo tree): 95-134 s after the Release build in runs 43390156751 and 43395323737. The one job starts them after cargo is installed (scripts/ci/nightly-steps/app-third-party-notices.sh start), writing outside the checkout into the hand-off the notices step takes ($RUNNER_TEMP/nightly-inputs/notices, nightly_inputs.py install-notices), and joins them before that step. A failed background run packs no hand-off: the notices step then generates them itself, as before. tests/test_nightly_background_steps.py.

## note-18

nightly-next-one (the job):

nightly-next on one Mac, end to end (Leo, 2026-11-12: "Why isn't it just like the single machine does the thing end to end?"). With vars.NIGHTLY_NEXT_ONE_JOB=on, decide sets one_job and the split jobs skip: this one job compiles warm, prepares, signs, notarizes, verifies and writes the feed in one workspace, with the split jobs' own steps (YAML aliases, or a copy where the one job differs: note-15) and no artifact between them. tests/test_nightly_next_one_job.py.

## note-19

The workflow-level concurrency group and nightly-next's push slot:

Each lane has its own group and a newer run replaces only a pending one; an in-flight nightly always finishes. nightly-next has its own group: sharing main's (#18150) let every main push replace the pending nightly-next run (run 37579667979), so it starved. Scheduled and manual cache seeds use different groups, so a tick never cancels a manual refresh. A nightly-next push shares one group (nightly-build-nightly-next-push): one run builds and the newest pushed head waits, and GitHub replaces a waiting run (never a started one) with a newer push, so only the newest head is built and signed. Leo, 2026-11-05, when 25 run-scoped nightlies queued behind the one signer: "why do multiple merges even build the f***ing nightlies anyway?". Other nightly-next runs (dispatches) stay run-scoped, except the loop's own retry of a failed run (nightly_next_loop_retry), which takes the push group's pending place like a push; the release/feed writers keep their own groups below. A loop run holds the group through publish and the GitHub release (the next run's decide reads its body and tag), then dispatch-published-in sends the deltas, notes, reel and PR comments to a run-scoped run (nightly_next_post_publish). Holding the group through that whole tail made the newest head wait about 79 min per cycle: 172 of 198 push runs were replaced while pending in 26 h (2026-11-07). With the one job on (vars.NIGHTLY_NEXT_ONE_JOB), the push slot is nightly-next-one's own group (nightly-next-one-push) and the run is run-scoped here: the GitHub release, dSYMs and the dispatch after the feed held this group 5-10 min more, and the next landing waited 22.1 and 23.9 min from landing to run created (holders 43581845419 and 43605506661). The next run's notes start from the live feed's published source, which nightly-next-one writes (publish-prepare-release-notes.sh), not from that tail's release body. A publishing nightly-next push builds only (decide's pipeline): its dispatch-nightly-next-sign hands the unsigned app to a sign run (nightly_next_sign_stage) in nightly-build-nightly-next-sign, so build N+1 runs while N signs and the publish period is the slower stage, not the whole run. That group works like the push group: one sign run at a time, and a newer dispatch replaces only a pending one, so the newest build signs next.

The push slot at nightly-next-one (2026-11-14). With the one job on (vars.NIGHTLY_NEXT_ONE_JOB), a push run and the loop's retry are run-scoped at the workflow level, and nightly-next-one takes its own group, nightly-next-one-push (cancel-in-progress false): one loop run builds and publishes at a time and the newest waits. The workflow-level push group held a loop run through its whole post-feed tail (published-build, keep-published-dsyms, publish-nightly-next-github, dispatch-published-in), 5-10 min after the feed write, and the next landing waited behind it: holder 43581845419 (feed 10:09:17Z, ended 10:19:08Z) delayed 43584856901, holder 43605506661 (feed 14:57:49Z, ended 15:02:43Z) delayed 43608103300, 22.1 and 23.9 min from landing to run created. With the one job off the split jobs keep the workflow-level push group, as before, and so do they with it on while vars.NIGHTLY_NEXT_SUBMISSIONS_PAUSED or vars.NIGHTLY_NEXT_NOTARY_PAUSED is 1: decide then leaves one_job false and builds the split jobs, which nightly-next-one-push does not serialize. The group reads exactly the variables decide's one_job reads (tests/test_nightly_next_push_slot_at_build.py reads oneJob from decide's script).

Nothing is cancelled: GitHub replaces only a pending job of the group, and main's tick promotes nothing while a loop run's nightly-next-one is queued, pending or building, or while a loop run with no job yet is pending (nightly_next_feed_watch.run_holds_group on main), so at most one loop run ever waits at the slot. Its tail holds nothing. wake-nightly-next-tick asks main's tick as soon as nightly-next-one ends, since the tick's workflow_run trigger fires only when the whole run ends.

The next run's decide can now read the release body and tag before the previous run's tail rewrote them, so the notes and PR-comment span start from the live feed's newest cmux:sourceCommit instead (publish-prepare-release-notes.sh, nightly_version.py published-source): nightly-next-one writes the feed before it ends, and the feed's compare-and-swap only moves to a descendant source. nightly-next-one outputs that commit as published_sha, which the published-build record prefers over decide's. tests/test_nightly_next_push_slot_at_build.py.

## note-20

build-nightly-app, Checkout build ref (warm nightly-next builder):

A kept workspace: fetch only new objects (actions/checkout's depth-1 fetch resent the tree, 118 s in run 39440747033) and keep the three Rust target dirs.

actions/checkout's own URL, no .git: on a mismatch a later checkout on this slot deletes the workspace.

A slot whose git store was deleted fetched all of history from GitHub (jobs 132417366047, 132487716521: about 2.6 GiB in 267 s and 278 s); glaeda's job-completed hook linked it to the mini's mirror only after the job. Borrow a healthy mirror here, before the fetch, so it sends only what the mirror lacks. The checks and the record are glaeda's (mirror_identity, same_mirror in scripts/glaeda-cmux-runner-hook): the record comes first, since a slot that lists the mirror without one is wiped at job-started; no birth time (it then matches on the inode, and job-completed adds it).

The negotiation tells the server what the workspace has only through refs; a detached HEAD alone makes it send the whole tree.

Each try has its own limit and git's low-speed abort, and a failed try's partial pack and locks are removed before the next (scripts/ci/git_fetch_retry.py). Run 40466772597 hung here for 62 min, then died with "early EOF". Measured on owned minis (25 runs, 2026-10-26/27): 0-6 s warm, 194 s at most cold, so 600 s per try, 3 tries. The kept clone holds an earlier build, so the helper comes from the workflow commit, into RUNNER_TEMP where the checkout and clean below cannot remove it: from the local objects, else raw.githubusercontent.com (bounded), else the clone's own copy.

No helper: one try, with git's own low-speed abort, so a stall still ends in about a minute.

One runner can have the builder and the signing label, so the signer or a deltas job may have left this clone sparse; checkout and reset then keep its files out of the tree (run 42833135477: "Select Xcode", .xcode-version missing). Take the setting out of both config files (a full actions/checkout leaves .git/config's `true` in force) and the skip-worktree bits out of the index. Not `git sparse-checkout disable`: it first writes the old tree.

Go writes its module cache read-only; a clone whose acpmux build ran before tailnet-go.sh set -modcacherw still has one, and git clean cannot remove it (run 42940891027: "failed to remove .build/go-path/pkg/mod/...: Permission denied").

A hosted runner starts with clean submodules; drop what earlier runs left.

Each fetch adds a pack and gc.auto is off: fold them past 40.

## note-21

publish-nightly-next-github (the job):

cmux NEXT's GitHub release copy, after the feed went live from R2 (publish-nightly), in one job nothing waits on. It uploads the build's immutable assets first: no concurrency group, so no run's uploads are ever replaced, and they may wait out GitHub's rate limits as long as they need. Then, only while this build is the live feed's newest, it writes the release's mutable state: the rolling DMG name, the feed copy, the body with the cmux-published-sha marker and the nightly-next tag. Each of those writes runs still-newest just before it writes, inside the release names lease (one writer at a time across runs: on nightly-next it runs in the loop run, and in run-scoped manual runs that may overlap it), so no older build moves them back. It stays in the loop run, holding the push group: the next run's decide reads the body and tag (published_sha), so the dispatched tail (cross_run) never runs it. They were a job of their own until run 42018687632: its second whole-Mac claim, set-up and variant download let the deltas job take cmux15 first, and the names moved 40 min after the feed. It holds the release App key, so it runs on an ephemeral GitHub-hosted VM in release-next, as publish-release-notes already does with the same key, never on a mini a pull request job can reach. Leo, 2026-11-08, on moving it off the signer: "no. if this is still a good idea, we can still do it." (the override of Lawrence's owned-minis rule for this one job, tests/test_nightly_owned_minis_only.HOSTED_LOOP_JOBS). On cmux15 it held the whole signing Mac 289-406 s a build after queueing 79-412 s behind keep-published-dsyms (runs 42547726872, 42552327203, 42555458535, 42563930397); hosted it starts beside keep-published-dsyms.

## note-22

published-build and the PR comments:

Each PR in this nightly-next build gets a "Shipped in" line, in one comment that release.yml also writes for stable releases (scripts/ci/published_in_comments.py). The span is the one the release body's "PRs in this build" list uses (the previous published commit to this build's), first-parent, so main's PRs arriving through a sync merge are not claimed. No secrets; a comment failure never fails the nightly. The published build that the jobs after the feed describe (scripts/ci/nightly_published_build.py). It runs in the run that published, passing that run's own jobs through, and in a dispatched tail run (nightly_next_post_publish), reading the checked source run's record (cross_run). run_tail says where the rest of the tail (deltas, notes, reel, PR comments) runs: false only in a nightly-next loop run (a push or the loop's retry), which keeps the GitHub release and dSYMs and then dispatches the rest (dispatch-published-in), so the push group's newest head starts once the release is written (Leo, 2026-11-06: "when it finishes, it starts another one, like the latest one at that present moment"). Main, RC and run-scoped manual nightly-next runs hold no push group and keep the whole tail in-run.


## note-23

build-nightly-ghostty-cli-helper's runner:

The helper builds with the Zig the Ghostty submodule pins (0.16.0) and links against the macOS 26 SDK: the universal build and its lipo check pass on an owned macOS 26 mini (Xcode 26.6, SDK 26.5). The old Zig 0.15.2 link failure that pinned this job to macOS 15 is gone. Zig on Linux has no macOS SDK. The all-nightly reservation admits fresh and reused helpers; otherwise only a reused helper (resolve-nightly-ghostty-cli-helper) leaves this job on Linux, for the source archive. A fresh helper takes an owned pool (main's trusted pool on attempt 1 of a push or schedule; nightly-next: pick-nightly-build-runner's `helper` pick made for this attempt, an idle owned Mac but never the dedicated builder, else its moving Blacksmith label); a re-run of failed jobs keeps the older pick and takes Blacksmith macOS 26, so a rescue re-run leaves a busy mini. Not CI_NIGHTLY_NEXT_BUILD_RUNNER: it holds every attempt on its label, and a trusted NEXT runner admits only build-nightly-app. Never a hosted Mac past the fork branch, never macOS 15. glaeda sizes it light at its measured cores.

## note-24

retry-nightly-next, the loop's retry:

The nightly-next loop's retry (Leo, 2026-11-06: one nightly at a time, the newest head next; a failed run is retried at the newest commit, not at its own). When this run built and failed to publish, and nightly-next still points at its commit, it asks for one more run of the push group: GitHub keeps that group's one pending place for the newest arrival, so a push that lands meanwhile takes it instead and nothing waits beside the loop. The retry builds again from scratch: a dispatch runs at the head when it is dispatched, so a push that lands between the check and the dispatch (and loses its pending place to the retry) is still the commit the retry builds; resuming this run's unsigned app would publish the older commit for it. At most two retries in a row. In the pipeline a push run that handed its build to a sign run (dispatch-nightly-next-sign) retries nothing; the sign run retries a failed sign or publish the same way, and a sign run a newer published build superseded retries nothing.

## note-25

keep-published-dsyms:

A published nightly-next build's dSYMs, kept on R2. Nothing needs it and it continues on error, so it never delays a publication. The dSYMs come from the run that compiled the published binary (its build number is that run's id and attempt). A rerun repairs a missing object; an existing one (exit 75 from --write-once) counts as kept. A loop run keeps it in the run that published, as the GitHub release; a sign run (the record's sign_stage) leaves it to its tail run, so the sign group frees once the feed and the GitHub release are written: in sign run 43282010692 it held the group 6.3 min past the release, 4.3 of them waiting for the whole signing Mac. The release stays in the sign run: the next decide reads its body and tag (published_sha, the span of that build's notes and PR comments). It takes the trusted signing runner (the whole Mac, after the signing is done), never GitHub-hosted Ubuntu, whose queue (39 min for the oldest job on 2026-11-08) held the next push run for as long.

## note-26

nightly-next-one, Ask main's nightly-next tick at notarization (and the job's actions: write):

The next run sets up while this one notarizes and publishes. Push runs 43634178843, 43642011551 and 43644053566 waited 19.6-26.8 min from landing to run created while the previous nightly-next-one held nightly-next-one-push, then 4.7 min more after it ended (21:38:45 to 21:43:25) for wake-nightly-next-tick, the tick, the promotion, runner-preflight, decide and resolve-nightly-cmux-tui-client. This step asks main's tick right before the notarize step. Main's rolling rule (nightly_next_rolling.FINISH_STEPS, finishing) counts a run from this step on as finishing while it is the only open loop run, and promotes ONE run: its set-up runs now, and its nightly-next-one waits pending on nightly-next-one-push until this job ends. Once that run is open the holder holds again, so no second promotion replaces the pending job (nothing is cancelled), and the feed watch's starvation guard still counts this run as building (run_holds_group is unchanged). wake-nightly-next-tick still asks at the end, for a landing that came later.

github.token, as wake-nightly-next-tick's (the release App holds no actions permission), so the job needs actions: write. The ask never waits through a rate limit (GH_BUDGET_WAIT_MAX_SECONDS 0, `timeout 60`) and continues on error: a missed ask costs at most the tick's 5-minute cron, never the notarization.

The post-feed uploads (variant artifacts, DMG digests, SSH daemon assets, source archive, dSYMs) and the cleanup (Rust target bound, helper stop, keychain, wipe) stay in this job: the next nightly-next-one reuses this kept workspace (final-dmg/, tested/, remote-daemon-assets/, build-universal's dSYMs), this Mac's build.keychain and its Rust target dirs, so a job after the slot would upload, delete or prune what the next build writes, and on the same whole-Mac claim it would only queue behind it. tests/test_nightly_next_push_slot_at_build.py.

## note-27

dispatch-nightly-next-sign:

The push run's half of the nightly-next pipeline (decide's pipeline): once the unsigned app and what the resume restores beside it are uploaded, ask for this build's sign run. It is the unsigned resume of this run (resume-unsigned-nightly.py, which reads this live run only as a sign stage) in the sign group, so this run and the push group end here and the next build starts while this one signs. GitHub keeps one pending run in the sign group and replaces it with a newer dispatch: nothing started is cancelled, and a build that waited behind a newer one is never signed. A dispatch refused for the API rate limit waits for the reset and tries again (gh_budget_wait.sh; a refused request did nothing, so this never starts two runs): run 42726398544's dispatch failed on "API rate limit exceeded for installation" and nothing published for two hours. Any other failure fails this job, retry-nightly-next retries the build and report-nightly-failure lists it.

## note-28

sentry-dsyms-nightly:

nightly-next's dSYMs to Sentry, off the build's path (Sentry held it 10.8 and 19.7 min in runs 41471126151, 41466468306). Nothing needs it; it continues on error. It runs with the rest of the tail (run_tail: on nightly-next the dispatched tail run), outside the push group: in the loop run it held the push group until its hosted queue (39 min for the oldest job on 2026-11-08) and its upload were done, and in a pipelined push run (decide's pipeline) it held the group after dispatch-nightly-next-sign. It stays on GitHub-hosted Ubuntu (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS): the Sentry token keeps it off the nightly mini's shared light runners, and on the trusted signing runner its 11-20 min upload would hold the whole Mac while the next run builds and signs there. The dSYMs come from the run that compiled the published binary, as keep-published-dsyms finds them.

## note-30

refresh-test-compilation-cache (the scheduled cold DerivedData seeder):

This seeder runs on our nightly-only minis, never Blacksmith (a fork on hosted macos-26). The schedule skips this seeder while owned pools serve pull requests (CI_PR_POOL_OWNED is 1): admission then runs on owned minis that keep their own DerivedData, and seed-derived-data.yml still seeds the Blacksmith admission pools on main pushes that change app-host build inputs. Those incremental chains then get no six-hourly cold reset; a seed_only dispatch still writes one on demand. Writes the cold DerivedData seed that ci-macos.yml compile admission adopts. It no longer restores, bounds or saves the Debug compilation cache: admission stopped restoring it (the app target missed on every file; see tests/test_ci_test_compilation_cache_seed.sh), so nothing read it. The build's CAS stays local to the run. Scheduled, not per push: a build per merge would take macOS slots from the pull request queue.


## note-29

runner-preflight:

Fails the run in minutes when a label its jobs would wait on has no online runner, instead of every job sitting queued for hours (2026-11-10: CI_NIGHTLY_MINI named cmux-lawrence-2-light, whose runners went offline at 00:45Z; the nightly sat queued for 3+ h). It takes decide's own route, so it never waits longer than decide would, and in one-mini mode it stays on vars.CI_NIGHTLY_MINI with the rest of the run (never split across Macs); there a dead mini holds it like every other job. It was on GitHub-hosted Ubuntu until 2026-11-18, when the org-wide hosted queue held it 1h25m+ (run 44207617943) and with it every nightly, while the nightly Macs were idle. It holds no secret and reads only vars.CI_RUNNER_STATE (scripts/ci/nightly_runner_preflight.py). It never cancels anything; an unreadable or stale census lets the run go on. A failure files the nightly's failure incident with the job's token (report-nightly-failure never runs then). hq docs/handbook/runner-var-points-at-dead-host.md.

## note-32

nightly-next-one, Upload nightly variant artifacts (2026-11-21):

The upload runs after the feed is written, but it still holds nightly-next-one-push and the whole signing Mac, so every second of it delays the next landing's build. In run 44904268153 (job 136847063748) it uploaded 571,388,812 bytes in 283 s (12:59:52 to 13:04:35Z) while run 44906071087 waited at the slot and then left it, publishing nothing. Two of the six files were the same DMG: the immutable `<prefix>-arm64-<build>.dmg` and the rolling `<prefix>-arm64.dmg`, a copy of it. No reader of this artifact uses the rolling copy. build-nightly-deltas and generate-nightly-deltas read the immutable name and the appcast. publish-nightly-next-github checks the immutable DMG against the tested digest and makes the rolling name itself (`cp`, github-names-publish-rolling-name.sh). republish-verified-nightly.py, the one reader that requires both names, takes the variant only from build-sign-notarize-nightly (its ARTIFACTS producers), never from this job. So this job leaves out the rolling copy, about 243 MB, about half the upload. The split jobs' upload (build-sign-notarize-nightly) is unchanged.

## note-33

Both cmux15 and ultra1 carry `glaeda-trusted-next-signing` on multiple runners. A single `nightly-next-one-push` group serialized both Macs; removing it without pinning the runner could send both builds to the same Mac and leave the other idle.

For a push or loop retry, `pick-nightly-next-signer` reads the runner census and active jobs. It chooses a free signer with no queued build, preferring cmux15 on a tie. If both are busy, it prefers a signer finishing its current work. `nightly-next-one` takes `nightly-next-one-push-<host>` with `cancel-in-progress: false`. Its runner pin requires both the literal signing label and that runner’s label. A failed or stale pick falls back to cmux15’s group and the signing label alone, not a guaranteed cmux15 pin. One-slot and explicit one-mini mode skip the pick and keep the legacy `nightly-next-one-push` group, so a finishing build and its queued successor cannot overlap. Non-loop dispatches keep their run-specific groups.

Main’s rolling rule defaults to one slot. Enable `NIGHTLY_NEXT_SLOTS=2` only after both changes land and existing legacy-group builds drain; likewise drain the per-host groups when switching back to one. The Macs share a publication lease: under that lease the publisher rechecks the live feed, and the conditional feed write compares build number and source ancestry before replacing it. Finishing late cannot roll the authoritative appcast back. The release mirror has its own lease and can lag the feed; the two are not an atomic write.
