---
name: cmux-ios
description: "Test, review and ship the cmux-next iPhone app (cmux-next-ios): fleet simulator runs, Swift suite names, the App Review gate, iPhone-only builds, TestFlight and App Store rules, localization, Rust-first logic, simulator isolation and how iOS PRs merge. Use for any change under cmux-next-ios/, Packages/iOS/ or the mobile Rust crates, or when you need to prove, review or release iOS work."
---

# cmux iOS

`cmux-next-ios/` is the iPhone app (`CmuxMobileApp`); `ios/` is the retired classic app, not changed
or installed. Read [cmux-next-ios/SECURITY.md](../../cmux-next-ios/SECURITY.md), the
parity rule in the root `CLAUDE.md` and the HIG rule in [Packages/iOS/AGENTS.md](../../Packages/iOS/AGENTS.md).
iOS is Aziz's area (`azooz2003-bit`).

## See your change first

Pick the fastest route that covers your change. The table and its numbers are in
[cmux-next-ios/CLAUDE.md](../../cmux-next-ios/CLAUDE.md), "See your change".

| Change | Route | Edit to visible |
|---|---|---|
| Any change, sent from your checkout to the always-on simulator | `scripts/ios-live/ios-live swap` (on `feat-cmux-next` since [#45435](https://github.com/manaflow-ai/cmux/pull/45435)) | about 16 s |
| Swift values, strings, colors or logic in a running DEBUG app | `ios-live swift`, Swift live code ([#45397](https://github.com/manaflow-ai/cmux/pull/45397), `scripts/live-code/ios-sim.sh` not on the branch yet) | about 2 s once it lands |
| PR evidence: tests, UI tests, benches, video | the fleet simulator step below | about 15 min |

`ios-live swap` is on `feat-cmux-next`: use it for every edit and keep the fleet step for the evidence a PR
cites. `ios-live swift` needs `scripts/live-code/ios-sim.sh` (#45397, still open); until it lands `swift`
refuses and `swap` is the live route.

## Build and test on the fleet

- Nothing builds or boots a simulator on the person's Mac. The fleet's `cmux-ci build ios` builds the classic app, not this one.
- Simulator run: `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg MODE --artifact artifacts/ios-sim/evidence.zip`. Modes: `release-build` (compile only), `build` (install, launch, screenshot), `test`, `bench`, `all`, and `pair-e2e`, `shots`, `clips`, `listperf`, `energy`, `chief-live-perf`, `chief-live-perf-baseline`, `handoff` (sent as `shots handoff=TAG`); the script's header describes each. After any mode that boots a simulator, `--arg device=iPhone,16e` (commas for spaces; an unknown type exits 3 with the runtime's iPhone types) picks the iPhone type, and `--arg reducemotion=1` turns Reduce Motion on; SUMMARY.md names the device and the read-back, and a reducemotion=1 run whose app does not report `isReduceMotionEnabled=true` exits 3. Through the fleet controller these pass only after `shots` with a real scene (`--arg shots --arg device=iPhone,16e --arg settings=-cmux-mobile-tab,settings`) until the HQ controller change for them lands; its argument pattern has no spaces or parentheses, so a name with parentheses uses its identifier form (`device=iPhone-SE-3rd-generation`).
- `test` takes more `--arg`s, comma-separated without spaces: `only=TARGET/SUITE`, `ui=SUITE`, `video` (before/after video, with a small copy for PR media), `profile` (Time Profiler, needs `ui=`). The script's header is the reference.
- Swift Testing suites: `scripts/ci/run-swift-testing-suites.sh <package>` with `--env CMUX_SWIFT_TEST_SUITES=Suite[,Suite]` ([example](../cmux-testing/references/local-vs-ci-validation.md)).
- Name only real suites of that package. `scripts/ci/swift_suite_names_precheck.py <package> <name>...` refuses a name its tests never mention, before a build that takes 11 to 58 minutes.
- A run that executed zero tests proves nothing; report how many ran.
- CmuxMobileKit's tests run in `.github/workflows/cmux-next-ios-kit.yml`. They run with no label on a PR into `feat-cmux-next` that touches the kit or a package it links, and skip a tree that already passed. The Mac-to-iPhone gate is `.github/workflows/ios-e2e.yml`: its tailnet jobs skip on PRs while the repo variable `IOS_E2E_PR_TAILNET` isn't `true`, and a dispatch runs them.
- A Mac build proves neither an iOS compile nor an install. Report Mac, simulator and iPhone results separately.

## Logic in Rust

- New logic goes in Rust: `cmux-next-ios/rust` (see its README for `cargo test`, clippy and fmt) or the `cmux-tui` crates it uses. Swift is the UI and the glue.
- Swift reaches Rust through `cmux-mobile-link-ffi` (uniffi). After an FFI change, regenerate with `cmux-next-ios/rust/scripts/build-xcframework.sh`. The kit workflow fails when `CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift` differs from what it generates.

## Strings

- Write user-facing text as `String(localized: "mobile.area.key", defaultValue: "English", bundle: .module)` in the module's `Resources/Localizable.xcstrings`.
- Give every new key all nine locales the catalogs carry: `en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`. `scripts/localization_catalog.py` doesn't scan these catalogs, so check them yourself. General rules: [cmux-localization](../cmux-localization/SKILL.md).

## Simulators

- On the fleet, each `cmux-next-ios-sim.sh` step gets its own simulator, so there's nothing to clean up.
- Outside contributors with no fleet run one simulator per task, named for the task's tag (`cmux-<tag>`).
- Pass that simulator's UDID to every `simctl` and `xcodebuild -destination id=` command, never `booted` or a device name.
- Never touch a simulator with another tag, and delete yours when the task ends.
- A hand-off build is one the person can test right away: launched, signed in and on the screen under test. An installed build that is still signed out is not done.

## App Review and App Store

- The app is iPhone only: `TARGETED_DEVICE_FAMILY: "1"` on every target in `cmux-next-ios/project.yml`. Don't add iPad.
- `.github/workflows/ios-review-gate.yml` runs `cmux-next-ios/scripts/app_review_gate.py` and the reviewer-path UI tests. It answers "would Apple accept this build?" ([APP-REVIEW-GATE.md](../../cmux-next-ios/AppStoreReview/APP-REVIEW-GATE.md)).
- A PR into `feat-cmux-next` skips the gate unless it is labeled `full-ci`; the push after the merge runs it. A push or a `full-ci` PR fails only on a blocker that isn't in `known-blockers.json`. A fix removes its entry, and a PR that adds an entry is itself a blocker.
- Every past rejection keeps a detector in `rejection-history.json`. When Apple rejects a build, add the rejection with the check that catches it.
- `.github/workflows/ios-screenshots.yml` shoots the classic `ios/` app's listing, not the cmux-next app's.
- How a person tests on their own iPhone (cmux INTERNAL, iPhone YOLO, cmux Dev, shake to report): [cmux-next-ios/TESTING-ON-YOUR-IPHONE.md](../../cmux-next-ios/TESTING-ON-YOUR-IPHONE.md). Send Leo or Aziz a PR preview with `-f yolo=PR` on `ios-internal-nightly-trigger.yml`.
- TestFlight (`cmux INTERNAL`, `dev.cmux.app.internal`) builds come from `ios-internal-nightly.yml`. `cmux-next-ios/scripts/testflight-build.sh` uploads nothing without `--upload`.
- A marketing version must be at least every version already uploaded: TestFlight orders by marketing version first, so a lower build processes but is never offered as an update.
- Submit for App Review only when a person asks. Releasing an approved build live is a separate ask.

## Merging iOS PRs

- An iOS PR merges on green CI and a review SHIP at its exact head, like any other PR. Don't hold it for Aziz and don't ping him (Leo, 2026-11-23: "do not hold. if you can argue for it strongly, then just merge it. we do not hold on people and arbitrary things and blockers than can be solved. ever."; "you dont have to keep telling aziz").
- land-judge wants the case in the body when a PR touches iOS UI code (`cmux-next-ios/`, `ios/`, `Packages/iOS/`, the mobile core and FFI crates). Docs (`*.md`), `cmux-next-ios/verify/`, iOS files that draw nothing (Rust, tests, Swift targets with no UI import) and screen-sharing paths need none. Each line stands alone in the PR body:
  - `Merge-case: <why it should merge now>`, at least 8 words. This is the usual route.
  - `iOS-hold: strict fix` with a one-paragraph `## ELI5` section (at most 120 words).
  - `iOS-hold: proven` with a test that fails without the change, the flow shown in a simulator or on a device, an `## Implications` section, and a SHIP review at the head confirming them.
  - A screen-sharing PR touching no screen-sharing path: `iPhone-tested: <device> at <head sha> <capture url>`.
- A change that flips a default stays with Leo.

## Lessons from reverts (2026-11-27)

Lawrence's phone recording (blank terminal tabs, a linked Mac reading offline, a stale "cmux not answering") traced back to these patterns. Each one is a rule now:

- **A default flip ships behind a flag and is tried on a real phone first.** #57025 flipped TUI scrolling for every phone and #60338 had to revert it. Land the new behavior default-off (like #61836's `CMUX_MOBILE_VIEWPORT_DATAGRAM_START`), then flip it in its own PR with `iPhone-tested:` evidence.
- **Connection, transport and presence changes carry a recorded network run.** A PR that touches `CmuxMobileTransport`, `cmux-mobile-link*`, `cmux-mobile-host`, or the presence and failure logic in `LiveCoordinator`/`AppStore` links a simulator run under network conditions (the `ios-network-conditions` profiles) that covers the path it changes: Wi-Fi with a secondary cellular route (the case #61665 changed), plus one relay-only run. The simulator has the network conditions this needs; unit tests alone don't count. A real iPhone isn't required.
- **Search open PRs before you start a lane.** `gh pr list --state open --search '<area words>'` first. #62641, #62666 and #62797 all fixed "linked Mac reads offline". When one already exists, add to it or close yours.
- **A real failure found in a PR stops the merge or gets an issue.** If a PR's own text says a red test "looks like a real regression" (#61760 on the composer typing cap), file it and link it before merging. Don't just list it under "left as is".
- **Quiet-state rules keep the way out.** Hiding connection text ("a reattach says nothing") can't hide the recovery. Every change to `quietLine`/`quietStatus` keeps a test that an outage past the quiet bound still shows Retry or Reconnect. #61760 found `offersReconnect` dead for every reattach. The terminal page's test is `HiddenWordsKeepRetryTests`; `scripts/lint-hidden-words-keep-retry.py` fails CI if it goes.
- **Stale errors clear on fresh data.** Any failure state set by a deadline (for example `serviceDown` from `armWorkspacesDeadline`) is cleared by the next successful payload, with a test (see #62661).
- **WIP and auto-checkpoint PRs never merge.** Titles starting with `WIP:` or `probe:`, or bodies with "do not merge" or "do not land", are closed or finished. Never land one as is.
