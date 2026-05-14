# WKWebView surface audit (P3 migration scope)

Generated from grep over `Sources/Panels/*.swift`, `Sources/Find/*.swift`, and friends. Drives what `Packages/CmuxBrowserEngine` must expose before each callsite can flip to the Chromium backend.

## Scope

Files inside the migration boundary:

| File | Lines |
|---|---|
| `Sources/Panels/BrowserPanel.swift` | 10,864 |
| `Sources/Panels/BrowserPanelView.swift` | 6,862 |
| `Sources/Panels/CmuxWebView.swift` | 2,472 |
| `Sources/Panels/BrowserPopupWindowController.swift` | 657 |
| `Sources/Panels/BrowserWebAuthnSupport.swift` | (small) |
| `Sources/Find/BrowserFindJavaScript.swift` | (small) |
| Auxiliary: `AppDelegate.swift`, `ContentView.swift`, `Workspace.swift`, `TerminalController.swift`, `MarkdownPanelView.swift`, `MarkdownWebRenderer.swift`, `ReactGrab.swift`, `FileDropOverlayView.swift`, `BrowserPaneDropTargetView.swift` | various |

The first four files are the primary migration surface (~20 K lines). The rest hold the engine but treat it as opaque.

## WK types touched (alphabetical)

`WKDownload`, `WKDownloadDelegate`, `WKFrameInfo`, `WKHTTPCookieStore`, `WKInspector`, `WKMediaCaptureType`, `WKMenuItemIdentifier*`, `WKNavigation`, `WKNavigationAction`, `WKNavigationActionPolicy`, `WKNavigationDelegate`, `WKNavigationResponse`, `WKNavigationResponsePolicy`, `WKNavigationType`, `WKOpenPanelParameters`, `WKPermissionDecision`, `WKProcessPool`, `WKScriptMessage`, `WKScriptMessageHandler`, `WKScriptMessageHandlerWithReply`, `WKSecurityOrigin`, `WKSnapshotConfiguration`, `WKUIDelegate`, `WKUserContentController`, `WKUserScript`, `WKWebView`, `WKWebViewConfiguration`, `WKWebsiteDataStore`, `WKWindowFeatures`.

`Packages/CmuxBrowserEngine` already exposes engine-neutral analogues for the bold types below. Italic = needs to be added before that callsite migrates. Plain text = not needed at the wrapper layer (delegate-internal).

| WK type | Coverage today |
|---|---|
| **WKWebView** | `CmuxBrowserView` |
| **WKWebViewConfiguration** | `CmuxBrowserConfiguration` |
| **WKUserContentController** | `CmuxUserContentController` |
| **WKUserScript** | `CmuxUserScript` |
| **WKScriptMessage** | `CmuxScriptMessage` + `CmuxScriptMessageBody` |
| **WKScriptMessageHandler** | `CmuxScriptMessageHandler` |
| **WKNavigationDelegate** | `CmuxNavigationDelegate` |
| **WKNavigation** | `CmuxNavigation` |
| **WKNavigationAction** | `CmuxNavigationAction` |
| **WKNavigationActionPolicy** | `CmuxNavigationActionPolicy` |
| **WKNavigationResponse** | `CmuxNavigationResponse` |
| **WKNavigationResponsePolicy** | `CmuxNavigationResponsePolicy` |
| **WKNavigationType** | `CmuxNavigationAction.NavigationType` |
| **WKFrameInfo** | `CmuxFrameInfo` |
| **WKUIDelegate** | `CmuxUIDelegate` |
| **WKWindowFeatures** | `CmuxWindowFeatures` |
| **WKOpenPanelParameters** | `CmuxOpenPanelParameters` |
| **WKURLSchemeHandler** | `CmuxURLSchemeHandler` + `CmuxURLSchemeTask` |
| *WKScriptMessageHandlerWithReply* | not yet — used by one inspector path |
| *WKDownload + WKDownloadDelegate* | not yet — `BrowserPanel` exposes downloads via `webView.cmuxBrowserPanelForceRenderingStateRefresh`-adjacent code; needs `CmuxDownload`, `CmuxDownloadDelegate`, `CmuxDownloadProgress` |
| *WKHTTPCookieStore + WKWebsiteDataStore* | not yet — needs `CmuxCookieStore`, `CmuxDataStore`, persistence/ephemeral selection, container ID |
| *WKInspector* | not yet — needs `CmuxInspector.show/hide/attach/detach`; Chromium provides `chrome://inspect` style remote debugger we can wire instead |
| *WKMediaCaptureType + WKPermissionDecision* | not yet — needs `CmuxMediaCapturePermission` enum |
| *WKSecurityOrigin* | not yet — exposed via `CmuxFrameInfo` host/port; promote to a proper type if a callsite needs more |
| *WKSnapshotConfiguration* | not yet — `takeSnapshot` exists but doesn't take config; add `CmuxSnapshotConfiguration` (rect, after-screen-updates, snapshot width) before parity |
| *WKProcessPool* | not yet — `CmuxBrowserConfiguration.processPoolTag` exists but doesn't bridge to WKProcessPool; production needs that bridge or a documented compromise |
| *WKMenuItemIdentifier\** | not needed at the wrapper — these are AppKit menu items the host owns |

