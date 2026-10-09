# C16 `platform`: app-wide services for the iOS shell

Status: landed on the lane branch, 2026-10-06, branch `feat-cmux-next-ios-c16-platform` off `feat-cmux-next-ios`.
Binding: PLAN.md (this directory, rules section 4), a1-shell.md (1.20 gaps 2, 9 to 14 and the A1
follow-ups in 2.10), ios-rewrite.md, OWNERSHIP-PRINCIPLES.md. Parity reference (read-only):
`repo/Packages/iOS` CmuxMobileCrashReporting, CmuxMobileDiagnostics, CmuxMobileToast,
CmuxMobileAnalytics, CmuxMobileBilling, What's New, demo content, keep-awake.

## 1. Scope and order

Each item is one commit, in this order: this note; crash reporting and the diagnostic log with its
export screen; the `ShellRoute` router; the toast center; remote flags; What's New, the Mac version
gate and App Review demo mode; Keep Mac Awake and billing seams with UI stubs. Deferred sign-in is a
design note only (section 9) because C9 must agree.

## 2. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSPlatform` | router, toast queue, remote config seam and flag merge, diagnostic log sink, What's New catalog, Mac compatibility policy, demo policy, keep-awake and billing seams with mocks | Foundation, Observation, `CmuxiOSFeatureKit`, `CmuxSentryScrubbing` |
| `CmuxiOSPlatformUI` | toast overlay, diagnostics screen, What's New sheet, Mac update gate view, keep-awake row, plans stub | UIKit, SwiftUI, `CmuxiOSPlatform`, `CmuxiOSDesign` |
| `CmuxiOSCrashReporting` | Sentry start/stop under consent, scrubbed events and breadcrumbs | `CmuxSentryReporting`, `CMUXMobileCore` (consent seam), Sentry |

