---
name: cmux-ios
description: "Test, review and ship the cmux-next iPhone app (cmux-next-ios): fleet simulator runs, Swift suite names, the App Review gate, iPhone-only builds, TestFlight and App Store rules, localization, Rust-first logic, simulator isolation and how iOS PRs merge. Use for any change under cmux-next-ios/, Packages/iOS/ or the mobile Rust crates, or when you need to prove, review or release iOS work."
---

# cmux iOS

`cmux-next-ios/` is the cmux-next iPhone app (`CmuxMobileApp`); `ios/` is the classic app with its own
[ios/AGENTS.md](../../ios/AGENTS.md). Read [cmux-next-ios/SECURITY.md](../../cmux-next-ios/SECURITY.md), the
parity rule in the root `CLAUDE.md` and the HIG rule in [Packages/iOS/AGENTS.md](../../Packages/iOS/AGENTS.md).
iOS is Aziz's area (`azooz2003-bit`).

## Build and test on the fleet

- Nothing builds or boots a simulator on the person's Mac. The fleet's `cmux-ci build ios` builds the classic app, not this one.
- Simulator run: `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg MODE --artifact artifacts/ios-sim/evidence.zip`. Modes: `release-build` (compile only), `build` (install, launch, screenshot), `test`, `bench`, `all`.
- `test` takes more `--arg`s, comma-separated without spaces: `only=TARGET/SUITE`, `ui=SUITE`, `video` (before/after video, with a small copy for PR media), `profile` (Time Profiler, needs `ui=`). The script's header is the reference.
- Swift Testing suites: `scripts/ci/run-swift-testing-suites.sh <package>` with `--env CMUX_SWIFT_TEST_SUITES=Suite[,Suite]` ([example](../cmux-testing/references/local-vs-ci-validation.md)).
- Name only real suites of that package. `scripts/ci/swift_suite_names_precheck.py <package> <name>...` refuses a name its tests never mention, before a build that takes 11 to 58 minutes.
- A run that executed zero tests proves nothing; report how many ran.
- CmuxMobileKit's tests run in `.github/workflows/cmux-next-ios-kit.yml`. The Mac-to-iPhone gate is `.github/workflows/ios-e2e.yml`, which runs on PRs into `feat-cmux-next`.
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
- A push or PR fails only on a blocker that isn't in `known-blockers.json`. A fix removes its entry, and a PR that adds an entry is itself a blocker.
- Every past rejection keeps a detector in `rejection-history.json`. When Apple rejects a build, add the rejection with the check that catches it.
- `.github/workflows/ios-screenshots.yml` shoots the classic `ios/` app's listing, not the cmux-next app's.
- TestFlight (`cmux INTERNAL`, `dev.cmux.app.internal`) builds come from `ios-internal-nightly.yml`. `cmux-next-ios/scripts/testflight-build.sh` uploads nothing without `--upload`.
- A marketing version must be at least every version already uploaded: TestFlight orders by marketing version first, so a lower build processes but is never offered as an update.
- Submit for App Review only when a person asks. Releasing an approved build live is a separate ask.

## Merging iOS PRs

- Agents that land PRs automatically hold a PR touching iOS code (`cmux-next-ios/`, `ios/`, `Packages/iOS/`, the mobile core and FFI crates) until Aziz approves its exact head.
- Docs (`*.md`) and `cmux-next-ios/verify/` don't hold a PR.
- A push after his approval needs a new one. The hold stops only the merge: keep testing and pushing fixes.
- When you open one, mention `@azooz2003-bit` in a PR comment so he knows it's waiting.
