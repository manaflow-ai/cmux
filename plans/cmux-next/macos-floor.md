# cmux-next minimum macOS

Status: proposal (2026-10-09). Not landed. Today cmux-next requires macOS 26
(`Packages/macOS/CmuxNext/Package.swift` `.macOS(.v26)`, the `cmux-next` Xcode
target `MACOSX_DEPLOYMENT_TARGET = 26.0`, and `MACOSX_DEPLOYMENT_TARGET=26.0` in
`scripts/cmux-next/build-app-ffi.sh`, `build-rd-ffi.sh`,
`build-layout-reducer-ffi.sh`, `embed-cef.sh`, `bundle-server-helper.sh`).
Classic cmux requires macOS 14.

## Recommendation

RECOMMENDATION_PLACEHOLDER

## Who is on each version

Classic cmux, PostHog `cmux_daily_active`, distinct users, last 30 days
(2026-09-09 to 2026-10-09, 206,425 users). Classic cmux needs macOS 14, so
macOS 13 users are invisible here.

| macOS | users | share |
| --- | --- | --- |
| 27 | 38,632 | 18.7% |
| 26 | 140,079 | 67.9% |
| 15 | 22,844 | 11.1% |
| 14 | 4,180 | 2.0% |

Homebrew install events by OS version
(https://formulae.brew.sh/api/analytics/os-version/30d.json and `365d.json`,
read 2026-10-09; install events, not unique users; CI machines inflate old
versions). Share kept at each floor:

| floor | 30 days | 365 days |
| --- | --- | --- |
| 15 | 92.9% | 83.3% |
| 14 | 96.7% | 94.6% |
| 13 | 98.3% | 96.9% |
| 12 | 99.7% | 99.3% |
| 11 | 99.95% | 99.7% |

