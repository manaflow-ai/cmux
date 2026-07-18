# Engine-neutral omnibar abstraction for cmux — refactor plan

(Architect's plan; all file:line references verified against the worktree /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cef-panes.)

## 0. Findings — what the omnibar is

**Layer A — already engine-neutral, reusable with zero changes:**
- `OmnibarState` / `OmnibarEvent` / `OmnibarEffects` / `omnibarReduce` — pure reducer, Sources/Panels/BrowserPanelView.swift:3676-3853.
- `OmnibarSuggestion` — value type, BrowserPanelView.swift:3855-4014 (only external type: `BrowserHistoryStore.Entry`, typealias at Sources/Panels/BrowserPanel.swift:1247).
- `OmnibarNativeTextField` — NSTextField subclass keyed by panelId + closures, BrowserPanelView.swift:4056-4266.
- `OmnibarTextFieldRepresentable` + Coordinator — panelId + bindings + 13 closures; only outward dep is `shouldSuppressWebViewFocus: () -> Bool`, BrowserPanelView.swift:4268-5029.
- `OmnibarSuggestionsView` — pure SwiftUI, BrowserPanelView.swift:5091-5407, incl. popupHeight(for:) at 5149.
- `BrowserOmnibarNativeFieldRegistry` / `BrowserOmnibarInteractionView` / `BrowserOmnibarInteractionRepresentable` — keyed by UUID, Sources/Panels/BrowserOmnibarAppKitBridge.swift:12-260. Works for CEF unchanged.
- Pure suggestion building/ranking/inline completion: `OmnibarInputIntent`, `buildOmnibarSuggestions`, `omnibarPreferredAutocompletionSuggestionIndex`, `omnibarInlineCompletionForDisplay`, `omnibarPublishedBufferTextForFieldChange` — BrowserPanelView.swift:2969-3648, plus `OmnibarInlineCompletion` at 287-297.
- Submit decision: `OmnibarLiveFieldSnapshot` / `omnibarSubmitDecision` — Sources/Panels/BrowserOmnibarSubmitSupport.swift:6-54.
- `OmnibarSuggestionRefreshScheduler`, `BrowserOpenTabSuggestionIndex`, `TabManager.matchingOpenBrowserTabSuggestions` — Sources/Panels/BrowserOmnibarPerformanceSupport.swift (:157, :55).
- Keyboard routing: `browserOmnibarSelectionDeltaForControlNavigation` / `browserOmnibarShouldSubmitOnReturn` — Sources/App/ShortcutRoutingSupport.swift:7,83.
- `BrowserHistorySuggestionEngine` is stateless/pure (Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/History/BrowserHistorySuggestionEngine.swift:14-41). CmuxBrowser/Omnibar/PageFocus/* is WK-only and NOT needed for CEF.

**Layer B — glue inlined in BrowserPanelView (must become ONE shared implementation). All panel-typed deps:**
- `refreshSuggestions()` (2695-2838): panel.historyStore.recentSuggestions/suggestions(for:limit:) (2728, 2730, 2819), panel.resolveNavigableURL(from:) (2749, 2822), panel.workspaceId / panel.id / panel.preferredURLStringForOmnibar() / panel.pageTitle (2852-2871).
- `handleOmnibarSubmit`/`commitSuggestion` (2499-2543): panel.navigateSmart(_) (2516, 2537), AppDelegate.shared?.tabManager?.focusTab for .switchToTab (2535).
- `deleteSelectedSuggestionIfPossible` (2611-2619): panel.historyStore.removeHistoryEntry(urlString:) (2617).
- `handleAddressBarFocusedChange` (1004-1049): panel.preferredURLStringForOmnibar() (1011), panel.beginSuppressWebViewFocusForAddressBar() (1015), panel.endSuppressWebViewFocusForAddressBar() (1033), notifications .browserDidFocusAddressBar/.browserDidBlurAddressBar keyed by panel.id.
- `applyOmnibarEffects` (2890-2966): the only engine-specific block is .shouldBlurToWebView handoff at 2903-2964 (panel.webView, clearWebViewFocusSuppression, noteWebViewFocused, restoreAddressBarPageFocusIfNeeded).
- `applyPendingAddressBarFocusRequestIfNeeded` (2120-2203): pendingAddressBarFocusRequestId / pendingAddressBarFocusSelectionIntent / acknowledgeAddressBarFocusRequest (BrowserPanel.swift:2918-2919, requestAddressBarFocus at 7502).
- `autoFocusOmnibarIfBlank` (2360-2409): panel.shouldSuppressOmnibarAutofocus() (2386), panel.webView.isLoading (2393), blank check (2356-2358).
- `syncURLFromPanel` (2068-2072), `setAddressBarFocused` (1972-1999, noteAddressBarFocused at 1997).
- `canHandleOmnibarSelectionNavigation` (1953-1966): panel.webView.window fallback + browserOmnibarField(panelId:in:).

**Layer C — chrome view:** addressBar (1226-1284, width/height preference keys, compactChromeWidthThreshold/isChromeCompact at 437-441), nav buttons (1286-1352), pill + badge + interaction overlay (omnibarField 1699-1791), `BrowserChromeStyle` + free funcs (299-371), BrowserChromeMetrics (own file). WK-only accessories mixed in: downloads (1340-1350), PDF (1334-1338), screenshot/react-grab/devtools/profile/theme/focus-mode/overflow (1238-1253).

**Layer D — suggestions overlay presentation:** `BrowserPortalOmnibarSuggestionsConfiguration` (Sources/BrowserPortalOmnibarSuggestionsConfiguration.swift:3-14 — NO WKWebView anywhere), `BrowserPortalOmnibarSuggestionsOverlay` (24-line wrapper), `BrowserPortalOmnibarSuggestionsHostingView` (Sources/BrowserPortalOmnibarSuggestionsHostingView.swift:4-19). Mounted by WindowBrowserSlotView.setOmnibarSuggestions as an AppKit subview above the hosted WKWebView (Sources/BrowserWindowPortal.swift:1403-1445, sort priority 2 at 1678). Registry entry point is WKWebView-keyed (updateOmnibarSuggestions(for: WKWebView, ...) → webViewToWindowId, 3891-3899; entriesByWebViewId 1758-1780). Anchor math: pill frame in "BrowserPanelViewSpace" via OmnibarPillFramePreferenceKey (1782-1790, 3649-3657); portal frame = pillFrame shifted by maxY + 3 − addressBarHeight (597-608).

**History write path (WK):** didFinish → boundHistoryStore.recordVisit(url:title:) (BrowserPanel.swift:3766-3776, write at 3774); typed navigations → historyStore.recordTypedNavigation(url:) (BrowserPanel.swift:5778). Store is profile-scoped: BrowserProfileStore.shared.historyStore(for: resolvedProfileID) (BrowserPanel.swift:3957, 4616; adapter 293-316, 433-435). recordVisit filters non-http(s), TLD-less hosts, about:blank (1338-1352).

**CEF pane today:** CEFBrowserPanel exposes currentURL/title/isLoading/canGoBack/canGoForward (Sources/Panels/CEFBrowserPanel.swift:17-21), navigate/goBack/goForward/reload (80-110), setAddressFieldFocused (148-153), delegate callbacks (155-189). CEFBrowserPanelView is a bare toolbar (13-71) + NSViewRepresentable (95-107). CEFBrowser has stopLoad() (CEFBrowser.swift:223) and setFocus(_:) (236).

## 1. Protocol shape

`OmnibarHostingPanel` (new file Sources/Panels/Omnibar/OmnibarHostingPanel.swift). @MainActor, class-bound, refining ObservableObject. Members map 1:1 onto BrowserPanel:

```swift
@MainActor
protocol OmnibarHostingPanel: AnyObject, ObservableObject {
    var id: UUID { get }
    var workspaceId: UUID { get }                          // BrowserPanel.swift:2740; CEF: add stored property
    var omnibarDisplayURL: URL? { get }                    // BrowserPanel.currentURL (2784); CEF: URL(string: currentURL)
    var pageTitle: String { get }                          // 2850; CEF: title
    var isLoading: Bool { get }                            // 2856
    var canGoBack: Bool { get }                            // 2874
    var canGoForward: Bool { get }                         // 2877
    var isOmnibarVisible: Bool { get }                     // 2923; CEF: true
    func navigateSmart(_ input: String)                    // 5841; CEF: navigate(to:)
    func resolveNavigableURL(from input: String) -> URL?   // 5855; CEF: URL(string: normalizedURLString(_:))
    func goBack(); func goForward(); func reload(); func stopLoading()  // CEF stopLoading → browser.stopLoad()
    func preferredURLStringForOmnibar() -> String?         // 7788; CEF: currentURL unless about:blank → nil
    var historyStore: BrowserHistoryStore { get }          // 2743
    var pendingAddressBarFocusRequestId: UUID? { get }     // 2918
    var pendingAddressBarFocusSelectionIntent: BrowserAddressBarFocusSelectionIntent { get }  // 2919
    func acknowledgeAddressBarFocusRequest(_ id: UUID)
    @discardableResult
    func requestAddressBarFocus(selectionIntent: BrowserAddressBarFocusSelectionIntent) -> UUID  // 7502
    func beginSuppressContentFocusForAddressBar()          // wraps beginSuppressWebViewFocusForAddressBar
    func endSuppressContentFocusForAddressBar()            // 7492
    func shouldSuppressContentFocus() -> Bool              // 7465
    func shouldSuppressOmnibarAutofocus() -> Bool          // 7458
    func noteAddressBarFocused()                           // BrowserPanelView.swift:1997 call site
    var isContentBlankForOmnibar: Bool { get }             // WK: preferredURLStringForOmnibar()==nil (2356-2358)
    var isContentNavigationInFlight: Bool { get }          // WK: webView.isLoading (2393); CEF: isLoading
    func performAddressBarExitFocusHandoff(onComplete: @escaping @MainActor (Bool) -> Void)  // WK: 2903-2964 moved verbatim into BrowserPanel; CEF: browser?.setFocus(true) + completion
    var omnibarHostWindow: NSWindow? { get }               // WK: webView.window; CEF: containerView.window
}
```

Shared controller state: new `struct OmnibarPaneChrome<TrailingAccessories: View, LeadingExtras: View>: View` owning the @State currently on BrowserPanelView (omnibarState, addressBarFocused, inlineCompletion, omnibarSelectionRange, omnibarHasMarkedText, suppressNextFocusLostRevert, omnibarSelectAllRequestId, pendingFocusGainedSelectionIntent, lastHandledAddressBarFocusRequestId, scheduler + tasks, pill frame / bar height / width — declared at 394-446), generic over any OmnibarHostingPanel, reporting suggestions presentation outward via `onSuggestionsPresentationChange: (BrowserPortalOmnibarSuggestionsConfiguration?) -> Void`.

## 2. Exact extraction table (new files in Sources/Panels/Omnibar/, verbatim moves, wire pbxproj)

| New file | Moves (BrowserPanelView.swift lines) |
|---|---|
| OmnibarCore.swift | OmnibarState/Event/Effects/omnibarReduce (3676-3853); OmnibarSuggestion (3855-4014); focus-decision free funcs (4016-4054) |
| OmnibarSuggestionBuilding.swift | OmnibarInlineCompletion (287-297); OmnibarInputIntent + pure builders/rankers (2969-3648) |
| OmnibarNativeTextField.swift | 4056-4266 |
| OmnibarTextFieldRepresentable.swift | 4268-5029 + browserOmnibarPanelId/browserOmnibarField/browserPrepareOmnibarForProgrammaticBlur (5031-5089) + browserOmnibarTextFieldIdentifier (12) |
| OmnibarSuggestionsView.swift | 5091-5407 |
| OmnibarPaneChrome.swift | address bar layout (1226-1284), nav buttons core (1286-1333), pill/omnibarField (1699-1791), preference keys (3649-3674), compact threshold (437-441), glue: handleAddressBarFocusedChange (1004-1049), omnibar handlers (2453-2609), deleteSelectedSuggestionIfPossible (2611-2619), refreshInlineCompletion (2685-2693), refreshSuggestions (2695-2838), open-tab/UITest helpers (2840-2888), applyOmnibarEffects (2890-2966, blur branch → panel.performAddressBarExitFocusHandoff), syncURLFromPanel (2068-2072), autoFocusOmnibarIfBlank (2360-2409), applyPendingAddressBarFocusRequestIfNeeded (2120-2203), setAddressBarFocused (1972-1999), canHandleOmnibarSelection* (1953-1970), refresh consumer (2476-2497), receivers (1051-1066, 893-903) |
| BrowserChromeStyle.swift | color funcs + BrowserChromeStyle (299-371) |

Accessory slots: leadingAccessories (WK: PDF 1334-1338 + downloads 1340-1350), trailingAccessories (WK: focus-mode/screenshot/react-grab/profile/theme/devtools/overflow, 1234-1254 — stay in BrowserPanelView, passed in). CEF passes minimal accessories (+ the new extension bar). Suggestions presentation stays OUTSIDE the shared view: WK keeps portalOmnibarSuggestions (610-629) + SwiftUI fallback (1098-1119); CEF mounts the hosting view in its own host container.

Reused as-is: BrowserOmnibarAppKitBridge.swift, BrowserOmnibarSubmitSupport.swift, BrowserOmnibarPerformanceSupport.swift, ShortcutRoutingSupport.swift, BrowserChromeMetrics.swift, the three BrowserPortalOmnibarSuggestions* files.

## 3. History for CEF

- Same store, profile-scoped: CEFBrowserPanel gets profileID: UUID (default browser profile) + historyStore = BrowserProfileStore.shared.historyStore(for: profileID) (same accessor as BrowserPanel.swift:433-435, 3957).
- recordVisit on isLoading true→false transition in the loading-state delegate callback (CEFBrowserPanel.swift:166-176); recordVisit already dedupes/filters.
- recordTypedNavigation in navigate(to:) for typed submissions.
- historyStore.loadIfNeeded() in shared chrome appear path (parity with BrowserPanelView.swift:826).
- Open-tab suggestions publishing (BrowserOmnibarPerformanceSupport.swift:274) optional follow-up. Remote suggestions are panel-independent.

## 4. Suggestions overlay for CEF

Mount `BrowserPortalOmnibarSuggestionsHostingView` as an AppKit SIBLING above the CEF container inside new `CEFBrowserHostView: NSView` (Sources/Panels/CEFBrowserHostView.swift): bottom→top = CEFBrowserContainerView, then (when configuration set) the hosting view pinned to edges — ~50-line transliteration of WindowBrowserSlotView.setOmnibarSuggestions (BrowserWindowPortal.swift:1403-1445). Overlay must be a sibling ABOVE the container, not a subview of it (container layout() force-frames subviews; CEF owns that subview list). Popup frame math: y = pillFrame.maxY + 3 − addressBarHeight (597-608), height = OmnibarSuggestionsView.popupHeight(for:) (5149). Do NOT touch BrowserWindowPortal.swift or register CEF in the portal registry. Fallback if z-order fails empirically: child NSPanel modeled on Sources/TextBoxInput.swift:4579-4610.

## 5. Ordered steps (riskiest first)

1. Extract OmnibarPaneChrome + OmnibarHostingPanel; re-adopt in BrowserPanelView (replace omnibarHeaderView/addressBar/omnibarField at 1121-1127, 1226-1352, 1699-1791; blur handoff 2903-2964 → BrowserPanel.performAddressBarExitFocusHandoff). Gate: WK omnibar behavior byte-identical.
2. Mechanical Layer-A file splits (separate commit).
3. CEF z-order check inside CEFBrowserHostView.
4. CEFBrowserPanel conformance (promote normalizedURLString at CEFBrowserPanel.swift:249-266 into resolveNavigableURL; stopLoading → browser?.stopLoad(); focus plumbing copied from BrowserPanel.swift:2918-2919/7502; suppress witnesses over setAddressFieldFocused 148-153).
5. History wiring for CEF.
6. Rebuild CEFBrowserPanelView around OmnibarPaneChrome + CEFBrowserHostView; keep the mouse-down panel-focus monitor (95-153).
7. Entry-point audit: Cmd+L (AppDelegate.swift:14350-14356, ContentView.swift:9398, Workspace.swift:2963, 9616 — cast to protocol); panelType == .browser guard at BrowserPanelView.swift:2124 must accept .cefBrowser. Ctrl+N/P already panelId-keyed.
8. Unit tests: CEF conformance (typed-navigation record, loading-transition record).

## 6. Do NOT touch (WK zero-risk list)

- Sources/BrowserWindowPortal.swift — all of it.
- WebViewRepresentable + portal update call sites (BrowserPanelView.swift:5409-7956, updateOmnibarSuggestions at 7626/7662/7710/7741) and portalOmnibarSuggestions/omnibarSuggestionsFrameInPortal (597-629) beyond re-pointing inputs.
- OmnibarNativeTextField / OmnibarTextFieldRepresentable / BrowserOmnibarAppKitBridge.swift BEHAVIOR — verbatim moves only (focus state machines 4414-4505, 4649-4676 are the most regression-prone code).
- BrowserPanel navigation/focus internals — conformance is additive; no renames.
- Typing-latency instrumentation (CmuxTypingTiming) and BrowserOmnibarPerformanceSupport debounce semantics.
- WK-only chrome features (find overlay, focus mode, downloads, PDF, devtools, profile/theme menus, import hints, recovery overlay) — remain in BrowserPanelView, flow through accessory slots.
