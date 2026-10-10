# cmux-next minimum macOS

Status: proposal (2026-10-09). Not landed. Today cmux-next requires macOS 26
(`Packages/macOS/CmuxNext/Package.swift` `.macOS(.v26)`, the `cmux-next` Xcode
target `MACOSX_DEPLOYMENT_TARGET = 26.0`, and `MACOSX_DEPLOYMENT_TARGET=26.0` in
`scripts/cmux-next/build-app-ffi.sh`, `build-rd-ffi.sh`,
`build-layout-reducer-ffi.sh`, `embed-cef.sh`, `bundle-server-helper.sh`).
Classic cmux requires macOS 14.

## Recommendation

**Floor: macOS 14 Sonoma.** It is the floor of classic cmux, so the move to
cmux-next strands no current user. It keeps 100% of today's cmux users (macOS
14 is 2.0% of them, 4,180 of 206,425 in 30 days) and about 96.7% of the
Homebrew developer population. Cost: about 11 agent-days once, plus a VM launch
smoke per release. The work is mostly mechanical shims: `Mutex`/`Atomic`
(macOS 15), the `Observations` async sequence (macOS 26), and fallbacks for
Liquid Glass and SpeechAnalyzer (macOS 26).

**macOS 13 Ventura: no.** It adds about 0.8% of users (an estimate from the
Homebrew ratio, because classic cmux cannot see 13). The cost is about 24
agent-days, plus a permanent tax on every new view. macOS 13 has no Observation
framework, and cmux-next has about 130 `@Observable` models with roughly 900
measured or extrapolated Observation errors. Chromium will probably drop 13 in
a later release, as it dropped 12 at M151, and that would force the floor up
again. Neither GitHub nor the fleet can run 13 today.

**macOS 11 and 12: impossible.** CEF/Chromium 154 and the Zig-built Ghostty
need macOS 13.

**macOS 15 Sequoia:** about 2 agent-days cheaper than 14. It drops the 2.0% of
current cmux users who are on 14. Use 15 only if those users are acceptable to
lose.

What users on 14 and 15 do not get: the Liquid Glass look (they get a
`NSVisualEffectView` material with the same shape), on-device `SpeechAnalyzer`
dictation (they get `SFSpeechRecognizer`, which is older and of lower quality),
and a few small SwiftUI behaviors (macOS 15 table column resize, `animate`).

Strongest objection: every supported major is one more row in the test matrix.
No fleet host and, after 2026-11-02, no GitHub runner runs macOS 14. A
regression that shows only on 14 or 15 (for example a fallback material, or a
wakeup difference in the `Observations` shim) reaches users unless the VM smoke
below exists before the first release. Mitigation: build the smoke first, and
on 26 forward the shim to the native `Observations`, so that the main
population runs Apple's code.

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

Method (`scripts/measure/macos-floor.sh`, branch `feat-cmux-next-mfloor`):
set every local package to `.macOS(.v13)`, lower `iroh-ffi` in the checkout,
build CmuxNext with `-disable-availability-checking` (pass 1, so modules
exist), then re-typecheck each first-party module with checking on (pass 2) and
count unique errors. Host: cmux-lawrence-2, Xcode 27, nx-remote job
1009-180706-91a11c. Pass 1 stopped at one SwiftUI expression in
`CmuxNextHistory/HistoryPageView.swift:137`, which exceeds the solver limit
when the two-parameter `onChange` is unavailable. As a result, 49 modules
(203k of 346k lines) were measured. The script now types that closure for
measurement, but the rerun was refused: cmux-lawrence-2 now admits only GUI,
simulator or Xcode-27-only jobs. Also, `scripts/measure/` is not on the
cmux-ci allowlist yet ("script is not on the ci-step allowlist"). The 18
unmeasured modules (CmuxNextApp, Apps, AgentPane, Accounts, CodeRouter,
Remote*, BrowserHost, Mobile, Cloud and others; 143k lines) are extrapolated
from static counts of the same symbols.

Measured at floor 13 (49 modules, 1,204 unique errors):

| family | needs | errors | top symbols |
| --- | --- | --- | --- |
| Synchronization `Mutex` / `Atomic` | 15 | 703 | `withLock` 291, `Mutex.init` 99, `Mutex` 80, `Atomic` load/store/orderings about 230 |
| Observation framework | 14 | 406 | `@ObservationIgnored` 320, `@Observable` 60, `withObservationTracking` 11, `@Bindable` 4 |
| `Observations { }` async sequence | 26 | 20 | |
| Liquid Glass | 26 | 17 | `NSGlassEffectView` 10, `.glass` 5, `NSGlassEffectContainerView` 2 |
| SpeechAnalyzer family | 26 | 17 | `SpeechTranscriber`, `AnalyzerInput`, `SpeechAnalyzer`, `AssetInventory` |
| other SwiftUI/AppKit/WebKit APIs | 14 | 27 | `onChange(of:initial:)` 4, `NSApp.activate()` 3, `onKeyPress`, `CADisplayLink`, `focusEffectDisabled`, `WKWebsiteDataStore(forIdentifier:)`, `symbolEffect` |
| other APIs | 15 | 7 | table `columnResize`/`rowResize`, `NSAnimationContext.animate`, `onScrollGeometryChange` |
| other APIs | 13.3 | 5 | `WKWebView.isInspectable`, `ASAuthorizationWebBrowserPublicKeyCredentialManager`, `scrollBounceBehavior` |
| other APIs | 26 | 1 | |
| solver limit | | 1 | HistoryPageView |