`CmuxiOSPlatform` has no UIKit so its tests run with `swift test` on macOS through a scratch
package (same approach as A1's FeatureKit tests). `CmuxiOSShell` imports `CmuxiOSPlatform` for the
flag merge. Feature lanes import `CmuxiOSPlatform` for `ToastCenter` and `ShellRoute`, never
`CmuxiOSCrashReporting`.

## 3. Crash reporting and diagnostics

Owner of consent: `UserDefaultsAnalyticsConsentProvider` (`sendAnonymousTelemetry`, default on),
the same key the shipping app uses, so an existing opt-out carries over. C11 later moves the toggle
into its Privacy section; until then it sits on the diagnostics screen.

`CrashReporter` (CmuxiOSCrashReporting) starts Sentry when consent is on and never in test runs
(XCTest keys, `CMUX_UITEST_*`). Options: the dedicated `cmux-ios` project DSN, `sendDefaultPii`
off, traces 0, app-hang tracking (8 s), watchdog terminations, MetricKit normalized diagnostics,
swizzling, network tracking and auto breadcrumbs off (URLSession carries auth; injected trace
headers cannot be scrubbed). `beforeSend`, `beforeBreadcrumb` and `beforeSendLog` re-read consent
and run the shared `SentryEventScrubber`. Session replay stays off: a1-shell.md 2.10 waits for D3's
decision on masking Metal and video surfaces, and replay without that mask list would record
terminal text. Consent changes are observed through `UserDefaults.didChangeNotification`
(one notification observer, no timer): off closes the SDK, on starts it.

`DiagnosticLogSink` (actor, CmuxiOSPlatform) is the one structured app log of the new shell:
`record(level, category, message)` scrubs the message with `SentryScrubber` (tokens, emails,
home paths, keys, URLs' query secrets), keeps a bounded in-memory ring (2,000 lines) and appends to
`Application Support/cmux-next/diagnostics.log`, rotated at 1 MB with one archive. A tap mirrors
each scrubbed line to Sentry as a breadcrumb. `export()` writes one text file (support header:
app version, build, OS, device model, locale, flags summary; no account id, no email) to the
temporary directory for the share sheet. The export has a hard 2 MB cap including its header;
when older lines do not fit, the newest complete lines are retained and the file includes an
omission marker. `clear()` truncates both. The old
`CMUXMobileCore.DiagnosticLog`/`AppLog` pair is not reused: its event taxonomy is the old iroh
transport's, and the new transport lanes record into this sink through a `DiagnosticRecording`
protocol.

UI: `DiagnosticsView` (SwiftUI form, low frequency): crash reports toggle, line count, Share
Diagnostics (`ShareLink` on the exported file), Copy Support Info, Clear Log with confirmation.
Reached from Settings > Diagnostics and `cmux://diagnostics`.

Analytics: `CMUXMobileCore` now provides the transport-agnostic `BufferedAnalytics` emitter (and
`AnalyticsUploader` alias) behind `AnalyticsEmitting`. It keeps a bounded newest-first command
queue, validates and greedily splits wire batches by event and body limits, fails closed when the
reachability hint is offline, drops invalid/permanently rejected events, and retries transient
transport results with injected cancellable exponential backoff. `AnalyticsUploadTransport`
receives only encoded `AnalyticsWireBatch` bytes. The emitter remains opt-in: `NoopAnalytics` is
still the `AppContainer` runtime default until consent, persistence and lifecycle composition are
reviewed together.

## 4. `ShellRoute` router

`ShellRoute` is the one value every entry point produces: URL scheme, universal link, notification
tap, Spotlight or Handoff later.

| Route | URL path (after the host part) |
| --- | --- |
| `.home` | `home` |
| `.feed(item:)` | `feed`, `feed/<item>` |
| `.workspaces` | `workspaces` |
| `.workspace(host:workspace:surface:)` | `workspace/<host>/<workspace>[/<surface>]` |
| `.compose(host:workspace:)` | `compose[?host=<id>&workspace=<id>]` |
| `.hosts` | `hosts` |
| `.settings` | `settings` |
| `.diagnostics` | `diagnostics` |
| `.whatsNew` | `whats-new` |
| `.pairing(URL)` | `pair...`, `attach...` (passed whole to B6, which owns that grammar) |

Accepted forms: `cmux://<path>`, the registered exact-bundle scheme `cmux-ios-<bundle id>://<path>`,
and `https://cmux.com/app/<path>` (also `www.cmux.com`). Ids are 1 to 128 characters of
`[A-Za-z0-9._:-]`; anything else is unrecognized. The plain `cmux` scheme is parsed but not
registered in Info.plist: the shipping app registers only the exact-bundle scheme so tagged builds
never collide, and registering `cmux` is a product decision (DECISION below). Universal links need
the `applinks:cmux.com` associated domain and an `apple-app-site-association` entry served by
`web/`; neither exists yet, so the parser is ready and the entitlement is a follow-up.

`ShellRouter` (MainActor) owns delivery. `open(url)` returns `.handled`, `.deferred` or
`.unrecognized`. Routes that need an account (all but `.diagnostics`) are parked while signed out
or restoring; one slot, newest wins, and sign-out drops it. When the shell installs its handler
after sign-in, the parked route is delivered once. Unrecognized links show a toast ("This link
needs a newer version of cmux").

Notification hook for C7: `ShellRouter.openNotification(userInfo:)` reads `cmux.route` (a URL
string in the same grammar) or the pair `cmux.host` plus `cmux.workspace` (and optional
`cmux.surface`). C7 sets these keys server-side and calls the hook from the notification delegate;
feed pushes keep their existing `FeedNotificationResponder` path, which now also routes through
`.feed(item:)`. The app delegate's scene delegate forwards `openURLContexts`, `continue
userActivity` and launch options into `CmuxiOSApplication.open(_:)`.

## 5. Toast center

One owner: `ToastCenter` (MainActor, Observable) in `CmuxiOSPlatform`, created by `AppContainer`
and handed to features. `show(_:)` coalesces with the visible toast by key (refresh in place) and
otherwise queues (max 4 queued; the oldest non-failure drops first). Styles: info, success,
warning, failure; dwell 3.5 s for info and success, 6 s for warning, failure or a toast with an
action, `.never` for must-acknowledge states. Dwell runs through an injected sleep function
(`ContinuousClock` by default) in one cancellable task; dismissing or replacing cancels it.
VoiceOver running doubles the dwell. No `asyncAfter`.

`ToastOverlayView` (UIKit) sits above the root controller in a passthrough view, renders the
visible toast as a capsule (system materials, label color text, small muted glyph; no blue),
posts a VoiceOver announcement, fires the style's haptic, slides or fades (Reduce Motion), and
dismisses on tap or swipe. The action button is an accessibility custom action as well.

## 6. Remote flags

`RemoteConfig` is a projection served by B1 (per account and install, from the control plane):
`revision`, `flags: [String: RemoteFlagValue]` (bool, int, string), `minimumMacProtocol`,
`whatsNewRevision`, `demoContent`. `RemoteConfigSource` streams `SourceSnapshot<RemoteConfig>`
like every other seam. `MockRemoteConfigSource` uses `MockSnapshotHub`; a real source plugs into
`AppContainer.remoteConfigFactory` now uses the authenticated `GET /v1/mobile/config` projection
served by B1. `URLSessionRemoteConfigSource` emits the cached projection immediately, refreshes
every five minutes, maps the envelope's `version` to `revision`, and preserves the last valid
value when auth, transport, status or payload validation fails. A future `config.snapshot` stream
can replace this low-frequency source without changing the shell seam.

Merge with A1 local flags (`FeatureFlagStore`), highest first: launch environment
(`CMUX_IOS_FLAG_*`), the device's DEV override, the remote value, the build default. Remote keys
use the flag's raw value (`feedTab`); unknown keys are ignored; a non-bool value for a bool flag is
ignored. The remote layer is applied by `FeatureFlagStore.applyRemote(_:)`, so a remote change
fires the existing `onChange` and the shell re-tabs without a rebuild. The last remote config is
cached on device so a cold start uses it before the first snapshot; the cache is a projection.

## 7. What's New, Mac version gate, demo mode

What's New: `WhatsNewCatalog` holds entries compiled into the app (version, localized title,
items with SF Symbol and text). `WhatsNewPresenter` shows the sheet once after an update when the
newest entry's version is newer than the last seen version (UserDefaults, client view state) and
never on first install. Settings > What's New and `cmux://whats-new` reopen it. Remote entries can
come later over `RemoteConfig.whatsNewRevision`; channel policy follows the shipping app (team
channels by default, App Store only when an entry opts in) because App Review rejected
beta-announcement surfaces under guideline 2.2.

Mac version gate: `MacCapabilitiesSource` streams per-host `MacCapabilities` (app version,
`cmux.mobile` protocol version, capability names). B5 serves it from A0's capability negotiation;
until then a mock. `MacCompatibilityPolicy.verdict(for:)` returns `.compatible`,
`.macUpdateRequired(minimum:)`, `.phoneUpdateRequired(minimum:)` or
`.missingCapabilities([String])`, comparing against the app's supported protocol range and the
remote `minimumMacProtocol`. `MacUpdateGateView` explains which side to update and how (Mac: cmux
> Check for Updates; phone: App Store). Feature screens call the policy before opening a host's
surfaces (D1 and C5 wire it into navigation).

App Review demo mode: `DemoModePolicy` turns on when the remote config sets `demoContent` (B1
sets it for the App Review account) or, in DEBUG, `CMUX_IOS_DEMO=1`. While on, `AppContainer`
resolves every seam through the existing mock factories regardless of the DEV mode store, the
mocks' canned fixtures (`MockFixtures`) supply workspaces, feed and hosts, nothing is persisted,
and Settings shows a "Demo content" row. Turning it off rebuilds the sources from the stored modes.

## 8. Keep Mac Awake and billing

`KeepAwakeControl` seam (per host; B5 owns the Mac's power assertion): `updates()` streams
`[HostID: KeepAwakeState]` (supported, enabled, unknown), `set(_:enabled:key:)` is an intent with a
receipt; offline refuses (U5). `MockKeepAwakeControl` over `MockSnapshotHub`. UI stub:
`KeepAwakeRow` (toggle with status footer) for the host detail screen C11/B6 will own.

`BillingStore` seam: `updates()` streams `BillingState` (offers, current plan, purchase phase),
`purchase(_:key:)` and `restore(key:)` answer receipts. The real store wraps StoreKit 2 and
delivers transactions to the cloud billing owner (C12 decides plans with the cloud lead);
`MockBillingStore` serves two canned plans. UI stub: `PlansView` (plans list, purchase, restore)
behind the `billing` flag, off in every build.

## 9. Deferred sign-in (note only)

Today `RootViewController` gates the whole shell behind sign-in. SSH-only use (C9) needs Hosts and
SSH terminals without an account. Proposal for C9 and A1 to agree on: an `AccountState` of
`.signedIn`, `.guest` (chosen from the sign-in screen, "Use SSH without an account"), `.signedOut`.
Guest shows Hosts (SSH only, from the device Keychain store), Settings and Diagnostics; Feed,
Workspaces, Compose and Home stay hidden because their owners are account-scoped DOs. Guest data
lives in a device-local store that is migrated into the account's synced host store at first
sign-in (an intent per host, idempotent by host fingerprint). `ShellRoute.requiresAccount` already
lets the router deliver guest-safe routes. Nothing here is built until C9 confirms.

## 10. Tests

Swift Testing in `CmuxiOSPlatformTests`: router parsing (every route, every accepted URL form,
rejects bad ids and foreign hosts), deferral (park while signed out, newest wins, deliver once on
sign-in, drop on sign-out, notification payloads), toast queue (coalescing, ordering, cap, dwell
cancellation, `.never`), flag merge (precedence, unknown keys, type mismatch), diagnostic sink
(scrubbing, ring bound, rotation, bounded newest-lines export), What's New presentation rule, Mac compatibility verdicts, mock
keep-awake and billing intents. Plus the `CmuxiOSShellTests` flag store tests for the remote layer.
The whole `CmuxiOSApp` target compiles for the iOS simulator with SwiftPM.

## 11. Decisions

- DECISION: register the plain `cmux://` scheme? RECOMMEND: no for DEV and BETA (collisions between
  tagged builds), yes for the App Store build only, together with universal links.
- DECISION: session replay. RECOMMEND: keep off until D3 lists every Metal and video surface class
  to mask, then enable error-only sampling as the shipping app does.

## 12. Verification (2026-10-06)

- The prior `CmuxiOSPlatformTests` set had 41 Swift Testing tests passing through a macOS scratch
  package. This slice adds three HTTP remote-config tests (envelope mapping, fail-closed cache and
  negative-revision clamping); they are statically parsed here and await the hosted Swift test
  lane before being counted as passing evidence.
- `CmuxiOSShellTests` (with the new remote-layer tests) and `CmuxiOSPlatformTests` compile for
  `arm64-apple-ios17.0-simulator`; the whole `CmuxiOSApp` target builds with SwiftPM; the app target's
  scene delegate typechecks against it. `check-l10n.sh` and `check-concurrency.sh` pass.
- Fleet tag `nxd3-e0391-ios-v1` now compiles the device and simulator targets at exact head
  `e039144f38988cb5ad880d8eeb19773cd075f5e7` (job `a9c4cefb950b6befe522ad06`); no install,
  screenshots, or runtime UI evidence is recorded. Toast overlay, diagnostics share, What's New,
  Mac gate, keep-awake and Plans remain unverified on a device.
- Follow-ups: the `applinks:cmux.com` entitlement and AASA from `web/`; B1 realtime
  `config.snapshot` replacement for the low-frequency HTTP projection; B5 capabilities and power
  assertion; C7 payload keys; C11 moves the consent toggle; D3 replay masks.

## 13. Analytics wire boundary (2026-10-07)

`CMUXMobileCore` now contains a privacy-bounded `AnalyticsWireContract` and `AnalyticsWireBatch`.
It mirrors the worker's `/api/analytics/events` envelope, allowlists event names, limits properties,
identifiers, strings, batches and encoded bodies, rejects non-finite numbers, and maps an anonymous
install id to `$anon_distinct_id`. `BufferedAnalytics` adds bounded asynchronous composition,
offline fail-closed behavior, request splitting, permanent-drop handling and retry/backoff without
polling. The contract and emitter remain opt-in; `NoopAnalytics` is still the runtime owner until
consent, persistence and lifecycle composition are wired. Swift Testing covers shape, aliases and
all bounds plus offline dropping, batch splitting, invalid-event dropping, retry delays and
cancellation; package execution is blocked by the known `CMUXMobileCore` xcstringtool/Testing
plugin checkout issue.