## High-frequency call sites (sorted by occurrence)

| Count | Call | Coverage |
|---:|---|---|
| 131 | `WKWebView` type reference | type lives behind `CmuxBrowserView` |
| 26 | `webView.window` | inherited from `NSView`; `CmuxBrowserView` is an `NSView` ✓ |
| 16 | `webView.superview` | inherited from `NSView` ✓ |
| 15 | `webView.url` | `CmuxBrowserView.url` ✓ |
| 15 | `evaluateJavaScript` | `CmuxBrowserView.evaluateJavaScript` ✓ |
| 14 | `WKDownload` type | **needs `CmuxDownload`** |
| 11 | `WKWebsiteDataStore` | **needs `CmuxDataStore`** |
| 9 | `webView.observe` | needs KVO on `url`, `title`, `estimatedProgress`, `canGoBack`, `canGoForward`, `isLoading`, `fullscreenState`; add Combine `@Published` mirrors to `CmuxBrowserView` |
| 8 | `webView.evaluateJavaScript` | ✓ |
| 8 | `webView.cmuxInspectorObject` | **custom extension; needs migration plan, see below** |
| 7 | `WKScriptMessage` | ✓ |
| 7 | `WKNavigationAction` | ✓ |
| 5 | `WKNavigation` | ✓ |
| 5 | `webView.pageZoom` | **needs `CmuxBrowserView.pageZoom`** |
| 5 | `webView.isLoading` | ✓ |
| 5 | `webView.configuration` | not a 1:1 — config is immutable in the wrapper; callers reading config at runtime need a new accessor |

## Custom `WKWebView` extensions in `CmuxWebView.swift`

`CmuxWebView` adds cmux-specific properties via `extension WKWebView`. Each must move to `CmuxBrowserView`:

- `cmuxBrowserPanelForceRenderingStateRefresh`
- `cmuxBrowserPanelNotifyHidden`
- `cmuxBrowserPanelReattachRenderingState`
- `cmuxInspectorFrontendWebView`
- `cmuxInspectorObject`
- `cmuxIsElementFullscreenActiveOrTransitioning`
- `cmuxIsManagedByExternalFullscreenWindow`
- `onContextMenuDownloadStateChanged`
- `onContextMenuOpenLinkInNewTab`

Most of these are coordination hooks the host calls to nudge rendering state during workspace churn. They're not a 1:1 with WKWebView; they're cmux's own protocol over the engine. Cleanest path: a `CmuxBrowserViewLifecycle` protocol that both backends implement, and these stay on `CmuxBrowserView` itself.

## `WKWebViewConfiguration` flags actually consumed

Live config flags read from cmux code (drives what `CmuxBrowserConfiguration` must expose):

