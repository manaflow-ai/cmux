# cmux-next INTERNAL iOS TestFlight builder

> **Moved 2026-10-25.** All nine M6 minis (cmux16..cmux24) are reserved for the cmux Performance Lead
> (Lawrence). The INTERNAL iOS archive now runs on cmux9s (M4 Pro, runner `cmux9s-mac-mini-ios-internal`, `CI_IOS_INTERNAL_RUNNER=glaeda-runner-cmux9s-mac-mini-ios-internal`). Install with `scripts/ci/ios-internal-builder-install.sh HOST`; the old M6 runner is removed.

Owner: Chief subagent "iOS internal TestFlight builder" (2026-10-20). User ask:
"a builder for cmux-next cmux INTERNAL iOS ... that just keeps on churning out
new testflight builds, similar to what we have for the mac app".

Sibling: `plans/cmux-next/nightly-builder-DESIGN.md` (the Mac nightly on cmux22).

## What exists today (2026-10-20)

- **The app.** cmux-next's iPhone app is Aziz's `cmux-next-ios/` (target `CmuxMobileApp`,
  App Store Connect app "cmux INTERNAL", bundle `dev.cmux.app.internal`, app id
  6791408425). It lives on `rc/cnx-ios-internal-20261019` and is not yet on
  `feat-cmux-next`; a191 is merging it. The old `ios/` app is not built.
- **Aziz's build script** `cmux-next-ios/scripts/testflight-build.sh` already does the
  hard parts: archive, export, entitlement and binary checks, Apple validation,
  `--internal-only`, version and build number checks against App Store Connect,
  and a split mode: `--unsigned --no-asc` archives on a host with no secrets,
  and `--from-archive` signs, validates and uploads that archive elsewhere.
- **The retired manual workflow** `cmux-next-ios-testflight.yml` uploaded from
  `rc/cnx-ios-internal-*` in one job that also installed rolling tools, built
  branch code and held signing/upload credentials. The continuous split
  builder below replaces it; the legacy workflow was removed after the round-3
  CI security audit.
