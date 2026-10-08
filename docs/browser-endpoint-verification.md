# Google Endpoint Verification in the embedded browser

Google Endpoint Verification cannot be enabled by changing cmux's current
WebKit identity. The shipped embedded browser is a `WKWebView` product, while
Endpoint Verification's supported desktop flow requires Chrome, the Endpoint
Verification extension, and its companion helper. This note records the
boundary and the smallest implementation scope that could satisfy the request.

## Decision

Do not add a Chrome-looking user-agent string, `window.chrome` shim, cookie
copy, or TLS bypass to the current browser. Those changes could make a support
check look different while leaving the device-trust flow unavailable.

Treat full Endpoint Verification support as a Chromium/CEF engine capability.
The legacy WebKit browser should continue to handle ordinary web pages and
certificate challenges, but it should not claim to support Chrome-only device
posture flows.

## Product boundary found in this checkout

| Boundary | Evidence in `main` | Consequence for Endpoint Verification |
| --- | --- | --- |
| Rendering engine | `BrowserPanel.makeWebView` constructs `CmuxWebView` from `WKWebViewConfiguration`; `BrowserPanel.configureWebViewConfiguration` installs a `WKWebsiteDataStore` and WebKit user scripts. | The page runs in WebKit's runtime. There is no Chromium extension runtime or Chrome profile model to host Endpoint Verification. |
| Profile storage | `BrowserProfileWebsiteDataStoreAdapter` maps each cmux profile to `WKWebsiteDataStore(forIdentifier:)`. | A WebKit website-data profile is not a managed Chrome profile and cannot enroll the Chrome extension/helper pair. |
| Browser identity | `BrowserUserAgentPolicy` assigns a Safari-compatible `customUserAgent` to HTTP(S) pages. `WKWebView+BrowserUserAgentPolicy` only applies/restarts that identity. | The HTTP `User-Agent` header does not add extension APIs, native messaging, Chrome managed-account state, or device association. |
| Authentication boundary | `BrowserNavigationDelegate` and the popup delegate handle server trust, HTTP Basic, and client-certificate challenges. | This covers TLS/client-certificate authentication. It is separate from Endpoint Verification's browser extension/helper device-posture signal. |
| Popup boundary | `BrowserPopupWindowController` reuses the opener's WebKit configuration and website data store. | A popup does not switch engines or acquire Chrome extension capabilities. |
| Chromium source status | `cmux-browser/` is a staged Chromium overlay/build contract; it is not linked by the current app target. | Passing an engine flag cannot activate a Chromium runtime in this release. |

The user-agent policy is useful for ordinary browser-support gates, but it is
not an Endpoint Verification implementation. In particular, changing it must
not be presented as a workaround for device trust.

## Google’s supported contract

Google's [Endpoint Verification setup guide](https://support.google.com/a/users/answer/9018161?hl=en)
states that the desktop setup uses Chrome, the Endpoint Verification extension,
and a helper app. It also says that the extension may install on Chromium-based
browsers but is supported only on Chrome. The setup then requires opening Chrome
and signing in with the managed Google Account before the device synchronizes.

Google's [Context-Aware Access platform table](https://knowledge.workspace.google.com/admin/security/protect-your-business-with-context-aware-access)
lists device-policy access for desktop Chrome together with the Chrome Endpoint
Verification extension; Safari is listed under different platform cases. This
is why a Safari-compatible request header is not evidence that a protected app
will accept cmux's WebKit pane.

Google documents a separate [certificate-based web access flow](https://docs.cloud.google.com/access-context-manager/docs/enable-cba-web-apps).
That flow uses mTLS and a client certificate, which is the class of challenge
cmux's WebKit delegate can answer. It must not be conflated with Endpoint
Verification's extension/helper device-posture flow.

## Bounded implementation scope

The implementation belongs with the Chromium/CEF browser-engine work, rather
than in `BrowserPanel`'s WebKit path. A reviewable first slice should include
all of the following before calling the issue supported:

1. **Engine selection:** model a browser tab as `webkit` or `cef`, fix the
   engine at tab creation, and make an explicit CEF request fail with a clear
   unavailable reason instead of silently creating WebKit.
2. **Chrome runtime:** ship a supported CEF/Chromium build with the extension
   APIs Endpoint Verification uses (`chrome.runtime`, identity/storage, and
   native-messaging or the equivalent helper bridge), a Chrome-style profile,
   and the required helper lifecycle and keychain integration.
3. **cmux boundaries:** route tabs, popups, profile storage, downloads, client
   certificate selection, and automation through the selected engine. WebKit
   remains the fallback for pages that need its codecs or WebKit-only behavior.
4. **Acceptance evidence:** on a managed Mac and a test tenant enforcing a
   device policy, install/enroll Endpoint Verification, sign in with the
   managed account, and load the protected app in a CEF pane. Record the
   extension/helper sync and the policy decision. A changed user-agent string,
   a `window.chrome` object, or a successful ordinary TLS handshake is not
   sufficient evidence.

The adjacent [`BrowserEngineResolver`](https://github.com/manaflow-ai/cmux/blob/03b660fdf079ebdcf120dae15f4ae142b812ed3b/Packages/macOS/CmuxNext/Sources/CmuxNextApp/BrowserEngineResolver.swift)
work treats `cef`/`chromium` as an explicit engine and refuses an explicit
request when CEF is unavailable. Its [browser design note](https://github.com/manaflow-ai/cmux/blob/03b660fdf079ebdcf120dae15f4ae142b812ed3b/plans/cmux-next/browser.md)
also calls out the remaining CEF distribution, helper, profile, and live
managed-device validation work. That branch is not the shipped release path;
it is a useful implementation seam, not evidence that #18606 already works.

## Explicit non-goals

- Do not spoof Chrome with `customUserAgent`.
- Do not inject a partial `window.chrome` compatibility object.
- Do not copy cookies or device state from Chrome into WebKit.
- Do not bypass the organization's device policy or certificate validation.
- Do not claim support from a generic Google sign-in or a client-certificate
  prompt; both can succeed without Endpoint Verification.

## Evidence captured

- Current checkout at `f0a2bad554448afe3059eebbdabad7790dfc25cd`: the
  `BrowserPanel`/`BrowserNavigationDelegate` and `CmuxBrowser` sources
  described above.
- Google documentation fetched on 2026-10-08: the Endpoint Verification setup,
  Context-Aware Access platform support, and certificate-based web access pages
  linked above.
- Adjacent-engine reference: `origin/feat-cmux-next` at
  `03b660fdf079ebdcf120dae15f4ae142b812ed3b` (2026-10-08), inspected for
  `BrowserEngineResolver` and `plans/cmux-next/browser.md`.