| WK flag | Cmux equivalent | Status |
|---|---|---|
| `defaultWebpagePreferences.allowsContentJavaScript` | (TBD) `CmuxBrowserConfiguration.allowsContentJavaScript` | missing |
| `preferences.isElementFullscreenEnabled` | hard-coded `true` in `WebKitBrowserBackend` | promote to config |
| `preferences.setValue(forKey:)` | not a public WK API; cmux uses it for `developerExtrasEnabled` etc. | replace with explicit named flags |
| `mediaTypesRequiringUserActionForPlayback` | `CmuxBrowserConfiguration.mediaTypesRequiringUserActionForPlayback` ✓ | done |
| `processPool` | `processPoolTag` (semantic, not identity) | partial |
| `requestCachePolicy` | (TBD) `CmuxBrowserConfiguration.requestCachePolicy` | missing |
| `timeoutIntervalForRequest` | (TBD) | missing |
| `timeoutIntervalForResource` | (TBD) | missing |
| `userContentController` | ✓ | done |
| `websiteDataStore` | ✅ `CmuxBrowserConfiguration.dataStore` (s2) | shipped |
| `websiteDataStore.httpCookieStore` | ✅ `CmuxDataStore.cookieStore` (s2) | shipped |
| `connectionProxyDictionary` | (TBD — not yet used) | missing |

## Migration order recommended

Driven by what unblocks the largest BrowserPanel callsite groups first:

1. ✅ **KVO/Combine mirrors on CmuxBrowserView** — unblocks the 9 `webView.observe` sites. Done in session 1: `CmuxBrowserState` with `@Published url/title/isLoading/estimatedProgress/canGoBack/canGoForward/pageZoom`. KVO observations push to state.
2. ✅ **`pageZoom`** — unblocks 5 sites. Done in session 1: `CmuxBrowserView.pageZoom` getter/setter, mirrored on `state.pageZoom`.
3. ✅ **`CmuxDataStore` + `CmuxCookieStore`** — unblocks ~25 sites across config and cookie reads. Done in session 2: factories (`.default()`, `.nonPersistent()`, `.forIdentifier(_:)`), `removeData(ofTypes:modifiedSince:)`, cookie store with get/set/delete/observer. `CmuxBrowserConfiguration.dataStore` is plumbed.
4. ✅ **`CmuxDownload` + `CmuxDownloadDelegate`** — unblocks the download flow. Done in session 2: per-WKDownload shim with strong refs cleared in terminal callbacks; `CmuxNavigationDelegate.didBecome download` extensions for both nav-action and nav-response.
5. ⏳ **`CmuxInspector` + the `cmuxInspector*` extensions** — last because the inspector is its own subsystem. NOT done.
6. ✅ **`CmuxSnapshotConfiguration`** — for high-DPI snapshots used by `cmux browser screenshot`. Done in session 2: rect/snapshotWidth/afterScreenUpdates bridged to `WKSnapshotConfiguration`.

## Non-Browser callsites of WKWebView

Outside `BrowserPanel`, these surfaces also use WKWebView and are out of scope for the engine swap (they stay on WebKit):

| File | Why it stays |
|---|---|
| `Sources/Panels/MarkdownPanelView.swift` | Renders local markdown; no need for Chromium |
| `Sources/Panels/MarkdownWebRenderer.swift` | Same |
| `Sources/Panels/ReactGrab.swift` | React DevTools hook; built around WebKit's JSCore |
| `Sources/AppDelegate.swift` | Settings sheet; trivial |
| `Sources/CmuxTopProcessDetails.swift` | Read-only diagnostic page |
| `Sources/FileDropOverlayView.swift` | Pure WK drag-and-drop hit-test |
| `Sources/Workspace.swift` | Touches `WKProcessPool` for shared cookies; revisit during data-store work |

## Out of audit scope (deferred)

- `Sources/Panels/BrowserPopupWindowController.swift` (popups) — needs `CmuxBrowserPopupWindowController` thin shim; defer until `CmuxUIDelegate.createBrowserViewWith` is exercised end-to-end
- `Sources/Panels/BrowserWebAuthnSupport.swift` — Chromium's WebAuthn is feature-complete; need to verify behavior parity with WebKit's `ASAuthorizationController` bridge before flipping
- `Sources/Find/BrowserFindJavaScript.swift` — find-in-page is a separate subsystem; Chromium has a native find API to bind in `CmuxBrowserView.find(text:options:completion:)`
