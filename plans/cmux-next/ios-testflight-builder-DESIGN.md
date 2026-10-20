# cmux-next INTERNAL iOS TestFlight builder

Owner: Chief subagent "iOS internal TestFlight builder" (2026-10-20). User ask:
"a builder for cmux-next cmux INTERNAL iOS ... that just keeps on churning out
new testflight builds, similar to what we have for the mac app".

Sibling: `plans/cmux-next/nightly-builder-DESIGN.md` (the Mac nightly on cmux22).

## What exists today (2026-10-20)

- **The app.** cmux-next's iPhone app is Aziz's `cnx-ios/` (target `CnxApp`,
  App Store Connect app "cmux INTERNAL", bundle `dev.cmux.app.internal`, app id
  6791408425). It lives on `rc/cnx-ios-internal-20261019` and is not yet on
  `feat-cmux-next`; a191 is merging it. The old `ios/` app is not built.
- **Aziz's build script** `cnx-ios/scripts/testflight-build.sh` already does the
  hard parts: archive, export, entitlement and binary checks, Apple validation,
  `--internal-only`, version and build number checks against App Store Connect,
  and a split mode: `--unsigned --no-asc` archives on a host with no secrets,
  and `--from-archive` signs, validates and uploads that archive elsewhere.
- **Aziz's workflow** `cnx-ios-testflight.yml` uploads on a manual push to
  `rc/cnx-ios-internal-*` (run 39347548402 uploaded on 2026-10-20). It runs on
  Blacksmith and needs an admin push per build.
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
   only repo `manaflow-ai/cmux`, workflow `cnx-ios-internal-next.yml`, job
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
   `cnx-ios-internal-next-trigger.yml` runs on each `feat-cmux-next` push (and
   on a 2-hour schedule once the file reaches the default branch, and on
   dispatch). Its `decide` job (`ios_internal_builder.py plan`, Ubuntu, no
   secrets) dispatches the build with the head SHA when:
   - `cnx-ios/` exists at the head (until a191's merge lands, it skips);
   - the head is not the last uploaded SHA, and no build of the head is queued
     or running, and the head did not already fail (a failed head is retried
     only after the fallback interval);
   - the change since the last upload touches an iOS path: `cnx-ios/`, every
     local package `cnx-ios/CnxKit/Package.swift` names (today
     `Packages/Shared/*`, `Packages/iOS/CmuxTabsKit`, `CmuxConversation`,
     `vendor/stack-auth-swift-sdk-prerelease`), `cmux-tui/crates/cmux-wg`,
     `cmux-tui/crates/cmux-transport`, `AppIcon.icon`, and the builder files; or
   - **fallback:** the last upload is older than 12 hours and the head moved
     (any change), so non-iOS shared changes still ship twice a day.
   An unknown diff (compare failed, history missing) builds (fail open).
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
   `cnx-ios/project.yml` at the SHA; the signer refuses a version below the
   highest one in cmux INTERNAL.
8. **Internal testers only.** Every upload passes `--internal-only`
   (`testFlightInternalTestingOnly`), so the build can never go to an external
   group. "What to Test" lists the commit range since the last upload.
9. **Warm cache on cmux23.** `CNX_BUILDS_ROOT=~/cnx-ios-builds` persists between
   builds: `.cache/xcframework/<key>` (the Rust `CnxFFI.xcframework`, keyed by
   the Rust tree SHAs), `.cache/cnx-rust-target` (cargo), `.cache/spm`
   (SwiftPM checkouts). Each archive starts DerivedData empty (the script's
   choice), like the Mac nightly.

## The launchd watch loop (`ios_internal_builder.py watch`)

LaunchAgent `ai.manaflow.ios-internal-builder.watch` on cmux23, every 60 s:
runner listener alive (`ai.manaflow.ios-internal-builder.runner`, `KeepAlive`),
free disk, the newest build runs (public API, every 5 min), and
`feat-cmux-next` head. Writes
`~/Library/Application Support/ios-internal-builder/status.json` and a JSON line
per change to `~/Library/Logs/ios-internal-builder.log`. Alerts: `runner-down`,
`disk-low`, `build-failed`. It prunes runner `_diag` logs older than 7 days and
build outputs older than 3 days; it never deletes `.cache`.

```bash
ssh cmux23 'python3 ~/ios-internal-builder/ios_internal_builder.py status'
```

## Fallback

- A dispatch of `cnx-ios-internal-next.yml` with `runner=macos-26` archives on
  GitHub-hosted macOS instead of cmux23.
- Aziz's manual lane (`rc/cnx-ios-internal-*` push) keeps working; both use
  timestamp build numbers, so they interleave without collisions.

## Operations

- Move the builder's workflow forward (admin): `git push origin
  <feat-cmux-next sha>:refs/heads/rc/cnx-ios-builder` (fast-forward only).
- Pause: set repo variable `IOS_INTERNAL_HOLD=1`; the trigger then dispatches
  nothing.

## Not done (follow-ups)

- The Mac nightly and this builder use separate minis; neither waits on the
  other.
- The archive job uploads the `.xcarchive` as an Actions artifact (about
  0.3 GB per build, kept 3 days).