- The old `ios-testflight.yml` (main's `ios/` INTERNAL lane) is disabled.
- Signing material (`ASC_API_*`, `IOS_*`) lives only in the GitHub `release`
  environment, which admits `main`, `rc/**` and `v*`. `rc/**` is admin-only
  (ruleset "rc branches: admin only"). `feat-cmux-next` is not admitted.

## Decision

1. **Host: `cmux23`** (Apple M6, 16 GB, 141 GB free, macOS 27, Xcode 26.6,
   user `cmux`). It was a held worker: no GitHub runners, not in the cmux-ci
   controller pool, idle (load 1.1). Not cmux22: it runs the Mac nightly, and
   two Xcode builds at once on 16 GB would slow the nightly. cmux17, 18, 19 and
   24 run pool runners; cmux20 is the benchmark host; cmux21 has 58 GB free.
   The reservation is recorded in cmuxterm-hq `build-fleet/FLEET-MEMBERSHIP.md`
   and `fleet.json` (`excluded_workers`), like cmux22.
2. **One GitHub Actions runner on cmux23, used only for this job.** Name
   `cmux23-ios-internal`, labels (no default labels):
   `glaeda-runner-cmux23-ios-internal`, `glaeda-ios-internal-next`. The archive
   job asks for `glaeda-runner-cmux23-ios-internal` (repo variable
   `CI_IOS_INTERNAL_RUNNER` can move it). The admission hook
   (`ios_internal_builder.py admit`, `ACTIONS_RUNNER_HOOK_JOB_STARTED`) admits
   only repo `manaflow-ai/cmux`, workflow `ios-internal-nightly.yml`, job
   `archive`, event `workflow_dispatch`, ref `refs/heads/rc/cnx-ios-builder`,
   with at least 40 GiB free.
3. **No secret on the mini.** The mini archives with
   `testflight-build.sh --unsigned --no-asc` (warm caches, no credential). The
   archive goes to a GitHub-hosted `macos-26` job in the `release` environment
   that signs, validates and uploads with `--from-archive --upload
   --internal-only`. This is the same split as the Mac nightly: compile on the
   owned mini, sign on an ephemeral hosted runner. Copying the distribution
   certificate and the App Store Connect key to a shared fleet mini (every
   agent can ssh in as `cmux`) is not done.
4. **Trusted signer, untrusted source.** The build workflow runs only on the
   admin-only branch `rc/cnx-ios-builder`, so the `release` environment admits
   it, and its workflow file and signing script come from that frozen branch,
   not from `feat-cmux-next`. Code from a `feat-cmux-next` push runs only in the
   archive job, which has no secrets. A push to `feat-cmux-next` cannot change
   what runs with the signing key. Changing the builder means an admin
   fast-forwards `rc/cnx-ios-builder` (see "Operations").
5. **Trigger: every `feat-cmux-next` push, plus a periodic fallback.**
   `ios-internal-nightly-trigger.yml` runs on each `feat-cmux-next` push (and
   on a 2-hour schedule once the file reaches the default branch, and on
   dispatch). Its `decide` job (`ios_internal_builder.py plan`, Ubuntu, no
   secrets) dispatches the build with the head SHA when:
   - `cmux-next-ios/` exists at the head (until a191's merge lands, it skips);
   - the head is not the last uploaded SHA, and no build of the head is queued
     or running, and the head did not already fail (a failed head is retried
     only after the fallback interval);
   - the change since the last upload touches an iOS path: `cmux-next-ios/`, every
     local package `cmux-next-ios/CmuxMobileKit/Package.swift` names (today
     `Packages/Shared/*`, `Packages/iOS/CmuxTabsKit`, `CmuxConversation`,
     `vendor/stack-auth-swift-sdk-prerelease`), `cmux-tui/crates/cmux-wg`,
     `cmux-tui/crates/cmux-transport`, `AppIcon.icon`, and the builder files; or
   - **fallback:** the last upload is older than 12 hours and the head moved
     (any change), so non-iOS shared changes still ship twice a day.
   An unknown diff (compare failed, history missing) builds (fail open).
   **A failing builder holds** (cmuxterm-hq#5424: 58 failures in a row, every
   new head rebuilt, 23.2 Mac hours a day). Before any of the rules above the
   plan runs `check-tabskit-sync.sh`'s comparison on Linux (trees only); a head
   whose shared packages drift from upstream is never dispatched, because the
   archive refuses it. While the newest completed build failed: no dispatch
   while a build still runs; a head whose change since the failed SHA touches
   no iOS path waits 6 hours (one retry for an infra failure); otherwise the
   second failure in a row starts a backoff of 30 minutes after the newest
   failure, doubling per failure to 6 hours. A success resets it. A manual
   dispatch of the trigger skips the backoff, never the drift check. A held
   plan writes `BLOCKED: <why>` as an error annotation on the decide run, and
   the red builder shows in ci-dash's alerts (`ios_internal_red`, from the
   builder's newest completed run), so a hold is never silent.
   A dispatch with `workflow_dispatch` from `GITHUB_TOKEN` starts a run (the
   documented exception), so no extra credential is needed.
6. **Coalescing.** The build workflow has one concurrency group with
   `cancel-in-progress: false`: one build runs, at most one waits, and a newer
   dispatch replaces the waiting one. The newest head always builds next and no
   backlog forms.
7. **Build numbers.** `CFBundleVersion` is the 14-digit UTC timestamp at
   archive time (`yyyyMMddHHmmss`, the INTERNAL lane's scheme), moved one past
   the last dispatched build number if the clock is behind it. Builds are
   serialized by the concurrency group, so numbers only go up. The signing job
   checks the number is above the newest build in App Store Connect before it
   uploads (`testflight-build.sh`). `MARKETING_VERSION` comes from
   `cmux-next-ios/project.yml` at the SHA; the signer refuses a version below the
   highest one in cmux INTERNAL.
8. **Internal testers only.** Every upload passes `--internal-only`
   (`testFlightInternalTestingOnly`), so the build can never go to an external
   group. "What to Test" lists what changed since the last upload (below).
9. **Warm cache on cmux23.** `CMUX_MOBILE_BUILDS_ROOT=~/cmux-mobile-builds` persists between
   builds: `.cache/xcframework/<key>` (the Rust `CmuxMobileLinkFFI.xcframework`, keyed by
   the Rust tree SHAs), `.cache/cmux-mobile-rust-target` (cargo), `.cache/spm`
   (SwiftPM checkouts). Each archive starts DerivedData empty (the script's
   choice), like the Mac nightly.

## What to Test (2026-10-20)

Every upload carries a note for testers, written without a person and without
a signing secret (`scripts/ci/ios_internal_notes.py`, tests in
`tests/test_ios_internal_notes.py`).

- **Content.** The `## Changelog` lines (Added / Changed / Fixed / Removed) of the
  pull requests whose commits in BASE..SHA change the app: `cmux-next-ios/`
  (`cnx-ios/` before the rename), `AppIcon.icon/`, `cmux-wg`, `cmux-transport` and
  every local package `cmux-next-ios/CmuxMobileKit/Package.swift` names at SHA. Builder files are not app
  changes. Lines are grouped, `none` is dropped, repeats are dropped, and
  markdown, template comments and footers after the section are left out. A PR
  with no Changelog section contributes its title. A commit pushed straight to
  the branch contributes its subject under "Other changes", minus area labels
  and engineering references; test-only, CI, docs and red commits are left out.
- **PR lookup.** `associatedPullRequests` per commit and the `(#N)` in the
  subject, in batched GraphQL reads: links first (it also lists open PRs that
  branched from a commit), then the bodies of the chosen PRs. A PR merged into
  `feat-cmux-next` with that commit as its merge commit wins.
- **Shape.** The first line is `cmux-next iPhone <version>, feat-cmux-next
  <12-hex sha>. Internal testers only.`, then the range, then the groups. The
  note stays under App Store Connect's 4000 characters (UTF-16 units): items
  that do not fit become "...and N more"; no line is cut.
- **BASE.** The dispatch's `base` (the last successful builder run, from
  `plan`). When it is empty, `previous-build` reads the newest processed
  (VALID) build in cmux INTERNAL and takes the commit its note's first line
  records; the binary also carries it as `CNXSourceCommit` in Info.plist, but
  App Store Connect does not expose Info.plist. Else the newest successful run
  of this builder or of the retired `cnx-ios-testflight.yml` lane. Else the note
  says "First continuous build" and lists the last 20 lines.
- **Secrets.** `notes` runs on `ubuntu-24.04` with `contents`, `pull-requests`
  and `actions` read only, no environment, and the builder branch's script.
  `previous-build` runs only when `base` is empty and holds only the App Store
  Connect key (no certificate, no profile). `upload` downloads the note as an
  artifact and only passes it on. A failed `notes` or `previous-build` does not
  fail the run: the signer then sends the first line alone.

## The launchd watch loop (`ios_internal_builder.py watch`)

LaunchAgent `ai.manaflow.ios-internal-builder.watch` on cmux23, every 60 s:
runner listener alive (`ai.manaflow.ios-internal-builder.runner`, `KeepAlive`),
free disk, the newest build runs (public API, every 5 min), and
`feat-cmux-next` head. Writes
`~/Library/Application Support/ios-internal-builder/status.json` and a JSON line
per change to `~/Library/Logs/ios-internal-builder.log`. Alerts: `runner-down`,
`disk-low`, `build-failed`. It prunes runner `_diag` logs older than 7 days and
build outputs older than 3 days or beyond the newest 5 `*-testflight` folders. Below 60 GiB
free, and only while no build runs (no `Runner.Worker`, `testflight-build.sh` or
`build-xcframework.sh` process), it also trims caches, moving each into `.trash` first: the pre-rename `~/cnx-ios-builds`,
every `.work` folder (failed builds' source and DerivedData), xcframeworks beyond the
newest 3 keys, and the cargo target (rebuilt only on an xcframework cache miss).
SwiftPM checkouts stay. `~/cmux-mobile-builds` on cmux23 belongs to this builder only. The admission hook does the same trim once before it refuses
an archive job for disk, then checks again. (cmux23 fell to 39.9 GiB free on
2026-10-22 and refused every archive job; the old root and failed builds' `.work`
had no cleanup.)

```bash
ssh cmux23 'python3 ~/ios-internal-builder/ios_internal_builder.py status'
```

## Fallback

- Unset repo variable `CI_IOS_INTERNAL_RUNNER` and the archive runs on
  GitHub-hosted `macos-26` instead of cmux23 (no warm cache).
- Manual retries dispatch `ios-internal-nightly.yml` on the admin-only
  `rc/cnx-ios-builder` ref. There is no second branch-controlled signing lane;
  timestamp build numbers remain monotonic within the serialized builder.

## Operations

- Move the builder's workflow forward (admin): `git push origin
  <feat-cmux-next sha>:refs/heads/rc/cnx-ios-builder` (fast-forward only;
  the pre-push web lint covers other agents' files in that range, so set
  `CMUX_WEB_LINT_SKIP_REASON`). The push also registers the dispatch-only
  workflow with GitHub, which refuses to dispatch a workflow it never ran.
- After `scripts/ci/ios_internal_builder.py` changes, copy it to the mini:
  `scp scripts/ci/ios_internal_builder.py cmux23:ios-internal-builder/` (the
  admission hook and watch loop run that copy; a stale copy refuses jobs).
- The trigger does not retry a head that failed for 12 hours, and backs off
  while builds keep failing (rule 5); to build at once, dispatch the trigger
  (skips the backoff) or `ios-internal-nightly.yml` on `rc/cnx-ios-builder` with `sha`.
- Pause: set repo variable `IOS_INTERNAL_HOLD=1`; the trigger then dispatches
  nothing.
- Production naming (2026-10-20): the app moved from `cnx-ios/` to `cmux-next-ios/`
  (archive `CmuxMobileApp.xcarchive`, artifacts `cmux-mobile-internal-*`, build root
  `~/cmux-mobile-builds`). The signing job runs `rc/cnx-ios-builder`'s own copy of the
  workflow and of `testflight-build.sh`, so until an admin fast-forwards that branch to a
  feat-cmux-next commit with the rename, the trigger skips with "has no
  cmux-next-ios/scripts/testflight-build.sh" and nothing uploads (the last upload stays
  installable). Admin step, once the rename is on feat-cmux-next:
  `git push origin <feat-cmux-next sha>:refs/heads/rc/cnx-ios-builder`. The branch keeps
  its name. After it, copy `scripts/ci/ios_internal_builder.py` to the mini as above.

## Not done (follow-ups)

- The admission hook does not check the iOS platform is installed. cmux23 had
  none at first (`iOS 26.5 is not installed`); it was added with
  `xcodebuild -downloadPlatform iOS`. An Xcode update needs the same step.
- A build Apple rejects in processing holds the signer for 45 min
  (`asc builds wait`).

- The Mac nightly and this builder use separate minis; neither waits on the
  other.
- The archive job uploads the `.xcarchive` as an Actions artifact (about
  0.3 GB per build, kept 3 days).

## App Store review rules (2026-10-20, after ITMS-90626)

Apple rejected cmux INTERNAL builds in processing (after upload) because an App
Intent description said "transcribed on this iPhone". `scripts/cmux-next/check-app-store-rules.py`
now finds that class of error before upload. It checks App Intents text in every language
(Apple trademarks: iPhone, iPad, Mac, Siri, Apple, iCloud, ...), App Shortcut phrases without the
app name, missing or empty purpose strings for APIs the binary uses (ITMS-90683), usage
descriptions that name one Apple device, unknown `UIBackgroundModes`, and iPad orientations
(ITMS-90474). It runs in four places:

1. the pre-push gate (`--source`, on pushes that change `cmux-next-ios/`);
2. the cmux-next checks job (`--source` plus `tests/test_app_store_rules.py`);
3. this builder's archive job, on the source and on the built app, before the archive goes to the
   signer;
4. `testflight-build.sh` `check_app`, before it signs, exports or uploads.