Most errors are in CmuxNextControl (259), CmuxNextDaemon (202), CmuxNextBrowser
(145), CmuxNextTerminal (75), CmuxNextDesign (63), CmuxNextWakeups (57) and
CmuxNextUpdater (56).

Estimated totals for all of CmuxNext (measured plus extrapolated; the
unmeasured modules hold 403 `@ObservationIgnored`, 64 `@Observable`, 254
`withLock`, 20 `Mutex<`, 136 `Observations(`):

| floor | Observation (14) | Mutex/Atomic (15) | Observations (26) | glass + speech (26) | other APIs | total |
| --- | --- | --- | --- | --- | --- | --- |
| 13 | about 900 | about 1,100 | about 220 | about 35 | about 70 | about 2,300 |
| 14 | 0 | about 1,100 | about 220 | about 35 | about 15 | about 1,370 |
| 15 | 0 | 0 | about 220 | about 35 | about 3 | about 260 |

An error count does not measure work. All Mutex/Atomic errors go away with one
shim type that has the same API, and all `Observations` errors go away with one
helper. The Observation errors at 13 do not have a shim of that kind.

## Static inventory (Sources, 3,866 Swift files, 346k lines, feat-cmux-next a541ca5b5e8)

| API family | needs | files | uses | main modules |
| --- | --- | --- | --- | --- |
| `@Observable` | 14 | 123 | 130 | App 42, Browser 13, Onboarding 10, Daemon 10 |
| `@Bindable` | 14 | 7 | 8 | |
| `Observations { }` | 26 | 111 | 156 | App 97 |
| `Mutex` / `import Synchronization` | 15 | 118 | 173 | App 10, Daemon 8, AgentPane 4, spread |
| `Atomic<` | 15 | 14 | 34 | |
| `SpeechAnalyzer` family | 26 | 12 | 49 | Dictation 11 |
| Liquid Glass | 26 | 10 | 22 | Design 5, Onboarding 1, Tabs 1, App 1 |
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
  Proposal: one fleet Mac keeps a Tart image per supported major (14, 15,
  26; 13 only if chosen). A `cmux-ci` step class `os-smoke` boots each image, installs the
  release-candidate build, launches it with `CMUX_NEXT_NO_ACTIVATE=1`, waits for
  the first window and the socket, opens one terminal and one CEF tab, takes a
  window snapshot, and quits. One run per release candidate and per nightly.
  Cost: about 2 agent-days to build the images and the step, about 60 GB disk
  per image.
- macos-15 hosted runners can also run the launch smoke as a second source.

## Cost per floor

Agent-days, one capable agent, including review and a VM launch check:

| item | 15 | 14 | 13 |
| --- | --- | --- | --- |
| deployment-target plumbing: Package.swift, Xcode target, 5 scripts at 26.0, CEF embed `min_os`, server helper; rebuild GhosttyNextKit, CCmuxAppFFI (FFI release + pin, needs FFI-RD and PKG tokens), rd-ffi; iroh-ffi release at the lower platform | 1.5 | 1.5 | 1.5 |
| `Observations` shim over `withObservationTracking`, forwarding to native on 26; 156 call sites; wakeup-ledger tests | 2.5 | 2.5 | n/a (no Observation) |
| Liquid Glass fallback material in CmuxNextDesign + visual pass | 1 | 1 | 1 |
| SpeechAnalyzer to SFSpeechRecognizer fallback in CmuxNextDictation | 1 | 1 | 1 |
| other API gates (`#available` or older equivalents) | 0.5 | 1 | 1.5 |
| `Mutex`/`Atomic` shim (`OSAllocatedUnfairLock`, `swift-atomics`), import swap in 118 files | 0 | 1.5 | 1.5 |
| Observation back-port (`swift-perception` or ObservableObject rewrite), about 130 models, every SwiftUI view that reads them, `withObservationTracking` and `Observations` call sites, debug checker in CI | 0 | 0 | 12 |
| VM launch smoke per supported major (Tart images, `os-smoke` step) | 2 | 2 | 3 (Ventura image is not maintained) |
| buffer for unknowns in the 18 unmeasured modules | 1 | 1 | 2 |
| **total** | **about 9.5** | **about 11.5** | **about 24.5** |

A floor of 13 also adds a permanent tax: every new view and model must use the
back-port correctly, because a missed wrapper is a silent stale-UI bug.

Next steps if 14 is chosen: (1) build the VM smoke on one fleet Mac; (2) land
the shims (Mutex/Atomic, Observations) at the current 26 floor first, as
no-op refactors; (3) add the glass and speech fallbacks; (4) lower the
deployment targets and rebuild the binaries in one landing with the FFI
release and pin; (5) add a CI compile at the floor to keep it from regressing
(a CmuxNext build with `.macOS(.v14)` is the check).