Homebrew 30 days: macOS 13 is 1.57% and macOS 14 is 3.82%. Applied to the cmux
population (macOS 14 = 2.0%), macOS 13 would add about 0.8% of users.
TelemetryDeck (https://telemetrydeck.com/survey/apple/macOS/versions/) shows
macOS 26 at about 77% and macOS 15 at about 10% of app users at the end of
September 2026; it does not publish 14 and older.

## Hard limits (components we ship)

| component | minimum macOS | source |
| --- | --- | --- |
| CEF 154 / Chromium 154 (`plans/cmux-next/browser.md`) | 13 | Chromium dropped macOS 11 at M139 and macOS 12 at M151 (commit 3a7cdb6be7 "Make Chromium require macOS 13", 2026-06-08); `build/config/mac/mac_sdk.gni` `mac_deployment_target = "13.0"`; https://support.google.com/chrome/answer/95346 |
| GhosttyNextKit (Zig 0.15/0.16 build) | 13 | Zig 0.16 release notes: macOS 13.0 minimum; upstream Ghostty `src/build/Config.zig` osVersionMin 13 |
| Xcode 27 deployment range | 12 | https://developer.apple.com/support/xcode/ (Xcode 26: 11 to 26) |
| Sparkle 2.10 | 12 (2.9 binary in tree: arm64 minos 11.0) | Sparkle release notes |
| sentry-cocoa 9.25+ | 12 (9.x before 9.25: 10.14) | sentry-cocoa CHANGELOG |
| manaflow-ai/iroh-ffi (CmuxIrxTransport) | 14 in its Package.swift | `.build/checkouts/iroh-ffi/Package.swift`; the Rust code itself has no reason for 14; a fork change |
| Rust daemon, cmux-app-ffi, rd-ffi | 11 (aarch64), 10.12 (x86_64) | rustc platform support; our scripts pin 26.0 and only need the env var changed |
| Observation (`@Observable`, `withObservationTracking`) | 14 | Apple docs |
| `Observations` async sequence (Swift 6.2) | 26 | Apple docs |
| `Mutex`, `Atomic` (Synchronization) | 15 | Apple docs |
| `SpeechAnalyzer` / `SpeechTranscriber` | 26 (`SFSpeechRecognizer` 10.15 is the fallback) | Apple docs |
| `NSGlassEffectView`, `.glassEffect` (Liquid Glass) | 26 | Apple docs |
| `WKWebsiteDataStore(forIdentifier:)` | 14 | Apple docs |
| `WKWebView.isInspectable` | 13.3 | Apple docs |

Result: macOS 11 and 12 are impossible while we ship current Chromium and a
Zig-built Ghostty. A floor of 12 would need a frozen Chromium 150 (no security
updates) and a Ghostty built with an old Zig. macOS 13 is the hard floor.

## Code measurement

MEASUREMENT_PLACEHOLDER

## Static inventory (Sources, 3,866 Swift files, 346k lines, feat-cmux-next a541ca5b5e8)

| API family | needs | files | uses | main modules |
| --- | --- | --- | --- | --- |
| `@Observable` | 14 | 123 | 130 | App 42, Browser 13, Onboarding 10, Daemon 10 |
| `@Bindable` | 14 | 7 | 8 | |
| `Observations { }` | 26 | 111 | 156 | App 97 |
| `Mutex` / `import Synchronization` | 15 | 118 | 173 | App 10, Daemon 8, AgentPane 4, spread |
| `Atomic<` | 15 | 14 | 34 | |
| `SpeechAnalyzer` family | 26 | 12 | 49 | Dictation 11 |
| Liquid Glass | 26 | 7 | 22 | Design 5, Onboarding 1, Tabs 1 |
| `WKWebsiteDataStore(forIdentifier:)` | 14 | 2 | 3 | |
| `#available` checks today | | 1 | 1 | |

There is no `ObservableObject` anywhere. The code assumes macOS 26 everywhere
and has one `#available` check.

## Fallback strategy per family

- `Observations { }` (26): one package-level `ObservationStream` helper built on
  `withObservationTracking` (14+) that re-arms on each change and yields on the
  main actor. Same call shape, so the 156 uses change mechanically. On 26 it can
  forward to `Observations`. Works on 14 and 15, not on 13.
- `Mutex` / `Atomic` (15): one small `Mutex<Value>` in CmuxNextWakeups (or a
  shared base module) with the same `withLock` API over
  `OSAllocatedUnfairLock` (13+); `Atomic` over `swift-atomics` (already resolved
  through swift-nio) or the same lock. Mechanical; drop `import Synchronization`.
- Liquid Glass (26): CmuxNextDesign already owns the glass surfaces. Add one
  material switch: `NSGlassEffectView` on 26, `NSVisualEffectView` with the same
  corner radius and tint on older systems. Respect Reduce Transparency on both.
- Speech (26): `SpeechAnalyzer` on 26, `SFSpeechRecognizer` (already present as
  the fallback in 5 files) on older systems.
- `@Observable` on 13: no Observation framework. Options: (a) a back-port
  (`swift-perception`, MIT: `@Perceptible`, `withPerceptionTracking`, and
  `WithPerceptionTracking { }` wrapped around every SwiftUI body that reads a
  model), or (b) rewrite to `ObservableObject`/Combine. Both touch about 130
  models and every SwiftUI view that reads them (145 files import SwiftUI);
  a missed wrapper is a silent no-update bug, so (a) also needs its debug
  runtime checker on in CI. This is the single largest cost of a macOS 13 floor.
- Binaries: rebuild GhosttyNextKit, CCmuxAppFFI, rd-ffi and the server helper
  with the new `MACOSX_DEPLOYMENT_TARGET`; re-release iroh-ffi with the lower
  platform; pin sentry-cocoa and Sparkle versions whose floor fits.
- SwiftUI and AppKit APIs newer than the floor: see the measured counts above;
  each gets `if #available` with an older equivalent or is removed.

## Testing on each supported version

- Fleet: every fleet Mac and the AWS EC2 Macs run macOS 26.x
  (`build-fleet/mini-fleet.json`, 2026-10-09). No fleet host runs 13, 14 or 15.
- GitHub-hosted: macos-13 retired 2025-12-04; macos-14 is unsupported from
  2026-11-02; macos-15 and macos-26 remain
  (https://github.com/actions/runner-images/issues/13518).
- Apple-silicon VMs (Virtualization.framework, Tart): macOS 12+ guests from an
  IPSW, two macOS guests per host at once, paravirtualized Metal for 13+ guests.
  Proposal: one fleet Mac keeps a Tart image per supported major (13 if chosen,
  14, 15, 26). A `cmux-ci` step class `os-smoke` boots each image, installs the
  release-candidate build, launches it with `CMUX_NEXT_NO_ACTIVATE=1`, waits for
  the first window and the socket, opens one terminal and one CEF tab, takes a
  window snapshot, and quits. One run per release candidate and per nightly.
  Cost: about 2 agent-days to build the images and the step, about 60 GB disk
  per image.
- macos-15 hosted runners can also run the launch smoke as a second source.

## Cost per floor

COST_PLACEHOLDER
