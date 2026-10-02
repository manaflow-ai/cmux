# cmux next: passkeys and WebAuthn (CEF and WebKit)

Proposal for the spec, 2026-10-02. Owner: the passkeys lead. Inputs: browser.md (CEF fork, child-window pages), browser-host.md (agent leases, Secure sign-in sheet, sealed tabs), browser-isolation.md, OWNERSHIP-PRINCIPLES.md. Lawrence asked for full passkey support: every option the Chromium WebAuthn stack offers, including QR code scanning, done well and without repeating the old cmux bug.

Paths: `main:` = manaflow-ai/cmux `origin/main`, `next:` = `origin/feat-cmux-next`, `chromium:` = `~/fun/cef-cmux-build/chromium/src` (Chromium 154.0.8037.58, CEF fork `cmux/8037-ext` at `8f931f24b`).

## 0. Status in one paragraph

cmux next has no working passkey path today. The legacy WebKit passkey bridge (1,891 lines, `main:Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/WebAuthn/`) was deleted with the legacy app on 2026-09-29 (#15659, deletion.md B1), and nothing replaced it: `next:Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/WebKit/WebKitEngine.swift` builds a plain `WKWebViewConfiguration` and never asks AuthenticationServices for browser passkey authorization. The CEF engine runs Chromium's own WebAuthn stack, which can work with our entitlement, but nobody has run a ceremony in a signed cmux-next build. Signing is in place for stable and nightly (entitlement plus a profile that grants it, checked on the installed apps on 2026-10-02); RC ships without it.

## 1. Known bugs: do not repeat

Every parity agent (cmux next Swift app, GPUI, the Chrome port, cmux-browser) must read this table before it touches WebAuthn, signing, entitlements, popups or browser visibility. "Test" is the regression test each implementation needs; a row is closed for an engine only when that test exists and passes for it.

| # | When, link | Symptom | Root cause | Fix and status | Test we need |
|---|---|---|---|---|---|
| K1 | 2026-02-20 [#124](https://github.com/manaflow-ai/cmux/issues/124), umbrella [#2657](https://github.com/manaflow-ai/cmux/issues/2657), [#1056](https://github.com/manaflow-ai/cmux/issues/1056), [#1278](https://github.com/manaflow-ai/cmux/issues/1278) | GitHub says "This browser or device is reporting partial passkey support"; Okta Touch ID step-up and YubiKey fail. | A plain WKWebView in a third-party app has no browser passkey rights: no `com.apple.developer.web-browser.public-key-credential` entitlement and no `ASAuthorizationWebBrowserPublicKeyCredentialManager.requestAuthorizationForPublicKeyCredentials` call. | Entitlement + authorization + bridge, [#2727](https://github.com/manaflow-ai/cmux/pull/2727) (merged 2026-04-15). **Open again in cmux next (K13).** | Signed build: `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` is true and webauthn.io register + sign in pass, for each engine. |
| K2 | 2026-02-24 [#421](https://github.com/manaflow-ai/cmux/pull/421) | Google sign-in shows "Something went wrong" when it offers a phone passkey. | Hybrid (phone) transport needs Bluetooth; the app had no `NSBluetoothAlwaysUsageDescription`, so the BLE request failed. | Key added (it is in `next:Resources/Info.plist:168`). Its text is the generic child-process string "A program running within cmux would like to use Bluetooth to discover passkeys and security keys." | Built-bundle check that the key is present in the shipped app, plus the manual hybrid check (section 8). |
| K3 | 2026-04-07 [#2660](https://github.com/manaflow-ai/cmux/pull/2660), reverted by [#2681](https://github.com/manaflow-ai/cmux/pull/2681) after [#2676](https://github.com/manaflow-ai/cmux/pull/2676)-[#2680](https://github.com/manaflow-ai/cmux/pull/2680) | Nightly could not launch at all. | New restricted entitlement plus a reworked multi-pass codesign that was never run against a signed, notarized artifact before merge. | Reverted. Rule: any entitlement or signing change is proven on a notarized artifact that launches on a clean Mac before merge. | Release pipeline step that launches the notarized app (not only `codesign --verify` / `spctl`) and fails on spawn error 163. |
| K4 | 2026-04-14 [#2727](https://github.com/manaflow-ai/cmux/pull/2727), [#2902](https://github.com/manaflow-ai/cmux/pull/2902), [#2905](https://github.com/manaflow-ai/cmux/pull/2905), [#2908](https://github.com/manaflow-ai/cmux/pull/2908) | Passkey ceremony fails with `ASAuthorizationError 1004` "The calling process does not have an application identifier"; the first fix made the notarized nightly unlaunchable (POSIX 163). | AuthenticationServices reads `com.apple.application-identifier` from the signed entitlements. Adding it to one shared file signed with `--deep` put the app id on the CLI helpers, whose identifiers differ; AMFI on notarized macOS 26 refuses that. | Inside-out signing: helpers with `cmux-helper.entitlements` (no app id), main app last without `--deep`, per-channel checked-in entitlements. Live in `next:scripts/sign-cmux-bundle.sh`, which also asserts helpers carry no app id. | Keep the existing assertion; add CEF helper apps to it (they must not carry the app id or the passkey entitlement). |
| K5 | 2026-04-15 [#2913](https://github.com/manaflow-ai/cmux/issues/2913), [#2914](https://github.com/manaflow-ai/cmux/pull/2914) (closed, not merged) | Nightly "can't be opened": `AppleMobileFileIntegrityError -413 "No matching profile found"`. | Developer ID provisioning profiles name one leaf certificate. The embedded profile authorized a different leaf certificate than the one that signed the app. | The profile secret was rotated; the guard in #2914 never merged. `nightly.yml` checks the app id, the passkey key and `ProvisionsAllDevices`, not the certificate. | CI check: the signing certificate's SHA-1 is in the profile's `DeveloperCertificates`. Same launch step as K3. |
| K6 | 2026-03-20 [#1876](https://github.com/manaflow-ai/cmux/pull/1876) | Crash on macOS 14; CAPTCHA (Cloudflare) fails in panes. | macOS 15 API used without `@available`; the bridge script ran in every frame and third-party iframes detected the tampering. | Guards; scripts limited to the main frame. | Build at the deployment target; a cross-origin CAPTCHA iframe sees an unmodified `navigator.credentials`. |
| K7 | 2026-04-15 to 2026-06-24, dropped by `cb1a6de8c68` ("Fix bilibili search popup opening detached window"), restored by [#6718](https://github.com/manaflow-ai/cmux/pull/6718) | Passkeys silently stopped working for ten weeks. | A popup refactor of `BrowserPanel.swift` removed the bridge user script and the coordinator; the entitlement and native handler stayed, so nothing failed loudly. | Restored with a behavior test that loads a configured WKWebView and checks the bridge at document start. | Behavior test for every web view the app creates (tab, page-opened popup, restored, hibernated and woken, profile change): the passkey path is installed. |
| K8 | 2026-06-25 [#6766](https://github.com/manaflow-ai/cmux/pull/6766) (closed 2026-09-23, not merged; **still on main**) | Google platform passkey sign-in shows the phone/QR (hybrid) sheet instead of Touch ID; "request already in progress" errors. | The bridge treated the `hybrid` transport as a platform signal and set `shouldShowHybridTransport` from it (`main:.../BrowserWebAuthnSupport.swift:1504`, `:1610`, `:1645`), and defaulted hybrid/internal-only descriptors into USB/NFC/BLE security-key requests. | Not fixed on main. In Chromium the transport routing is Chrome's own; any bridge we write must follow Chromium's rules. | Routing table test: `internal`, `hybrid`, `internal+hybrid`, `usb`, empty allow list, each with `authenticatorAttachment` unset/platform/cross-platform, against Chrome's expected sheet. |
| K9 | 2026-07 [#8630](https://github.com/manaflow-ai/cmux/pull/8630) (closed 2026-08-01, not merged; **still on main**) | Browser crashes on macOS 26.1 (six crashes on 0.64.20). | The bridge called the private selector `isDeviceConfiguredForPasskeys` through `object_getClass`/`unsafeBitCast` (`main:.../BrowserWebAuthnSupport.swift:1855`); `NSXPCConnection` raised `NSInvalidArgumentException` in `ASCAgentProxy`. | Not fixed on main. Rule: no private AuthenticationServices or WebKit selectors in the passkey path. | Capability probe with no private call; `scripts/cmux-next/check-crash-safety.sh` refuses `NSSelectorFromString`/`class_getClassMethod` in the passkey module. |
| K10 | 2026-07-07 [#7503](https://github.com/manaflow-ai/cmux/issues/7503), fix [#9529](https://github.com/manaflow-ai/cmux/pull/9529) (closed 2026-09-23, not merged; **still on main**) | Invisible level-20 windows stay on screen and steal clicks over other apps; blank cmux windows pile up in window switchers. | `presentationAnchor(for:)` returned `activePresentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()` (`main:.../BrowserWebAuthnSupport.swift:1195`): a new window per callback when no window was key. | Not fixed on main. Rule: the sheet anchors to the pane's host window or the request fails; never allocate a window. | Run 10 ceremonies with no key window: the app's window count does not grow. |
| K11 | 2026-07-28 [#9060](https://github.com/manaflow-ai/cmux/pull/9060) (merged 2026-09-25) | Crash after a YubiKey assertion. | `ASAuthorizationPublicKeyCredentialAssertion.userID` is implicitly unwrapped; security keys return none for non-discoverable credentials; the bridge force-unwrapped on the main thread. | Fixed on main; lost in cmux next with the deletion. | Assertion with no user handle returns `response.userHandle === null`. |
| K12 | 2026-09-29 [#15525](https://github.com/manaflow-ai/cmux/pull/15525) (merged) | Google passkey re-authentication: "Something went wrong" (a fresh profile works). | The bridge parser capped every binary field at 1 KiB; Google sends a 10,832-byte challenge and the bridge threw `TypeError: Malformed browser passkey request.` in 2 ms. | Limits follow Chromium/Firefox/WebKit (challenge and credential id unbounded up to the 1 MiB payload; user.id 1-64 bytes; lists 128). Lost in cmux next with the deletion. | Same limits table as #15525, run against every engine. |
| **K13** | **2026-09-29, cmux next: [#15659](https://github.com/manaflow-ai/cmux/pull/15659) (`a4a0868db8b`)** | **cmux next WebKit panes cannot use passkeys; K1 is back. Fixes K9-K12 left with the deleted code.** | **The legacy deletion removed `CmuxBrowser` (deletion.md B1, "WebAuthn ... typed-unavailable") but WebKit panes still expose `navigator.credentials`, so sites see a broken API, not an unavailable one. `WebKitEngine.makeConfiguration` has no passkey setup. CEF passkeys are untested (browser.md section on CmuxBrowser files).** | **This proposal.** | **K1 test per engine on a signed cmux-next nightly.** |
| **K14** | **2026-09-16 [#12777](https://github.com/manaflow-ai/cmux/pull/12777), [#12840](https://github.com/manaflow-ai/cmux/pull/12840); live** | **cmux RC has no passkeys.** | **The RC App ID's capability request has been pending at Apple since 2026-07-10, so `cmux.rc.entitlements` omits the entitlement and the sign check skips it. Checked 2026-10-02: `/Applications/cmux RC.app` 0.65.0-rc signature and profile both lack the key.** | **Open. [#12857](https://github.com/manaflow-ai/cmux/pull/12857) (RC uses the stable identity) would fix it.** | **The app reports `passkeys: unavailable (no entitlement)` in `browser.passkeys.status` and in Settings, instead of failing silently.** |
| K15 | Code inspection of `main:.../BrowserWebAuthnSupport.swift` (no `signal` handling anywhere) | A page that starts a conditional (autofill) request and then a modal one gets "The passkey request failed" (K8's "already in progress"). | The bridge ignores `AbortSignal`; the conditional request stays in flight and `performAuthorization` refuses the second one (`:1421`). #6766 papered over it with a 500 ms retry. | Not fixed on main. Chrome cancels a pending conditional request when the page aborts it or starts a modal one. | Abort test: conditional get, abort, modal get succeeds; abort during a modal get rejects with `AbortError` and closes the sheet. |
| K16 | 2026-08-02 cmux-browser [#95](https://github.com/manaflow-ai/cmux-browser/pull/95) (Chromium fork, Linux) | WebAuthn fails in custom panes with `NotAllowedError`. | Chromium refuses a request unless the frame is active and `ChromeWebAuthenticationDelegate::IsFocused` holds, which is `web_contents->GetVisibility() == VISIBLE` (`chromium:chrome/browser/webauthn/chrome_web_authentication_delegate.cc:251`), checked at the start and again when the result returns (`chromium:content/browser/webauth/authenticator_common_impl.cc:1334`, `:3255`). The pane's WebContents visibility did not follow the real pane. | Fixed in cmux-browser by syncing visibility. Applies to our CEF panes: hidden, hibernated, scrolled-away or reported-occluded tabs fail, and a ceremony whose own system sheet makes us report the page occluded fails at completion. | CEF: visible tab passes; hidden tab gets `NotAllowedError`; a page partly covered by the system sheet or a cmux overlay keeps `VISIBLE` and completes. |
| K17 | Gaps in the legacy bridge (not crashes) | Sites that need these fail or degrade. | No PRF, `largeBlob`, `credProps`, `getClientCapabilities`, `signal*` methods, `parseCreationOptionsFromJSON`; cross-origin iframes refused even with `allow="publickey-credentials-get"`; parent-domain RP IDs native only for `google.com` (`main:.../BrowserWebAuthnSecurityOrigin.swift:112`); U2F `appid` falls back to WebKit. | n/a | Feature matrix test (section 7) on every engine. |
| K18 | Process | Each fix was "verified" on a tagged build that cannot run a real ceremony. | Tagged DEV bundle ids have no profile that grants the entitlement (stated in #6718 and #15525). | n/a | Every passkey change lists its signed-build manual checks as UNVERIFIED until a signed nightly passes them. |

Related, not passkey bugs (do not confuse): [#2154](https://github.com/manaflow-ai/cmux/issues/2154) Apple Passwords autofill (no public API for third-party WKWebView browsers), [#10528](https://github.com/manaflow-ai/cmux/issues/10528) Extensible SSO (misattributed; closed by reporter), [#4033](https://github.com/manaflow-ai/cmux/issues/4033) mTLS client certificates (keychain access group), [#1491](https://github.com/manaflow-ai/cmux/issues/1491) and [#7513](https://github.com/manaflow-ai/cmux/issues/7513) Google/Duo user-agent checks.

The most recent bugs are K12 (fixed on main 2026-09-29, the last passkey commit on main) and K13 (the same day, cmux next lost all of it). K14 is live in RC today.

## 2. What the Chromium WebAuthn stack supports on macOS

Read from Chromium 154 in our build tree.

| Feature | Chromium mechanism | CEF pane (Chromium stack) | WebKit pane |
|---|---|---|---|
| iCloud Keychain / Apple Passwords passkeys (create, sign in, Touch ID, Apple Watch) | `device/fido/mac/icloud_keychain*.mm`: `ASAuthorizationWebBrowserPublicKeyCredentialManager`, gated on `SecTaskCopyValueForEntitlement("com.apple.developer.web-browser.public-key-credential")` in the browser process (`icloud_keychain_sys.mm:228-240`) and macOS 13.5 (`icloud_keychain.mm:617`); needs an `NSWindow` from the tab's views Widget (`chrome_authenticator_request_delegate.cc:1208-1216`), else the discovery is skipped (`device/fido/fido_discovery_factory.cc:210`). | Works if the main app is signed with the entitlement (stable, nightly) and the page's Widget resolves to an `NSWindow` (our child page window is a views Widget). | Needs `requestAuthorizationForPublicKeyCredentials` once, then either WebKit's own WebAuthn or our bridge (decision D1). |
| Third-party credential managers (1Password, Bitwarden, Dashlane via macOS 14+ credential provider extensions) | Same AuthenticationServices request; the system sheet lists enabled providers. | Comes with iCloud Keychain support. | Same. Extensions as browser extensions: CEF supports Chrome extensions; WebKit needs `WKWebExtension` (not in cmux next). |
| Chrome profile passkeys (Touch ID "Chrome profile" authenticator) | `device/fido/mac/` Touch ID authenticator, keychain group `MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"` (`chrome_web_authentication_delegate.cc:394`). | Our build's identifiers do not match the `keychain-access-groups` we sign, so keychain writes fail. Decision D3. | n/a |
| Google Password Manager passkeys (enclave, synced) | Needs a Chrome profile signed into Google with sync. | Not available: CEF has no Chrome sign-in. State it in Settings. | n/a |
| Hybrid: QR code scanned by a phone, BLE proximity, caBLE v2, linked phones | `device/fido/cable/`, Chromium's QR sheet; needs Bluetooth on and the app's Bluetooth TCC grant. Linked phones come from Google sync. | QR + BLE work in the browser process (the main app), which has `NSBluetoothAlwaysUsageDescription`. Linked phones: no (no sync). | The system sheet offers "iPhone, iPad or Android device" (QR) when `shouldShowHybridTransport` is true; Bluetooth TCC as above. |
| USB and NFC security keys (CTAP2/U2F over HID) | Chromium's HID discovery; Chromium's PIN, touch, and reset sheets. | Works (non-sandboxed browser process; no extra entitlement). | `ASAuthorizationSecurityKeyPublicKeyCredentialProvider` (macOS 14.4+ for the full set). |
| Conditional UI (`mediation: "conditional"`, passkeys in the autofill dropdown) | Chromium's autofill integration plus iCloud Keychain `GetPlatformCredentials`. | Works with Chromium's autofill UI. | Bridge: `performRequests(options: .preferImmediatelyAvailableCredentials)` shows the system sheet, not an inline dropdown (no public API for inline WKWebView autofill). |
| `mediation: "immediate"`, `signalUnknownCredential` / `signalAllAcceptedCredentials` / `signalCurrentUserDetails`, `getClientCapabilities`, JSON helpers | Implemented in Chromium 154 (verify per feature with the test RP, section 7). | Follows Chromium. | Bridge must implement or report unsupported. |
| PRF, `largeBlob`, `credProps`, `credBlob`, `minPinLength`, `hmac-secret` | Chromium: PRF on iCloud Keychain (macOS 15+ API) and security keys; largeBlob on iCloud Keychain and keys (`icloud_keychain_sys.mm` LargeBlob inputs). | Follows Chromium. | `ASAuthorizationPublicKeyCredentialPRFRegistrationInput`/`AssertionInput` (macOS 15) and `largeBlob` (macOS 14) on the platform provider. |
| Related origin requests (`/.well-known/webauthn`) | Chromium fetches and checks the list for RP IDs outside the caller's registrable domain. | Follows Chromium. | Bridge: the legacy one refused all non-`google.com` parent domains (K17). |
| Cross-origin iframes with `allow="publickey-credentials-get"` / `-create` | Allowed by Permissions Policy (create needs user activation). | Follows Chromium. | Bridge must set `crossOrigin`/`topOrigin` in client data (legacy refused, K17). |
| Enterprise attestation, `chrome://settings/passkeys` management, security-key PIN and reset UI | Chromium settings pages. | Reachable as `chrome://` pages if the fork allows them (decision D5). | System Settings > Passwords for iCloud Keychain; no key management. |

## 3. Design

### 3.1 One owner per ceremony, per engine

A WebAuthn request belongs to the tab that made it. The engine runs it (Chromium's `AuthenticatorCommon` for CEF, WebKit or our bridge for WebKit); the app owns only policy (agent leases, settings) and presentation (which window anchors the sheet). The daemon and the Rust browser host never see request or response bytes: nothing about a ceremony crosses a socket. The host learns only a status event for agent leases (3.5).

### 3.2 CEF (default engine): use Chromium's stack, change little

No JavaScript bridge in CEF. Requirements, each with a test:

1. Browser process entitlement: the main app is the CEF browser process, so the stable/nightly signature already satisfies `ProcessHasEntitlement`. The CEF helper apps must not carry the passkey entitlement or the app id (K4).
2. Window: `GetTopLevelWidgetForNativeView(web_contents->GetNativeView())` must return the page's child Widget. The sheet then attaches to the page's child `NSWindow`, which sits exactly over the pane (browser.md, "Chrome style with a native parent view"). Check on a signed nightly that the system sheet appears over the pane, not detached. If it detaches, the fork returns the parent window for `set_nswindow` (fork change in manaflow-ai/cef, one function).
3. Visibility (K16): a tab with a pending ceremony must report `VISIBLE` while its pane is on screen, including while the system sheet, the Chromium WebAuthn dialog, or a cmux overlay (palette, hover card) covers part of it. Occlusion reporting (`BrowserWindowOcclusion`, `CEFTab+Visibility`) must not send `WasOccluded`/`WasHidden` for partial coverage. Hibernation and the deferred-tab path must not hibernate a tab with a pending ceremony.
4. Chromium's WebAuthn dialog: it is a tab-modal views dialog with Chromium styling (blue buttons, Google strings). Decision D2 picks between keeping it, restyling it in the fork, or replacing it with cmux's own sheet through a fork hook.
5. Touch ID profile authenticator (decision D3).
6. Agent leases (3.5) need one fork export: `cmux_tab_set_webauthn_mode(browser_id, mode)` with modes `allow`, `refuse` and `virtual` (DevTools virtual authenticator environment), set before the first navigation, inherited by popups the app adopts, like API 15's password switch.

### 3.3 WebKit (secondary engine): authorization first, then measure

1. Every WebKit tab's configuration path (new tab, page-opened popup, restored, woken from hibernation, profile switch) goes through one `PasskeyConfiguration.prepare(_:)` (K7). It requests browser passkey authorization once per app session, lazily, on the first WebAuthn call from a user-activated top-level or same-origin frame, never on page load.
2. Decision D1: WebKit's own WebAuthn (with entitlement and authorization) or a new native bridge. First step is a measurement on a signed nightly: does WebKit alone pass the section 7 matrix (platform passkey, hybrid QR, YubiKey, conditional, PRF, 10 KB challenge, cross-origin iframe)? Whatever WebKit alone cannot do decides whether a bridge exists. If a bridge exists it is new code that carries every rule in section 1 (K8-K12, K15, K17) with tests first, and no private selectors.
3. The sheet anchors to the pane's host window (`webView.window`), only when that window is visible and on the active Space; otherwise the request fails with `NotAllowedError` (K10).

### 3.4 Permission prompts and system sheets

- The passkey sheet, the browser passkey authorization prompt ("Allow cmux to use passkeys...") and the Bluetooth prompt are macOS system UI; we cannot style them. cmux adds no pre-prompt.
- cmux's own UI for passkeys: one line in the page info popover ("Passkeys: allowed / not allowed in System Settings / unavailable in this build"), a Settings section, and a refusal toast when an agent-driven tab tries a ceremony. Minimal, Ghostty-derived colors, no blue, Liquid Glass on macOS 26 through CmuxNextDesign. Prototype variants for the refusal surface (toast vs page-info badge vs tab-strip glyph) behind a Debug Settings switch; Lawrence picks.
- Which window owns the sheet: the window that holds the pane (CEF: its page child window over the pane; WebKit: the pane's host window). Never a new window, never the key window of another app area, never a hidden or off-Space window. A ceremony in a background workspace fails rather than surfacing that workspace.

### 3.5 Agents never complete a passkey ceremony

An agent's synthesized click is a user activation for the page, so an agent can make a site call `navigator.credentials.get()` and put a Touch ID sheet in front of the user, who may approve it without knowing an agent asked. Rules:

1. A tab under an agent lease (the same lease that turns password fill off, browser.md "Agent-driven tabs get no autofill") runs WebAuthn in mode `refuse` by default: every request rejects with `NotAllowedError` before any system UI; conditional requests never show passkeys in autofill. The app shows the refusal (3.4) with one action: "Sign in yourself", which ends the agent lease for that tab (the user takes over, like the Secure sign-in sheet) and reloads.
2. The Secure sign-in sheet gains a passkey path: an agent asks `sites.browserAuth.request {method: "passkey"}`; the app hands the tab to the user, the user completes the ceremony in the page, and the agent gets only a status (`submitted`, `cancelled`, `unavailable`, `expired`, `origin_changed`). The tab is then sealed (browser-host.md decision 8).
3. Mode `virtual` exists for agents testing their own sites: a DevTools virtual authenticator (CEF only; `WebAuthn.enable` + `WebAuthn.addVirtualAuthenticator` through the host's raw CDP relay). It never reaches real credentials. WebKit has no public virtual authenticator, so `virtual` answers `unsupported` there.
4. No socket method, CLI verb, MCP tool or host API returns a credential, assertion, PRF output or large blob, and none may be added. Raw CDP from agents must refuse `WebAuthn.*` except in `virtual` mode, and `WebAuthn.disable` from an agent does not leave `refuse`.
5. Tests (first): an agent click on a "Sign in with passkey" button in a leased tab rejects with `NotAllowedError` and shows no system sheet (CEF: virtual-authenticator environment proves no real discovery started; WebKit: the bridge or WebKit delegate records no `ASAuthorizationController`); a popup opened by a leased tab inherits `refuse`; the lease ending restores `allow` only after a reload.

### 3.6 Settings (cmux.json and Settings > Browser > Passkeys)

| Key | Default | Meaning |
|---|---|---|
| `browser.passkeys.enabled` | `true` | Off makes every engine reject WebAuthn with `NotAllowedError` and report UVPA false. |
| `browser.passkeys.agentTabs` | `refuse` | `refuse` or `virtual` (CEF only). There is no `allow`. |
| `browser.passkeys.hybrid` | `true` | Offer "use a phone or tablet" (QR + Bluetooth). |
| `browser.passkeys.securityKeys` | `true` | Offer USB/NFC security keys. |
| `browser.passkeys.chromeDialog` | per D2 | Prototype switch for D2 (DEV/NIGHTLY Debug Settings first). |

Each default has a docs entry and a test that the default matches the docs.

### 3.7 Surfaces (one action catalog)

| Action | CLI | MCP | Palette | Notes |
|---|---|---|---|---|
| `browser.passkeys.status` | `cmux browser passkeys status --json` | yes | no (read-only diagnostics) | Per engine: entitlement present, app id, macOS authorization state, Bluetooth TCC state, settings, last ceremony outcome per tab (status only). Agents use it to say "passkeys unavailable in this build" instead of guessing (K14). |
| `browser.passkeys.openSettings` | `cmux browser passkeys settings` | yes | "Passkey Settings" | Opens Settings > Browser > Passkeys. |
| `browser.passkeys.openSystemSettings` | no | no | "Manage Passkeys in System Settings" | Opens System Settings > Passwords. Exemption for CLI/MCP: it would move focus to another app. |
| `sites.browserAuth.request {method: passkey}` | via browser REPL | yes | no | Section 3.5. |

The CLI verbs go to the Rust CLI session (CLI freeze, AGENT-BRIEF).

## 4. Signing, App IDs and profiles

Checked 2026-10-02 from the installed apps (no secrets read):

| Channel | Bundle id | Signed with the entitlement | Embedded profile grants it |
|---|---|---|---|
| stable 0.64.25 | `com.cmuxterm.app` | yes | yes |
| nightly 0.64.25-nightly | `com.cmuxterm.app.nightly` | yes | yes |
| RC 0.65.0-rc | `com.cmuxterm.app.rc` | no | no (K14) |
| tagged DEV | per-tag debug bundle id | no | no profile (K18) |

`next:cmux.nightly.entitlements` and `next:cmux.release.entitlements` request the key and `keychain-access-groups` `7WLXT3NR37.<bundle id>`; `next:scripts/sign-cmux-bundle.sh` asserts the key when the channel asks for it. Gaps: the certificate-in-profile check (K5) and a launch smoke (K3). cmux-browser (`com.cmux.app.*`) has its own pending Apple requests (cmux-browser PR 215). Passkey work never touches signing secrets; profiles come from the existing CI secrets or the vault.

## 5. Build plan (small landable steps, failing test first)

1. **Test RP and reference oracle (landed with this proposal).** `tests/passkeys/`: a local relying party page that runs every section 7 scenario and reports structured results, and `run.mjs`, which runs it in Playwright Chromium with a DevTools virtual authenticator. Stock Chromium is the oracle; the same runner later targets a cmux CEF tab through the host's CDP relay and a WebKit tab through the WebKit driver.
2. **CEF signed-nightly measurement.** Run section 8 on a signed cmux-next nightly. Record which rows pass. No code.
3. **CEF visibility and pending-ceremony guard (K16).** Failing test: a CEF tab with a pending virtual-authenticator ceremony that we occlude partly stays `VISIBLE` and completes. Then the fix in `CEFTab+Visibility` / hibernation.
4. **Agent leases: `refuse` mode.** Fork export `cmux_tab_set_webauthn_mode` (manaflow-ai/cef, new API version), shim binding, lease hook next to `markAgentDriven`. Failing tests first (3.5.5).
5. **WebKit `PasskeyConfiguration` + authorization (K1, K7, K13).** Behavior test that every WebKit configuration path is prepared; signed-build check for UVPA.
6. **WebKit measurement, then D1.** If a bridge is needed, port the rules, not the code, with K8-K12, K15, K17 tests first.
7. **Settings, `browser.passkeys.status`, page-info line, refusal prototypes.**
8. **Signing guards (K3, K5).** Certificate-in-profile check and a notarized launch smoke in the release pipeline.

## 6. Decisions for Lawrence

- **D1. WebKit path.** (a) WebKit's own WebAuthn with entitlement + authorization, measured first; bridge only for what fails. (b) Port a full native bridge now. **Recommended: (a).** The legacy bridge caused K7-K10 and K15 by reimplementing what WebKit and AuthenticationServices do; the measurement takes one signed nightly.
- **D2. Chromium's WebAuthn dialog in CEF panes.** (a) Keep Chromium's dialog as is (blue, Google strings, full feature set at no cost). (b) Restyle it in the fork (colors, strings, no Google branding). (c) A fork hook that hands dialog state to a native cmux sheet. **Recommended: (a) now, prototype (b) behind a Debug switch.** (c) re-implements Chromium's ~20 dialog states (PIN, reset, QR, BLE off, too many attempts) and repeats K8-class bugs.
- **D3. Chrome profile (Touch ID) passkeys in CEF.** (a) Disable the profile authenticator in the fork; new passkeys go to iCloud Keychain or a security key. (b) Make the fork use `7WLXT3NR37.<bundle id>.webauthn` and add that group to the entitlements and profiles. **Recommended: (a).** Profile passkeys do not sync, Chromium itself steers new credentials to iCloud Keychain or Google Password Manager, and (b) adds a keychain group to three App IDs and profiles.
- **D4. Agent default.** `refuse` (recommended) vs `virtual` by default in agent-driven CEF tabs.
- **D5. `chrome://settings/passkeys` and security-key management pages.** Expose them in CEF panes (recommended, they are Chromium's own) or hide them.
- **D6. RC passkeys (K14).** Land #12857 (RC uses the stable identity, which already has the capability) or keep waiting for Apple. **Recommended: land #12857**, owned by the release lane, not this one.

## 7. Feature matrix (test RP scenarios)

`tests/passkeys/rp/index.html` (run with `node tests/passkeys/run.mjs`; `--serve` for a person in a cmux pane, `--cdp` for an existing Chromium) runs these in order and reports one JSON object per scenario: `create-platform`, `get-discoverable`, `get-allow-list`, `get-large-challenge` (K12), `get-no-user-handle` (K11), `abort-conditional-then-modal` (K15), `abort-modal` (K15), `prf-create-get`, `large-blob`, `cred-props`, `client-capabilities`, `cross-origin-iframe-denied`, `cross-origin-iframe-allowed`, `transports-hybrid-only` and `transports-internal-hybrid` (K8, reported for the manual check), `user-id-too-long` (expect `TypeError`), `insecure-rp-id` (expect `SecurityError`). The page checks what a browser must produce (clientDataJSON type, origin, challenge echo, crossOrigin, flags, extension outputs); it does not verify signatures, which no browser bug in section 1 involved.

## 8. Manual checks for Lawrence (UNVERIFIED until done; signed cmux-next nightly)

Each in a CEF tab and in a WebKit tab (New WebKit Tab from the palette):

1. https://webauthn.io: Register with "Platform"; Touch ID; then Authenticate. Expect success both times.
2. https://passkeys.dev/device-support or https://webauthn.io with "Cross-platform": choose "iPhone, iPad, or Android device"; a QR code appears; scan with the iPhone camera; approve on the phone. Expect success. If Bluetooth is off, expect a clear "turn on Bluetooth" step, not "Something went wrong" (K2).
3. YubiKey: webauthn.io "Security key", insert the key, touch it, enter the PIN if asked. Then Authenticate with the username filled in (allow list). Expect no crash (K11).
4. github.com sign-in with a saved passkey: the username field shows the passkey in autofill (conditional UI). Choose it; Touch ID. Expect sign-in.
5. accounts.google.com re-authentication (myaccount.google.com > Security > "Passkeys", which asks to verify): expect Touch ID, not a QR sheet (K8), and no "Something went wrong" (K12).
6. Ask an agent to click "Sign in with a passkey" on webauthn.io in a browser tab: expect no Touch ID sheet, a cmux refusal, and "Sign in yourself" (3.5; needs step 4 of section 5).
7. Background check: start webauthn.io Authenticate, then switch workspaces before Touch ID: expect the request to fail cleanly, and no leftover invisible window (K10).

## 9. Not verified / shortcuts

- I ran no ceremony in any cmux-next build; CEF behavior is read from Chromium source. Sheet placement over the child page window (3.2.2) is the biggest unknown.
- WebKit's behavior with the entitlement and no bridge is unknown (D1 measures it).
- K15 comes from code inspection, not a reproduction.
- Stock Chromium (Chrome for Testing 153.0.8010.12, one major below our fork) passes every judged test RP scenario with a virtual authenticator, and its `getClientCapabilities()` reports `immediateGet`, `relatedOrigins`, `hybridTransport`, `signalAllAcceptedCredentials`, `signalCurrentUserDetails`, `signalUnknownCredential`, `extension:prf`, `extension:largeBlob` and the JSON helpers. PRF and largeBlob on iCloud Keychain itself (not a virtual authenticator) are unverified.
- K8 oracle from that run: an allow list with `transports: ["internal", "hybrid"]` is answered by the local platform credential; `["hybrid"]` alone is not sent to it (Chromium goes to the phone flow; with no UI it ends in `NotAllowedError`). A WebKit bridge must route the same way.
