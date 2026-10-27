# p13-webui: cmux pages work like Chrome WebUI

Program spec, final (the fixer pass over the design and 3 reviews). Base: perf/chrome-parity at 772cdfc45ac
(= origin/feat-cmux-next). P = `Packages/macOS/CmuxNext/Sources`. Counts come from `git grep` at that commit.
The fixer checked each count again on 2026-10-25; those counts say "(checked)".

Scope in one sentence: every first-party page (Settings, History, New Tab, chats, viewers and the rest) shares
a renderer with the pages of the same capability, is built only when it shows, is told when it is hidden,
freezes and later discards when it is off screen (with Chrome's keep rules), never wakes the app or the daemon
while hidden, and Home idle holds at most one frozen preload in one renderer (fault F3, perf-lead.md issues 9
and 15).

Owned faults: F3 (Home footprint and idle renderers). Shared: F1/F2 for page windows (with PL-cef-layer and
PL-cefhost), issue 15 renderer sharing (with PL-memory), issue 9 acpmux polling (with PL-acpmux).

How this spec changed after review (summary; details are in each section):

- Process groups follow capability, not "renders untrusted text". The design's `content` group put the agent
  page (`shell.run`, `git.push`, `git.commit`, `git.worktree.apply`, `pane.saveFile`, `harness.restart`;
  AgentPageProvider.swift:35-43, checked) in one renderer with markdown and changelog, which render repository
  files and remote media. That made isolation weaker than today. Groups are now `agent`, `privileged`,
  `viewer`, `solo` and `secrets`, and a unit test computes them from each descriptor's ops (task 087).
- Sharing a renderer across page origins needs Chrome's WebUI TLD lock rule, not GetEffectiveURL. Chrome
  computes the process lock from the real URL (`site_info.cc`: `GetAgentClusterKeyForURL(..., /*effective_url=*/
  std::nullopt)`; `MakeProcessLockComparisonKey` leaves out `site_url_` on purpose; checked on
  chromium.googlesource.com). Chrome shares WebUI renderers through `IsWebUIAndUsesTLDForProcessLockURL`
  (`chrome://foo.bar/` locks to the last label). A fork spike (091) proves the mechanism before 011.
- Chrome never freezes WebUI (`CannotFreezeReason::kWebUI`; also `kLoading`, `kRecentlyVisible`,
  `kMostRecentlyUsed`; checked). cmux freezes pages anyway, with a written reason (section 3.C) and with those
  three Chrome reasons added as keep reasons.
- No custom JS lifecycle stream. Pages use `document.visibilityState` and the standard `freeze`/`resume` events
  (45 sites already use visibility, checked). Native guarantees the order.
- The snapshot and the page state are taken when the page hides, not at discard. A frozen page cannot answer a
  save call, so the design's discard would always time out and never discard.
- The preload loads visible off screen, keeps its first frame as a cover, then hides and freezes, as Chrome's
  WebUIContentsPreloadManager does. A spike (090) picks frozen versus rendered-parked. D4 is split into key to
  cover frame and key to live frame.
- Leaks found by review and confirmed in code: 4 page providers (Keybindings, Passwords, MobilePairing,
  ChiefInspector) have no `tabClosed` and use the no-op default (InternalPage.swift:83), and
  BrowserAppTopPages.tabClosed sets `pages[key] = nil` without close (checked). CEFPaneHost removes only popup
  hosts from `runtime.hosts` (CEFPaneHost.swift:412, checked), so every page key `cmux-page-<UUID>` stays.
  Tasks 061 and 062 fix them.
- Wrong counts fixed: `PageWebView(` outside CmuxNextPages is 22, not 21; rAF hits are 57, not 66; Settings has
  0 `lazy(` sites, not 79 (all of webviews/src has 8). The Settings lazy split must be built (081).
- More ambitious (the user asked for this): page tabs share one Chromium window per pane (063), page teardown
  leaves the Cmd-W turn (064), frozen pages stop their native sources and daemon relays (066, 067), the old
  agent host is deleted (073), a Mojo-like push channel (079, lands only with a measured gain), renderer
  priority and purge (083), and a census of Chrome runtime idle services (084).

## 1. Chrome reference

Paths are in chromium/src at main.

1. WebUI process model. `docs/process_model_and_site_isolation.md`: WebUI is "strictly isolated from non-WebUI
   pages as well as other types of WebUI pages (based on site)". The local NTP is a WebUI page in process-per-site
   mode, so every NTP shares one process. `content/browser/site_info.cc`: the process lock comes from the real
   URL's AgentClusterKey; an effective URL (ContentBrowserClient::GetEffectiveURL) changes only `site_url`, and
   `MakeProcessLockComparisonKey` does not compare `site_url` ("those include effective URLs which may differ even
   if the actual document origins match"). `IsWebUIAndUsesTLDForProcessLockURL`: a WebUI host with two or more
   labels (`chrome://foo.bar/`) locks to its last label, "allowing WebUI with a shared TLD to share a
   RenderProcessHost". Top-chrome WebUIs use this (`tab-search.top-chrome`, `chrome/common/webui_url_constants.h`
   kChromeUITopChromeDomain). Embedder hooks: `ContentBrowserClient::GetAdditionalWebUISchemes`,
   `ShouldUseProcessPerSite`, `ShouldAllowProcessPerSiteForMultipleMainFrames`, and the feature
   `ProcessPerSiteUpToMainFrameThreshold` (`content/public/common/content_features.cc`; HTTP(S) sites only, see
   `GetProcessReusePolicyForMainFrame` in `render_frame_host_manager.cc`).
   Untrusted content goes in `chrome-untrusted://` documents, never in a process with stronger bindings.
2. Preloading WebUI. `chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.h`: "At anytime, at most
   one WebContents is preloaded across all profiles". The preload is made visible so that resources load at once,
   and is hidden when the page signals ready (`kPreloadTopChromeWebUIHideWhenReady`: while visible it keeps the
   shared renderer at foreground priority). It is never frozen. `MaybePreloadForBrowserContextLater` waits for
   the first non-empty paint or a 3 s deadline. No preload under heavy memory pressure.
   `TopChromeWebUIConfig::SupportsInProcessResourceLoadingV2`: resources load without a browser UI-thread round
   trip.
3. Spare renderer. `content/browser/renderer_host/spare_render_process_host_manager_impl.h`: a live renderer with
   no site lock and no document, default StoragePartition only. On desktop, WarmupSpare has no destroy timeout
   (`StartDestroyTimer` applies only with the Android feature `kAndroidWarmUpSpareRendererWithTimeout`), and
   `kKillSpareRenderOnMemoryPressure` is disabled by default; memory pressure only blocks a new spare. The design
   cited a 5 min timeout and kill-on-pressure as Chrome behavior; that was wrong. cmux's choice in task 020 is a
   cmux decision with a measurement. `WebContents::CreateParams::desired_renderer_state = kNoRendererProcess`
   makes a WebContents with no renderer ("tab discarding and session restore").
4. Hidden, frozen and discarded. `content/public/browser/web_contents.h`: WasHidden, SetPageFrozen (only while
   hidden), Discard (keeps the NavigationEntry PageState and session storage; the page sees
   `document.wasDiscarded`). `third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc`:
   hidden timers aligned (kDefaultThrottledWakeUpInterval), intensive throttling, background freezing after
   1 min. `components/performance_manager/public/freezing/cannot_freeze_reason.h` (checked): kVisible,
   kRecentlyVisible, kAudible, kRecentlyAudible, kHoldingWebLock, kHoldingIndexedDBLock, devices, capture,
   kWebRTC, kLoading, kNotificationPermission, kOptedOut, kMostRecentlyUsed, kWebUI.
   `components/performance_manager/policies/page_discarding_helper.cc`: one urgent-discard pass over every page,
   sorted by importance, stops at the reclaim target, protects recently visible pages.
   `discard_eligibility_policy.cc`: kFormInteractions and kUserEdits come from Blink for every page.
5. Lazy WebUI. `chrome/browser/resources/settings/lazy_load.ts` loads late sections after the first render.
   `docs/webui/webui_build_configuration.md`: bundle, minify, `generate_code_cache`. WebUI handlers get
   `WebUIMessageHandler::OnJavascriptAllowed/OnJavascriptDisallowed`, so a handler stops its observers while the
   page cannot take messages. Newer WebUI pages get data over Mojo page handlers, not script evaluation.
6. Process priority. `RenderProcessHostImpl::UpdateProcessPriority` backgrounds a renderer whose widgets are all
   hidden; on macOS it needs the child task port (MachPortRendezvous). WebKit: ProcessThrottler.

## 2. cmux today

All counts are at 772cdfc45ac.

Pages and hosts:
- 22 `PageDescriptor` statics (checked): agent, agentActivity, keybindings, chiefInspector, iconPicker,
  homeChannels, mobilePairing, passwords, debugSettings, chiefViews, chiefUsage, diff, markdown, editor, cloud,
  settings, apps, coderouter, changelog, files, history, stats. There is no `newtab` descriptor: New Tab is the
  `agent` descriptor.
- 28 `InternalPageProvider` types (checked).
- 22 `PageWebView(` sites in P outside CmuxNextPages (checked), plus 2 in CmuxNextAppTests.
- 17 React pages from `scripts/cmux-next/build-pages-web.sh` (checked: history apps coderouter cloud keybindings
  icon-picker settings passwords changelog files stats chief-usage chief-views mobile-pairing chief-inspector
  home-channels debug-settings). Each is one index.html with inline JS: no shared chunk, no code cache.
- Settings has 0 `lazy(` sites (checked). All of webviews/src has 8.
- diff, markdown and editor come from the webviews-app Vite build; agent-activity has its own build; the agent
  pane (146,987 TS lines) is split.
- 291 `cmux-page://` literals in 178 files (checked).
- `webviews/src/web-abi.json` gates OTA web updates by native interface version (web-ota.md).

Engine and process:
- `browser.defaultEngine` picks the engine of every page (CmuxNextPages/PageEnginePolicy.swift). Agent pages use
  Chromium by default.
- Every PageWebView allocates a WKWebView even in Chromium mode (PageWebView.swift:273).
- Each Chromium page: its own CEF window (pane key `cmux-page-<UUID>`, ChromiumPageHost.makePage), built on the
  main thread at open (CEFSpareWindow.take refuses off-the-record keys); its own renderer (each page id is its
  own site); and its own DevTools session (17 `devTools(` sites in CmuxNextPages, checked:
  ChromiumPageHostBridge 76/97/149/166, PageChromiumHosting 78, PageWebView+Chromium 117/194/303/312,
  +ChromiumMenu 58/67, +Debug 160/189/226, +EngineNeutral 28, +Evaluate 36, +WindowImage 14). On the pinned fork
  (`cef-154.0.28-cmux.28`, API 24) a DevTools agent ends renderer reuse (CEFSwitches processReusePerRendererDevTools).
  Renderer paths need API 29 (CEFForkFeatures.rendererPathsForkAPI, checked).
- Before API 29, CEFAgentRelay.browserAttached (line 131) attaches media, verification and first-paint DevTools
  bridges to every tab, page tabs included. From API 29, CEFDocumentScripts installs browser-tab scripts in
  every renderer, page renderers included.
- WebKit: each page makes its own `WKWebsiteDataStore.nonPersistent()` (PageWebView+Pooled.swift), so each page
  has its own WebContent process. Two WKProcessPools exist: `PageProcessPool.shared` and
  `AgentPaneView.processPool` (AgentPaneView.swift:112). The agent pool saves about 25 ms of a 30 ms page build
  (registerUserInstalledFonts once per pool, R81 trace; AgentPaneView.swift:108-112). Only agent pages share a
  process (WebProcessGroups, `_setRelatedWebView:`, 8 per process).
- The old agent host (its own AgentPaneWKWebView, AgentPaneSchemeHandler) runs only when both tunables
  `agent.pageHost` and `agent.chromium` are off (AgentTabs.swift:497, checked).

Spares and warmers: 4 warmers and 3 memory-pressure observers in scope (BrowserHibernation, NewTabSparePool,
PageHostPool+Build; checked).
1. CEFSpareWindow: a default-profile window with a live about:blank renderer, frozen through DevTools
   (CEFTab+Freeze.swift freezeNeverShownPage), which also attaches a DevTools agent.
2. NewTabSparePool (380 lines): a full agent page at alpha 0, 100,000 pt off window, never told it is hidden, not
   frozen. NowPlayingPlayer.tsx and NewTabExtras.tsx tick at 1 Hz in it.
3. PageHostPool: builds a WebKit Settings spare from noteLikely() at launch even when pages use Chromium.
4. AgentPaneView.startWarmup: a WebKit blank page until LaunchSettle, even in Chromium mode.

Lifecycle:
- TabContentCache.lifecycle (ContentLifecycle) is "the only source of show and hide for terminal surfaces and
  pages" (TabContentCache.swift, checked). AgentPaneVisibilityProbe is a second source.
- Browser tabs freeze and discard (BrowserHibernation). PL-memory landed Memory Saver keep rules (before_unload,
  web_rtc, connected_device, form input, audio, capture) in CmuxNextHibernation (perf-lead.md 2026-10-24).
- Agent chats are released by AgentPageHibernation (keep: pinned, shell command ran, waiting on the person,
  remote chat, minimum hidden 10 s). New Tab pages are exempt.
- TabContent.page (every other cmux page) has no freeze and no discard. PageRouter.deliver sends every event to
  hidden pages. WebKit page crashes reload at once even when hidden.
- AgentPaneFramePacer makes calls to hidden panes every 0.25 s (hiddenInterval, checked).
- Pushes that skip the router: 33 `evaluate(`/`evaluateJavaScript(`/`callAsyncJavaScript(` sites in
  CmuxNextPages and CmuxNextAgentPane (checked): theme, GlassBackdropFeed wallpaper, interface scale, uiPointer,
  dictation, transport.
- PageRelayChannel keeps a `private static var channels` (PageRelayChannel.swift:33, checked); each daemon
  connection keeps `subscribe(treeEvents: .coarse)` for the whole run. In cmux-tui, each page-relay subscribe
  receives every MuxEvent (SurfaceOutput too) and builds JSON before it drops non-page events.
- JS: 13 `setInterval(` and 107 `setTimeout(` sites in webviews/src/pages and agent-session; 120 `setTimeout(` in
  all webviews/src outside tests, galleries and prototypes; 57 `requestAnimationFrame(` in pages and
  agent-session (all checked). diff-viewer freshness.ts reads the repository every 4 s, shown or hidden.
- Close: see the leaks in the summary. PageWebView has a nonisolated deinit with no close.
- SettingsPageDomains `static let fontFamilies` and `static let sounds` (SettingsPageProvider.swift:415, 423,
  checked) enumerate fonts and /System/Library/Sounds on the main thread on first use.
- Global statics: 13 stateful statics in CmuxNextPages, CmuxNextAgentPane, CmuxNextApp/Pages and NewTab
  (checked, MQ10), plus PageProcessPool.shared.

Measured (speed-of-sound-DESIGN.md sections 5 and 7, perf-lead.md): Home has 3 Chromium renderers (185 MB,
1.78-2.02 % idle CPU; likely the about:blank spare, the New Tab spare and the built-in uBlock Origin MV2
background page; task 001 confirms), Home 793 MB whole tree against a floor of about 70 MB, a hidden WebKit page
wakes 11 times a second, a hidden Chromium tab is 55 MB. The pages area has no OWNERS row.

Existing tools to reuse: scripts/cmux-next/bench-pages.py, bench-settings.py, bench-idle.sh,
scripts/perf-bench/procs.py, bench_renderer_sharing.py (PL-memory), page-swap-visible-live.py,
page-hang-live.py.

## 3. Target design

### A. WebUIHost (P/CmuxNextPages/WebUI/)

- AppServices builds one `WebUIHost`. It replaces the statics `PageWebView.chromiumHosting`, `openPanel`,
  `PageRegistry`, `PageProcessPool`, `AgentPaneView.processPool/processGroups/sharedDataStore`,
  `PageRelayChannel.channels`, `WebDevOverrideWatcher.shared` and `WebBundleServedViews.shared` (MQ10).
- `open(PageOpenRequest)` is the only way to make a page view (22 sites move, MQ1). `close(view)` and
  `retire(view)` are the only ways to end one. The host tracks every page it opened, so a closed tab always
  ends its engine page whatever the provider does (MQ11).
- It owns: one WKProcessPool for every page and agent view (kept, not deleted: it saves about 25 ms per build),
  the process groups (B), the lifecycle controller (C), the single preload slot (D), the page relay channels,
  and one memory-pressure subscription shared with BrowserHibernation through one ranker (task 092).

### B. Process groups by capability

Group membership is computed from the descriptor's namespaces, nativeOps, actions, confirmedOps, CSP remote
sources and dynamic prefixes (task 087). Rule: a page may share a process only with pages of the same
capability class. Expected table (the test decides; if it disagrees, the test wins and 012 follows it):

| Group | Pages | Why |
| --- | --- | --- |
| `agent` | agent (New Tab and every chat; one origin `cmux-page://cmux.agent`) | Same op set on every instance, as Chrome's NTP process-per-site |
| `privileged` | settings, cloud, apps, coderouter, keybindings, debugSettings, mobilePairing, history, stats, chiefUsage | Write ops on app state, no repo text or remote content |
| `viewer` | markdown, files, iconPicker, chiefViews, homeChannels, agentActivity, chiefInspector | Read or display ops only; they render repo text or remote images |
| `solo` | diff (`git.push`), editor (file save), changelog (remote media) | Host-power or remote content with no peer of the same class: one process each, as today |
| `secrets` | passwords | Never shared; discarded 60 s after it hides |

Chromium mechanism (fork, through the shared fork train, task 086):
- The spike (091) builds both options: (A) the design's GetEffectiveURL plus ShouldUseProcessPerSite, and
  (B) Chrome's WebUI TLD lock rule: cmux-page is listed in GetAdditionalWebUISchemes, or the fork applies the
  same last-label rule to cmux-page. Hosts become `<page>.<group>` (for example
  `cmux-page://settings.privileged/`), built only in `PageDescriptor.origin`. Expected: A gives 3 processes for
  3 origins, B gives 1 with no bad-message kill. 011 implements the option that passes.
- If B wins, the origin rename is machine queue MQ15 (task 094). Page storage is off-the-record and WebKit
  stores are non-persistent, so no stored data needs migration. The OTA abi bump (071) covers it.
- The agent group needs the same fork code as the other groups. At 154.0.8037.98,
  `ProcessPerSiteUpToMainFrameThreshold` applies only to HTTP(S) sites (`render_frame_host_manager.cc`
  `GetProcessReusePolicyForMainFrame`, `kSchemeIsNotHttpOrHttps`), so it does not share `cmux.agent`. Its cap of 8 is
  011's embedder cap; the cmux-page entry in PL-memory's per-site sharing switch (web tabs: 2) holds the same value,
  reviewed by PL-memory, measured with bench_renderer_sharing.py (task 085). Spike 091 measures nine agent pages.
- The page bridge leaves DevTools (013, 014, 078): page channel `cmuxPageHost`, document scripts limited to
  cmux-page, tabEvaluate, a surface copy export (077) and native clicks. The host takes the sender's browser id,
  frame and committed origin from the CEF frame that delivered the message, never from the payload.
- Browser-tab document scripts and DevTools bridges never run in page tabs (068).
- Page tabs of one cmux pane share one Chromium window (063), with PL-cef-layer and PL-cefhost. Pages without a
  pane (update card, icon picker panel, preload) keep their own key. Hosts of closed pages are removed (062).

WebKit mechanism: one shared non-persistent data store per group, all views in the WebUIHost process pool,
`_setRelatedWebView:` per group (PageProcessGroups, moved from CmuxNextAgentPane/WebProcessGroups.swift), 8
pages per process, responds(to:) gated. The acceptance compares `_webProcessIdentifier` of two different page
ids of one group on macOS 26 and 27.

### C. Lifecycle: Active, Hidden, Frozen, Discarded

Why cmux freezes WebUI when Chrome does not (`kWebUI`): Chrome's WebUI handlers get backpressure from Mojo and
stop their observers in OnJavascriptDisallowed, and Chrome has few WebUI tabs. cmux has many page tabs per
session, each with a subscription stream and native pushes, and the targets ask for idle wakeups <= 1/s and
hidden memory near zero. The router hold (023), the provider freeze hooks (066) and the thaw-before-deliver rule
replace Mojo's backpressure. This reason goes into webui-DESIGN.md (task 004).

- One visibility source: PageLifecycle gets its show and hide from TabContentCache+Lifecycle (ContentLifecycle)
  for `.page` content and agent tabs. Window occlusion and app hide feed ContentLifecycle once per window.
  AgentPaneVisibilityProbe calls into it (070). No polling; one DemandTimer for the next deadline.
- The planner lives in CmuxNextHibernation next to HibernationPlanner, agreed with PL-memory, with one
  UrgentDiscardRanker for browser tabs, chats and pages (092).
- Hidden: the engine is told at once (Chromium setVisible(false); WebKit view `isHidden = true` in the window,
  with the hidden-page timer throttling and process suppression preferences). `visibilitychange` fires in the
  page. The page saves its state on hidden (sessionStorage and history.state on Chromium; a native-held blob of
  64 KB or less on WebKit). Native takes the snapshot of the last shown frame while the view is still attached
  (088). The router holds delivery.
- Frozen after 10 s hidden: Chromium SetPageFrozen (fork API 29; DevTools lifecycle state before it); WebKit
  stays hidden in the window and uses the `_suspendPage:` SPI when it exists and measures better (029). Window
  detach is used only if the spike shows hidden-in-window still wakes more than 0.2/s. Providers get
  `pageWillFreeze()` and stop their native sources; DaemonPageRelay cancels its listens (066). Thaw runs in the
  show's own turn, before the page is visible, then the held events go out as one batch.
- A built-in command or `evaluate()` to a frozen page (Cmd-F focusSearch, a palette page command) thaws the page
  in the same turn first, then delivers. No PageCallDeadline fires because of a freeze.
- Discarded after 300 s hidden (60 s at warning, 10 s at critical, by the ranker; never sooner than a number of
  minutes the person wrote in `browser.hibernation`, at each pressure as for browser tabs). The named modes keep
  timing browser tabs only: with the page-lifecycle controller on (022, default-off), an idle chat goes at 300 s
  where AgentPageHibernation waited 30 minutes ("moderate").
  Chromium in-place WebContents::Discard (018/031; close on older forks), WebKit drops the WKWebView. Discard
  makes no call into the page. The shell keeps descriptor, route, scroll, the state blob and the snapshot. Show draws the snapshot
  in the key's frame and loads behind it.
- Keep reasons. Block freeze and discard: visible, loading (until load and first paint), recentlyVisible (10 s),
  Web Inspector or DevTools open, focused, file drop pending, popup or confirmation sheet open, dictation or
  capture, an agent turn running (until acpmux can send a snapshot resync). Block freeze only: mostRecentlyUsed
  (the 1 most recently hidden page, discarded pages included, so a discard never hands the role to an older
  frozen page), as Chrome's kMostRecentlyUsed (components/performance_manager/public/freezing/cannot_freeze_reason.h)
  and D3's "all 9 hidden pages discarded at 300 s"; and `browser.freezeHiddenTabs` "off" (a number there times
  browser tabs; pages freeze at 10 s). Block discard only: userEdits and formInteraction (detected for every
  page, 089), beforeunload listener, an agent unsent draft or attachments, pinned (with the setting), a shell
  command ran, waiting on the person, a remote chat, and every PL-memory Memory Saver reason that applies. Page JS can only
  add keep reasons.
- Delivery policy per provider, a protocol requirement with no default: `.latest`, `.resync`, `.queue(limit)`
  or `.ordered` (never dropped; when the provider's own buffer is half full the page leaves Frozen but stays
  hidden). AgentPageProvider uses `.ordered`.
- Crashes: a renderer crash marks every page of its group. Shown pages reload once; hidden pages reload when
  shown. The crash budget (3 per 600 s) is per group.
- Web updates and dev overrides reload only shown pages; hidden and frozen pages are marked stale and reload when
  shown; a frozen page never blocks the swap; the previous tree's `_shared` files stay served while a document
  from that tree lives (071).

### D. One preload slot

- At most one preloaded page document in the app. It replaces NewTabSparePool, PageHostPool and
  AgentPaneView.startWarmup. PreloadSelector picks New Tab by default, or Settings, History or Cloud after a
  recent open; none under warning or critical pressure.
- It preloads after the first non-empty paint or a 3 s deadline, then 750 ms of quiet input. It loads visible,
  off screen, at the target pane size, waits for the load event and the first paint, keeps that frame as the
  cover, then hides. Spike 090 decides between frozen-hidden and rendered-parked (JS paused through visibility,
  0 wakeups). The parked page reports `document.visibilityState == "hidden"` on both engines (live test).
- A claim in the key's turn shows the cover in that frame, thaws, reparents and shows the page. The open
  handlers stay `registry.bindEffect` handlers that return `.done` with no await.
- CEF spare windows (default and pages profile) keep the window and have no renderer
  (desired_renderer_state = kNoRendererProcess, 017/019). Chromium's own spare renderer: none for the pages
  profile; for the default profile, only after the first browser tab, with a lifetime set from a measurement
  (020).

### E. Lazy loading and the shared chunk

- No page view until its tab first shows; no WKWebView in Chromium mode until a fallback needs it (041 after
  073 and 074).
- All 17 pages, the agent pane, the webviews-app viewers and agent-activity are built against one shared,
  content-hashed chunk set served from `cmux-page://cmux.shared/` (049, 050, 053, 072). WebKit answers shared
  chunk requests in one main-thread turn from an in-memory table (093). First load uses modulepreload, at most
  4 requests.
- Settings renders the navigation and the shown section first; every other section is a dynamic import after
  first paint (081, Chrome lazy_load.ts).
- The code cache spike (052) lands code only with a measured gain.
- One web abi bump for the whole branch (071).

### F. Home at the floor

Allowed at Home idle: app, daemon, Chromium engine processes (browser, GPU, network) when Chromium is the
default, and one renderer (the agent group) with the frozen New Tab preload. Not allowed: the about:blank
renderer, the WebKit Settings spare, the WebKit warmup page, a WebKit process for the update card, the ad-blocker
background page before the first browser tab, and Chrome runtime services cmux does not use (084).

### G. Observability

`debug.webui` (one row per page, spare and renderer, with group, engine, pid, state, held events, keep reasons
and preload), Release signposts `webui.lifecycle`, `webui.open`, `webui.preload`, `webui.scheme`, and
`scripts/cmux-next/bench-webui.py` as a thin driver over bench-pages.py, bench-idle.sh, procs.py and
bench_renderer_sharing.py, with the fleet entry `scripts/measure/webui-bench.sh`. Agents run it. No CI gate, no
budget rows.

### H. Stability

A page renderer hang shows the existing "Page unresponsive" card (CmuxDialogSpec). When Chromium ends, pages
wait for the helper-app supervisor restart (cef-helper-app-DESIGN.md); only after its 60 s give-up do shown
pages fall back to one WebKit group, and hidden pages fall back when shown. A page renderer crash can never end
cmux.

## 4. Rules for every task

1. Read CLAUDE.md, PATTERNS.md, REVIEW-STANDARD.md, threading-model.md and this spec before you start. Tell the
   owner named in the task (OWNERS.md) in the PR.
2. No compile or test on the person's Mac. Swift and Rust builds and tests run on the fleet
   (`cmux-ci run --class isolated ... --ref SHA`, `cmux-ci build cmux --ref SHA`). Web tests (`bun test`) and pure
   Python unit tests may run locally.
3. Each fix has a regression test that fails at base. Commit the red test first, then the fix, and write both
   results in the commit. Do not add CI jobs, CI steps, perf-gate rows or budget rows.
4. No main-thread blocking call, no `Thread.sleep`, no `.wait()`, no `try!`. Every new Task or queue has a
   `task-owner:` comment and an explicit QoS. Every new timer is a DemandTimer that does not repeat.
5. No raw animation. Layers that a task adds or removes (cover, snapshot, stand-in) set `actions` to NSNull or use
   `CATransaction.setDisableActions(true)`, and a test asserts no animation keys.
6. Every WebKit SPI and every optional shim symbol is gated (responds(to:), dlsym nil). Every task keeps the
   old-fork path working. A new shim export also gets a host-wire message for PL-cef-helper.
7. Process groups never mix capability classes. Any change to a descriptor's ops reruns task 087's test.
   Task 012 and 094 are risk:high and need an independent review receipt.
8. A page in the hidden or frozen state gets 0 native pushes, 0 router deliveries and 0 timer ticks. A thaw
   always runs before the page is visible and before held events.
9. Diffs stay at or below about 400 changed lines; split into commits by folder when larger.
10. Run `python3 scripts/cmux-next/prepush-gate.py` and `scripts/web-lint.sh` before push.

## 5. Done checks

Each row is measured at the program head on the fleet (macOS 27 aws-m4pro-1..4 and 26 aws-m4pro-5..9, 120 Hz
virtual display), light and STRESS, with p50, p95, p99 and max. A row marked "train" needs the fork train dist
(task 086). A row marked "pinned" must pass on `cef-154.0.28-cmux.28`.

- D1 Home, Chromium default. `bench-webui.py home --engine chromium --settle 60`. Pinned: WebKit WebContent
  processes == 0; extension renderers == 0; the New Tab preload frozen with 0 timer callbacks; web helper CPU
  summed over 60 s <= 0.3 % (today 1.78-2.02 %). Train: Chromium renderers == 1 (agent group, frozen preload);
  whole-tree footprint <= 250 MB (today 793); web helper CPU <= 0.05 %; web helper wakeups <= 1.0/s;
  `debug.wakeups` owners of pages, preload and spare == 0/s.
- D2 Home, WebKit default (pinned). CEF processes == 0; WebContent processes <= 1; footprint <= 150 MB;
  WebContent wakeups <= 0.2/s.
- D3 Ten pages (train). `bench-webui.py pages10`: open settings, history, cloud, apps, keybindings, files, diff,
  markdown, editor and chief-usage; show one. Page renderers <= 4 (privileged 1, viewer 1, solo 2 for diff and
  editor; 0 secrets); DevTools sessions on page renderers == 0 (clicks are native); 10 s after hiding, 8 pages
  frozen and the most recently hidden page hidden but not frozen; events and native pushes delivered to frozen
  pages == 0 over 60 s while `debug.webui publish` drives one stream per page at 10 Hz and an appearance toggle
  loop runs; at 300 s all 9 hidden pages without a keep reason are discarded; footprint at 300 s <= one-page
  footprint + 5 MB. WebKit variant (`--engine webkit`, pinned): WebContent processes <= 4.
- D4 Open latency (light and STRESS). `bench-webui.py open`. Preloaded open (Cmd-T New Tab; Cmd-, Settings while
  preloaded): key to cover frame <= 8.3 ms p50, <= 16.7 ms p99; key to live page frame: the target that spike
  090 records (no worse than 50 ms p95); main-thread work in the key's turn <= 4 ms p99. Warm open (group
  renderer live) <= 50 ms p95; cold open <= 150 ms p95; `cef.window_built_on_key_turn` == 0; second page in the
  same pane builds 0 windows. Discarded page: snapshot in the key's frame <= 16.7 ms p99, live <= 150 ms p95.
  Frozen chat with 2,000 turns: first frame <= 16.7 ms p99, live <= 150 ms p95. Cmd-W on a Chromium Settings tab:
  main-thread work in the key's turn <= 4 ms p99, 0 engine close calls in that turn.
- D5 Crash. `bench-webui.py crash`: kill -9 a group renderer with 5 pages, 1 shown. cmux survives; the shown page
  shows its notice and reloads once; hidden pages reload 0 times until shown; a second kill within 600 s follows
  the group cap (3).
- D6 Memory pressure. `debug.hibernation.pressure critical` (the memory coordinator's override, the one path
  every web object follows since 047): the preload slot is empty within 1 turn; one ranked pass
  over browser tabs, chats and pages discards in importance order until the reclaim target, recently visible
  last; page renderer count == groups with a shown page once all candidates are discarded.
- D7 Static counts (git grep at the program head, from the repo root):
  `git grep -n 'PageWebView(' -- Packages/macOS/CmuxNext/Sources ':!Packages/macOS/CmuxNext/Sources/CmuxNextPages'`
  == 0 (today 22). MQ10 command == 0 (today 13 plus PageProcessPool.shared).
  `git grep -n 'final class PageHostPool\|final class NewTabSparePool\|static func startWarmup\|final class AgentPageRetirer' -- Packages/macOS/CmuxNext/Sources`
  == 0. `git grep -n 'memoryPressure.observe' -- Packages/macOS/CmuxNext/Sources/CmuxNextPages Packages/macOS/CmuxNext/Sources/CmuxNextApp/NewTab Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation`
  == 0 (today 3; 047: the one kernel subscription is `MemoryCoordinator`'s in CmuxNextMemory, and WebUIHost,
  ChromiumWarmup and BrowserHibernation register with the coordinator). `git grep -n 'setInterval(' -- webviews/src/pages webviews/src/agent-session ':!*.test.*' ':!*.gallery.*' ':!**/gallery/**'`
  == 1 (inside usePageInterval). MQ3 hits only in the fork < 29 fallback. MQ13 == 0.
- D8 Bundles. `node scripts/cmux-next/page-bundle-report.mjs`: every page and the agent pane load <= 250 KB
  first-load JS (minified, uncompressed) not counting shared chunks; shared first-load <= 400 KB; total first
  load per page <= 600 KB; first-load requests per page <= 4; the React chunk URL is identical in the 17 pages,
  the agent pane, diff, markdown, editor and agent-activity; the Settings first load holds the navigation and one
  section.
- D9 Hangs and QoS. Over every bench run, `debug.hangs` holds 0 records > 250 ms with a stack in CmuxNextPages,
  NewTab, CEFSpareWindow or SettingsPageDomains. Every new Task or queue has `task-owner:` and an explicit QoS
  (cmux-next-deep-review workflow on the program range).
- D10 Security. PageProcessGroupCapabilityTests green; the page-channel sender test (two pages in one process,
  page A names page B in the payload) refuses the message; passwords never shares a process.
- D11 Leaks. Open and close each of the 14 web page providers 10 times: `debug.cef` tab count and
  `runtime.hosts.count` return to the baseline; the WebUIHost registry is empty; 30 s after the last Settings and
  History page closes or freezes, the daemon has 0 page-relay clients; with 4 page relays and `yes` in a terminal,
  daemon CPU is within noise of 0 relays.
- D12 Priority (train). `bench-webui.py priority`: a group renderer with every page hidden is backgrounded within
  1 s on both engines, or a linked follow-up task id exists.

## 6. Machine queues

Each command runs from the repo root. Each hit is one unit of work in the named task.

- MQ1 page factory (006-009). `git grep -n 'PageWebView(' -- Packages/macOS/CmuxNext/Sources ':!Packages/macOS/CmuxNext/Sources/CmuxNextPages'`.
  Today 22 (checked). Each hit becomes `webUI.open(PageOpenRequest(...))`. Done at 0.
- MQ2 frozen delivery (024-027). `git grep -l -E 'func subscribe\(_ stream: String' -- Packages/macOS/CmuxNext/Sources ':!**/PageProvider.swift' ':!**/PageRouter.swift'`.
  Today 15 files (checked; PageProviders.swift holds 2 providers). frozenDelivery is a requirement with no
  default, so the compiler lists every provider that still lacks it.
- MQ3 DevTools off pages (013, 014, 078). `git grep -n 'devTools(' -- Packages/macOS/CmuxNext/Sources/CmuxNextPages | grep -v 'func devTools\|///'`.
  Today 17 (checked). Done when only the fork < 29 fallback branch has hits.
- MQ4 page timers (034-036). `git grep -n 'setInterval(' -- webviews/src/pages webviews/src/agent-session ':!*.test.*' ':!*.gallery.*' ':!**/gallery/**'`.
  Today 13. Done at 1 (usePageInterval).
- MQ4b polls (069). `git grep -n 'setTimeout(' -- webviews/src ':!*.test.*' ':!*.gallery.*' ':!**/gallery/**' ':!webviews/src/prototypes/**'`.
  Today 120 (checked). The commit message gives a verdict per hit (poll loop or one-shot). Each poll loop pauses
  while hidden.
- MQ5 rAF loops (037). `git grep -n 'requestAnimationFrame(' -- webviews/src/pages webviews/src/agent-session ':!*.test.*' ':!*.gallery.*' ':!**/gallery/**'`.
  Today 57 (checked). Measurement first; only loops the measurement names change.
- MQ6 page bundles (049-051, 053, 072, 081). `sed -n 's/^PAGES="\(.*\)"/\1/p' scripts/cmux-next/build-pages-web.sh | tr ' ' '\n'`.
  Today 17, plus agent pane, diff, markdown, editor and agent-activity.
- MQ7 WebKit view makers. `git grep -n 'WKWebView(frame' -- Packages/macOS/CmuxNext/Sources`. Today 5 (checked):
  AgentActivityHostView.swift:41 -> 075; AgentPaneView+Warmup.swift:41 -> 046; AgentPaneView.swift:192 -> 073;
  WebProcessGroups.swift:16 (doc comment) -> 015; PageWebView.swift:273 -> 041.
- MQ8 spares and warmers (016, 019, 043-047). `git grep -n -E 'final class (CEFSpareWindow|NewTabSparePool|PageHostPool)|static func startWarmup|memoryPressure.observe' -- Packages/macOS/CmuxNext/Sources/CmuxNextPages Packages/macOS/CmuxNext/Sources/CmuxNextApp/NewTab Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation`.
  End state: one PagePreloadSlot, renderer-less spare windows, no `memoryPressure.observe` in this scope (every
  web object is a consumer of the memory coordinator, which holds the one kernel subscription in CmuxNextMemory).
- MQ9 lazy page tabs (040). `git grep -n -E '(class|struct) \w+.*: .*\bInternalPageProvider\b' -- Packages/macOS/CmuxNext/Sources`.
  Today 28. Applies only if 040's red-at-base test is red.
- MQ10 stateful statics (005, 010, 015, 066, 071, 073). `git grep -n -E 'static (let|var) (channels|views|processPool|processGroups|sharedDataStore|warmupView|chromiumHosting|openPanel|serials|nextSerial)\b|static let shared = (WKProcessPool|WebDevOverrideWatcher|WebBundleServedViews|AgentPaneNowPlaying)' -- Packages/macOS/CmuxNext/Sources/CmuxNextPages Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pages Packages/macOS/CmuxNext/Sources/CmuxNextApp/NewTab`.
  Today 14 (13 checked plus PageProcessPool.shared). Each moves into WebUIHost or is deleted.
- MQ11 close leaks (061). Every provider file in MQ1 whose provider has no `tabClosed` that closes its page.
  Today at least 6 (Keybindings, Passwords, MobilePairing, ChiefInspector, Cloud, BrowserAppTopPages; checked).
  The store-level close covers all; each gets one row in PageTabCloseTests.
- MQ12 native pushes (065). `git grep -n -E 'evaluate\(|evaluateJavaScript\(|callAsyncJavaScript\(' -- Packages/macOS/CmuxNext/Sources/CmuxNextPages Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane ':!*Tests*'`.
  Today 33 (checked). Each hit is marked held-latest, held-queue, thaws-first or allowed-while-frozen, with a
  reason.
- MQ13 WebKit view use in the agent pane (074). `git grep -n -E '\.webKitView\b' -- Packages/macOS/CmuxNext/Sources ':!Packages/macOS/CmuxNext/Sources/CmuxNextPages'`
  today 11, and `git grep -n -E '\bwebView\.' -- Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers`
  (with the first, 61 checked). Each moves to the engine-neutral API.
- MQ14 page state (082). The 17 pages of MQ6 minus those whose state is route-only, plus diff, files and
  agent-activity. Each saves route, scroll and unsent inputs on hidden and restores before first paint.
- MQ15 origin rename (094, only if spike 091 picks option B). `git grep -n 'cmux-page://'`. Today 291 hits in 178
  files (checked). Each literal becomes a use of `PageDescriptor.origin` (Swift) or the generated origin table
  (TS), or a `<page>.<group>` literal in tests.

## 7. Risks

1. Fork pin. The pin is API 24. Renderer paths, SetPageFrozen, page groups, the renderer-less spare, in-place
   discard and surface copy need API 29 or later. Task 086 puts the p13 exports into the one cross-program fork
   train (one reserved number per export, one dist, one pin bump by T+30 h). If the train is late, the "train"
   rows of D1, D3 and D12 cannot pass; the "pinned" rows still give a measured result.
2. Process lock. If spike 091 finds that neither option shares a renderer across origins without bad-message
   kills, groups fall back to one origin per process, and only the agent group shares (one origin, through 011's
   existing-process reuse and cap; the 085 threshold does not cover a site that is not HTTP(S)). D3 then expects
   renderers == pages open, and the rest of the program still lands.
3. Security of shared renderers. The capability test (087) is the guard. Groups are risk:high. A new op with a
   dangerous prefix on a viewer page makes the test fail.
4. Blast radius in the agent group. One renderer holds up to 8 agent pages; a streaming chat can slow the New Tab
   preload. Mitigations: the 8-frame cap, reload on show, per-group crash budget. If bench shows contention, a
   chat with a running turn takes its own process.
5. Frozen chats. turnRunning blocks freeze until acpmux can send a snapshot resync; `.ordered` delivery never
   drops. Task 038 tests 20,000 deltas while hidden.
6. WebKit SPIs change across macOS 14-27. All gated. 14 and 15 are checked only in Tart VMs (no timing).
7. Overlap with other programs in the 72 h window: PL-memory (planner, ranker, sharing switch), PL-cef-tab (spare
   windows, warmup), PL-cef-layer and PL-cefhost (page windows, surface capture), PL-cef-helper (shim to wire
   protocol, supervisor), PL-acpmux (transcript watch), p03-rendering (pages as layers). Each task names whom to
   tell. A task that touches the same function as another program waits for that program's merge and rebases.
8. Discard and state. Automatic userEdits detection and hide-time save reduce state loss; a page that keeps state
   only in memory outside its inputs (for example an open sub-dialog) can still lose it. MQ14 covers the pages
   one by one.
9. OTA. One abi bump for the branch (071). An older app never serves a split bundle.
10. Measurement needs an HQ ci-step allowlist entry for scripts/measure/webui-bench.sh and a GUI host with a
    console session.
11. Flagged lazy choice: the origin rename (MQ15) is large (291 literals). If spike 091 is slow, do not start the
    rename on a guess; it waits for the spike result.

## 8. Task table

Size: S <= 150 lines, M <= 400, L = split into commits of <= 400. "Tell" names the owner to notify in the PR.

| ID | Title | Size | Depends on | Queue |
| --- | --- | --- | --- | --- |
| 001 | debug.webui census of every page, spare and renderer | M | - | - |
| 002 | bench-webui.py as a thin driver over the existing benches | L | 001 | - |
| 003 | Release signposts webui.lifecycle, open, preload, scheme | S | - | - |
| 004 | webui-DESIGN.md, OWNERS row, F3 pointer, why cmux freezes WebUI | S | - | - |
| 005 | WebUIHost in the composition root with open() and close() | M | - | MQ10 |
| 006-009 | MQ1 batches A-D through webUI.open | S/M | 005 | MQ1 |
| 010 | Delete page statics; one WKProcessPool in WebUIHost | M | 006-009 | MQ10 |
| 011 | Fork: page process groups by the mechanism spike 091 picks | L | 091, 085 | - |
| 012 | PageDescriptor.processGroup (capability groups) and CEF registration | M | 011, 005, 087 | - |
| 013 | Page bridge on renderer paths, sender identity from the frame | L | - | MQ3 |
| 014 | Page evaluate and callAsync through tabEvaluate | M | 013 | MQ3 |
| 015 | WebKit pages: data store per group, shared pool, related views | M | 012, 073 | MQ7 |
| 016 | Pages profile at warm start and a pages spare window | M | 005 | MQ8 |
| 017 | Fork: renderer-less spare window placeholder | M | - | - |
| 018 | Fork: in-place discard of a page | M | - | - |
| 019 | CEFSpareWindow uses the renderer-less placeholder | S | 017, 016 | MQ8 |
| 020 | Chromium spare renderer policy from a measurement | S | 017, 002 | - |
| 021 | PageLifecyclePlanner in CmuxNextHibernation, full keep reasons | M | - | - |
| 022 | PageLifecycle controller fed by ContentLifecycle | M | 021, 005 | - |
| 023 | PageRouter hold, delivery policies, thaw-before-deliver | M | 022 | MQ2 |
| 024-027 | MQ2 batches A-D: frozenDelivery per provider | S | 023 | MQ2 |
| 028 | Freeze and thaw on both engines (WebKit stays in the window) | M | 022, 023 | - |
| 029 | WebKit suspend SPI spike; decides detach | S | 028 | - |
| 030 | Discard and restore behind the hide-time snapshot | L | 028, 088, 062 | - |
| 031 | Chromium in-place discard binding | S | 018, 030 | - |
| 032 | Native keep reasons and the keepAlive op | M | 022 | - |
| 033 | JS hooks on visibilityState and freeze/resume (no native stream) | M | 028 | - |
| 034-036 | MQ4 batches A-C: usePageInterval | S | 033 | MQ4 |
| 037 | MQ5 rAF loops, measurement first | M | 033, 002 | MQ5 |
| 038 | Agent chats and New Tab pages join the lifecycle | M | 028, 027, 021 | - |
| 039 | Crash handling per group, reload on show | M | 022, 012 | - |
| 040 | Lazy page tabs (red-at-base first; drop if green) | M | 005 | MQ9 |
| 041 | No WKWebView in Chromium mode until a fallback | L | 010, 073, 074 | MQ7 |
| 042 | Pure PreloadSelector | S | - | - |
| 043 | PagePreloadSlot per the spike 090 result | M | 042, 028, 090 | MQ8 |
| 044 | New Tab spare onto the slot (delete NewTabSparePool) | L | 043, 009 | MQ8 |
| 045 | Settings, History, Cloud preload through the slot (delete PageHostPool) | M | 043, 006 | MQ8 |
| 046 | WebKit warmup only for WebKit agent pages | S | 045 | MQ7 |
| 047 | One memory-pressure path for every web object | S | 044, 045, 019, 092 | MQ8 |
| 048 | Cold-open stand-in layer with no implicit animation | M | 003, 040 | - |
| 049 | Split page build, multi-entry, modulepreload | L | - | MQ6 |
| 050 | Shared chunks from cmux-page://cmux.shared/ | M | 049 | MQ6 |
| 051 | page-bundle-report with the D8 caps | S | 050 | MQ6 |
| 052 | Code cache spike (code only with a gain) | M | 050, 012 | - |
| 053 | Agent pane uses the shared chunk | L | 050, 073, 072 | MQ6 |
| 054 | Update card: privileged group, discarded when dismissed | S | 015, 022 | MQ7 |
| 055 | Built-in ad blocker after the first browser tab | M | 001 | - |
| 056 | HomeWebFootprintTests | S | 045, 046, 019 | - |
| 057 | Page renderer hang notice | M | 039 | - |
| 058 | Chromium ended: wait for the supervisor, then shown pages fall back | S | 041, 015 | - |
| 059 | Cleanup and doc updates | S | 047, 019 | - |
| 060 | Testing phase: every done check on the fleet | L | 002, 044, 047, 030, 038, 051, 056, 061 | - |
| 061 | Every closed page tab ends its engine page | M | 005 | MQ11 |
| 062 | CEF pane hosts of closed pages are removed | S | - | - |
| 063 | Page tabs share one Chromium window per pane | M | 005, 062 | - |
| 064 | Page teardown leaves the Cmd-W turn (PageRetirer) | S | 061 | - |
| 064b | Reopen Closed takes back a page tab's retired page | M | 064 | - |
| 065 | Native pushes held or thaw-first while frozen | M | 028 | MQ12 |
| 066 | Provider freeze hooks; page relay channels in WebUIHost | M | 023 | MQ10 |
| 067 | Daemon: page-relay subscriptions filter by event kind | M | - | - |
| 068 | Browser-tab document scripts and bridges skip page tabs | S | - | - |
| 069 | MQ4b: setTimeout polls pause while hidden | M | 033 | MQ4b |
| 070 | Agent pane frame pacer silent while frozen; one visibility source | S | 022, 038 | - |
| 071 | Web updates reload only shown pages; abi bump; safe point | M | 022, 043, 050 | MQ10 |
| 072 | Shared chunk across OTA trees; webviews-app and agent-activity join | L | 050 | MQ6 |
| 073 | Delete the old agent pane host | L | 009 | MQ7, MQ10 |
| 074 | AgentPaneView engine-neutral | L | 073 | MQ13 |
| 075 | Delete the AgentActivityHostView WKWebView fallback | S | 005 | MQ7 |
| 076 | Settings domains off the main thread | S | - | - |
| 077 | Fork: surface copy and native click without DevTools | M | - | - |
| 078 | Snapshots, menu, debug input and evaluate off DevTools | M | 014, 077 | MQ3 |
| 079 | Mojo-like page push channel (code only with a gain) | M | 013, 086 | - |
| 080 | Frozen idle chats close their acpmux watch | M | 038 | - |
| 081 | Settings lazy sections (built, not fixed) | L | 049 | MQ6 |
| 082 | Page state save and restore for every page | M | 088, 089 | MQ14 |
| 083 | Page renderer priority and purge on freeze | M | 028, 002 | - |
| 084 | Chrome runtime idle services census and switches | M | 001 | - |
| 085 | Agent origin sharing through PL-memory's per-site switch | S | 013 | - |
| 086 | p13 exports in the cross-program fork train | M | 017, 018, 077 | - |
| 087 | Process group capability test (security guard) | S | - | - |
| 088 | Hide-time snapshot and state; discard makes no page call | M | 022, 077 | - |
| 089 | Automatic keep reasons: user edits, form, beforeunload, capture, draft | M | 032 | - |
| 090 | Preload park-state spike | S | 002 | - |
| 091 | Fork spike: cross-origin process lock sharing | M | - | - |
| 092 | One urgent discard ranking for tabs, chats and pages | M | 021 | - |
| 093 | WebKit scheme handler answers shared chunks in one turn | S | 050 | - |
| 094 | Origin rename to `<page>.<group>` (only if 091 picks B) | L | 091 | MQ15 |

### Task details

Each entry: files, change, acceptance (what a diff-only reviewer checks), test phase.

**001 debug.webui census.** Files: P/CmuxNextApp/Control/DebugWebUI.swift (new), AppControl.swift,
CmuxNextPages/PageWebView+Debug.swift, Tests/CmuxNextAppTests/DebugWebUITests.swift (new). Change: socket method
`debug.webui` under DEBUG || CMUX_BENCH_HOOKS. One row per PageWebView, parked New Tab spare, PageHostPool spare
and CEFSpareWindow, plus one row per CEF helper process (renderer, extension, utility) with its pid and kind.
Fields: page id, engine, group (null until 012), state, hidden_for_s, keep reasons, browser id, renderer pid
(shim `rendererClientIDs` to helper pid), WebKit `_webProcessIdentifier` (gated), events delivered while hidden
(one integer add in PageRouter.deliver), native pushes while hidden, spare kind. Acceptance: no Release path
changes; JSON keys in a doc comment; counters allocate nothing. Test: fleet suite DebugWebUITests; tagged build at
Home after 60 s, record what the 3 renderers are in perf-lead.md section 5.

**002 bench-webui.py.** Files: scripts/cmux-next/bench-webui.py (new), scripts/measure/webui-bench.sh (new),
tests/test_bench_webui.py (new), tests/test-execution.toml. Change: a thin driver that imports the Run and process
code of bench-pages.py, bench-idle.sh's counters, scripts/perf-bench/procs.py and bench_renderer_sharing.py. Modes
home, pages10, open (adds Cmd-W and frozen-chat rows), crash, pressure, priority, delivery. Clicks go through
native clicks when the fork has them; on fork < 29, D3 DevTools rows print `unscored`. Acceptance: no new copy
of process counting; no sleep except `--settle`; refuses a wrong session shape; prints percentiles; budgets.json,
perf-budgets*.json and .github/ unchanged. Test: `python3 -I -m unittest tests/test_bench_webui.py` locally; then
the base baseline on the fleet, recorded in perf-lead.md.

**003 Signposts.** Files: P/CmuxNextSignposts/, PageWebView+Paint.swift, PageSchemeHandler.swift. Change: catalog
names webui.lifecycle (event), webui.open (request to first paint), webui.preload (park, claim, drop),
webui.scheme (requests and main-thread time per open). Acceptance: catalog only; static strings plus integers;
<= 100 lines. Test: CmuxNextSignpostsTests; a tagged trace shows the tracks.

**004 Doc and owners.** Files: plans/cmux-next/webui-DESIGN.md (new), OWNERS.md, perf-lead.md. Change: this spec
as the area doc, including the section "why cmux freezes WebUI" and the capability group table. OWNERS row "cmux
pages (WebUI host, process groups, lifecycle, preload)" for CmuxNextPages/, CmuxNextApp/NewTab/,
CmuxNextApp/Pages/, CmuxNextApp/InternalPages/, webviews/src/pages/shared/, build-pages-web.sh; owner p13-webui.
Only the F3 row of perf-lead.md changes. Test: docs only.

**005 WebUIHost.** Files: CmuxNextPages/WebUI/WebUIHost.swift, PageOpenRequest.swift (new), CmuxNextApp/AppServices.swift,
AppDelegate.swift. Change: `@MainActor final class WebUIHost(chromium:openPanel:memoryPressure:clock:)` with
`open(_:) -> PageWebView?`, `close(_:)`, an instance PageRegistry and a registry of opened pages. AppServices
builds it once as `webUI`. Statics stay as forwarders until 010. Acceptance: no static state; built once; existing
PageWebView tests unchanged. Test: CmuxNextPagesTests and new WebUIHostTests with FakeChromiumHosting.

**006-009 MQ1.** 006: PageFactory.swift and DebugSettingsService.swift (6 hits). 007: DiffPageService,
FilePageService, FileTreePageService, ChangelogPageTab, UpdateSurfaceIsland, StatsPage, ChiefUsagePage,
MobilePairingPage (8). 008: KeybindingsPage, PasswordsPage, IconPickerService, ChiefInspectorPage,
AgentActivityPageTab, HomeChannelsPage (6). 009: ChiefViewsPage, AgentPanePageHost, AgentPaneView (also its
default parameter `chromium: ... = PageWebView.chromiumHosting` at AgentPaneView.swift:138), AgentTabs (2).
Acceptance: MQ1 drops by the batch count, arguments field by field; 009 ends at 0 and adds no layer outside
architecture-layers.json. Test: fleet compile-check --app and the touched suites.

**010 Delete statics.** Files: PageWebView.swift, PageRegistry.swift, PageProcessPool.swift, CmuxNextApp/Pages/DebugPages.swift,
CmuxNextApp/Control/DebugWindowSnapshot.swift (line 149), CmuxNextApp/Screenshots/AppWindowImage.swift (34, 53), the 2
CmuxNextAppTests files that call `PageWebView(`. Change: remove `chromiumHosting`, `openPanel`, PageRegistry
statics; initializers become internal; tests use WebUIHost.open with a fake host. PageProcessPool becomes the one
`WKProcessPool` held by WebUIHost, also used by agent views (replaces AgentPaneView.processPool). Acceptance:
those MQ10 hits == 0; one WKProcessPool() in Sources; a fleet trace shows page build time unchanged (recorded).
Test: CmuxNextPagesTests, compile-check --package CmuxNext.

**011 Fork page groups.** Files: fork include/cef_cmux.h, libcef/browser/chrome/chrome_content_browser_client_cef.cc,
the cmux page scheme table. Its ref (`17a7f8ff`) stays unpinned until spike 091 has run: its Measured column (webui-DESIGN.md section 5.1) needs
a job id, and 091 names no winner before that. Change: the mechanism that the 091 run proves. Hypothesis (expected
B, unmeasured): cmux-page as an additional WebUI scheme with the last-label lock rule, and existing-process reuse
(`ShouldTryToUseExistingProcessHost`, as top-chrome WebUI) for the grouped hosts of `privileged`, `viewer` and
`agent` (`cmux.agent`). That reuse (`GetExistingProcessHost`) has no cap, and `ProcessPerSiteUpToMainFrameThreshold`
refuses a site that is not HTTP(S), so it cannot cap the agent group. Thus 011 has one cap of 8 main frames per
group renderer for every grouped host, the agent group too, in the content patch `cmux_page_process_groups`
(`ContentBrowserClient::ShouldUseExistingProcessHost`, asked only in `GetExistingProcessHost`), not in
`IsSuitableHost`, so a navigating page never moves off a full renderer (webui-DESIGN.md sections 3.2 and 5.1). The value 8 is the same as the cmux-page entry of
PL-memory's sharing switch (085), not a second setting. Export `cmux_shim_page_scheme_set_group(id, group)` before
CefInitialize ends. `solo` and `secrets` keep one process per page. Acceptance: fork test opens 3 origins of one
group: 1 RenderProcessHost, 0 bad-message kills after localStorage, fetch and postMessage on each; a 9th frame gets
a second process, in a `privileged` group and in the agent group (nine `cmux.agent` pages give 2 renderers); pages
of two groups never share a renderer; a secrets page gets its own; cmux-page sites do not use process-per-site (no
WebUIControllerFactory and no WebUI data source is registered for cmux-page, and it is not privileged embedder
content: `SiteInfo::ShouldUseProcessPerSite`); API number from the train reservation (086). Tell PL-memory. Test:
fork browser tests; pin a dev dist for 012.

**012 processGroup.** Files: PageDescriptor.swift, WebUI/PageProcessGroup.swift (new), CmuxNextBrowser/CEF/CEFPageSchemes.swift,
CEFRuntime.swift, CEFShimLibrary.swift, CEFForkFeatures.swift, CmuxNextApp/Pages/FirstPartyPageSchemes.swift.
Change: `enum PageProcessGroup { agent, privileged, viewer, solo, secrets }`, a non-optional init parameter on all
22 descriptors (table in section 3.B as corrected by 087), registered through the optional shim export when
`CEFForkFeatures.pageProcessGroups`. Acceptance: table test lists 22 descriptors; 087 green; dlsym nil on old
forks; no call when off; risk:high with a security note. Test: CmuxNextPagesTests, CmuxNextBrowserTests; with a
dev dist, bench-webui.py pages10 page renderers <= 4.

**013 Bridge on renderer paths.** Files: ChromiumPageHostBridge.swift, PageChromiumHosting.swift,
CmuxNextApp/Pages/Chromium/CEFPageChromiumPage.swift, CmuxNextBrowser/CEF/CEFDocumentScripts.swift,
Tests/.../ChromiumPageHostBridgeTests.swift. Change: with rendererPaths, the host script installs once per
renderer through addDocumentScript and returns unless `location.protocol === 'cmux-page:'`; posts through
addPageChannel('cmuxPageHost'); replies through tabEvaluate; no Page.enable, Runtime.enable or addBinding. The
host reads sender browser id, frame and committed origin from the delivering CEF frame and refuses a message
whose origin is not the descriptor's. Acceptance: 0 devTools() calls in setup and messaging (fake counter); a test
with two pages in one process where A names B in the payload is refused. Test: ChromiumPageHostBridgeTests red at
base; tagged build `debug.cef` shows 0 DevTools sessions for Settings and History (train dist).

**014 evaluate.** Files: PageWebView+Chromium.swift, +EngineNeutral.swift, +Evaluate.swift, PageChromiumHosting.swift,
CmuxNextPagesTestSupport/FakeChromiumPage.swift. Change: `evaluate(_:awaitPromise:) async throws -> String` on
PageChromiumPage through tabEvaluate; move Runtime.evaluate sites. Acceptance: result JSON matches the old path
(tests compare). Test: PageWebViewChromiumTests, PageWebViewEngineNeutralTests.
As built: `evaluate(_:) async throws -> Any?`, no default witness; CEFPageChromiumPage implements it over
`CEFTab.evaluate(_:world: .page, gesture: .cmux)` (tabEvaluate on fork >= 29). No `awaitPromise` parameter:
tabEvaluate has none, and a value that is not a promise comes back as is, so the one sync site (the
input-readiness edit) gets what it got before. The value comes back parsed, not as JSON text, so the DevTools
fallback parses its reply once off main and the CEF path does not re-serialize. Test:
PageWebViewChromiumEvaluateTests compares callPageScript, callPageFunction and the edit with the old parses.

**015 WebKit groups.** Files: CmuxNextPages/WebUI/PageProcessGroups.swift (moved from CmuxNextAgentPane/WebProcessGroups.swift),
PageWebView+Pooled.swift, AgentPaneView.swift. Change: hostConfiguration takes the group's data store (one per
group in WebUIHost) and the WebUIHost pool; views made through PageProcessGroups (8 per process); agent views use
the agent group. Acceptance: `.nonPersistent()` once per group in WebUIHost only; secrets never relates; two
different page ids of one group share `_webProcessIdentifier`, two groups do not; the 9th view starts a new
anchor. Test: PageProcessGroupsTests with real WKWebViews on macOS 26 and 27; pages10 --engine webkit
WebContent <= 4.

**016 Pages spare window.** Files: CEFSpareWindow.swift, CEFEngine.swift, ChromiumPageHost.swift,
CmuxNextChromiumWarmup/ChromiumWarmup.swift. Change: one spare per kind (default, pages profile); page keys take
the pages spare; the pages profile is made at warm start; ChromiumWarmup builds the pages spare at the next idle
moment. Acceptance: `cef.window_built_on_key_turn` stays 0 (fake runtime); take() still refuses incognito and
remote; at most one untaken spare per kind. Tell PL-cef-tab and PL-cef-helper. Test: CEFSpareWindow* and
CmuxNextChromiumWarmupTests; open: cold page <= 150 ms p95.

**017 Fork renderer-less spare.** Change: spare window creation option with
`desired_renderer_state = kNoRendererProcess` and no navigation. Acceptance: fork test counts 0 renderers for
the spare; a joined tab gets one. Test: fork browser test.

**018 Fork discard.** Change: `cmux_shim_tab_discard(browser)` (WebContents::Discard) and
`cmux_shim_tab_was_discarded`. The tab keeps its browser id, window slot, NavigationEntry and session storage.
Acceptance: renderer ends; reshow commits the same URL with `document.wasDiscarded`; a visible page refuses.
Test: fork browser test.

**019 Renderer-less spare in Swift.** Files: CEFSpareWindow.swift, CEFTab+Freeze.swift, CEFShimLibrary.swift.
Change: with the 017 export, prepare() makes no renderer and skips freezeNeverShownPage. Acceptance: 0 DevTools
calls for the spare (fake shim); take/giveBack/drop unchanged. Tell PL-cef-tab. Test: CEFSpareWindow*; home: no
about_blank row.

**020 Spare renderer policy.** Files: CEFSwitches.swift, fork chrome_content_browser_client_cef.cc. Change: no
spare for the pages profile. For the default profile: start only after the first browser-tab navigation. Measure
the idle wakeups and footprint of a documentless spare against cef_tab.new.visible (002), then choose no timeout
(Chrome desktop) or a timeout with the written number. Acceptance: constants cite spare_render_process_host_manager_impl
correctly (no desktop timeout, kill-on-pressure off by default); Home with no browser tab has 0 spares. Test:
home and open benches; cef_tab.new.visible within its noise band.

**021 Planner.** Files: CmuxNextHibernation/PageLifecyclePlanner.swift, Tests/CmuxNextHibernationTests/PageLifecyclePlannerTests.swift.
Change: pure value type; per page key, group, hiddenFor, keep reasons (section 3.C list, including loading,
recentlyVisible, mostRecentlyUsed, inspector, focused, fileDrop, popup, confirmation, dictation, capture,
turnRunning, userEdits, formInteraction, beforeunload, draft, pinned, shellCommandRan, awaitingPerson, remoteChat,
preload), split into freeze-blocking and discard-blocking; pressure, Low Power Mode; output target state and next
deadline; reuses HibernationPlanner.Pace. Port every AgentPageHibernation exemption test first. Agreed with
PL-memory before start. Acceptance: no clock read, no AppKit; property tests (shown is Active; a discard-blocking
reason never reaches Discarded; a freeze-blocking reason never reaches Frozen; the MRU page is never frozen;
deadline is the minimum). Test: PageLifecyclePlannerTests (commit property tests with a stub first).

**022 Controller.** Files: WebUI/PageLifecycle.swift (new), PageWebView.swift, WebUIHost.swift,
CmuxNextApp/TabContentCache+Lifecycle.swift, Tests/.../PageLifecycleTests.swift. Change: PageLifecycle consumes
ContentLifecycle effects for `.page` and agent content; no per-view observers; one DemandTimer; calls freeze,
thaw, discard (no-ops until 028/030). Acceptance: no NotificationCenter observer per page; no repeating timer;
thaw before visible (order test); O(changed pages) per event. Tell PL-cef-tab (TabContentCache owner). Test:
PageLifecycleTests with PageTestClock.

**023 Router hold.** Files: PageRouter.swift, PageProvider.swift, Tests/.../PageRouterFrozenDeliveryTests.swift.
Change: `enum PageFrozenDelivery { latest, resync, queue(Int), ordered }` as a requirement with no default;
holdDelivery/releaseDelivery; while held, keep per sub by policy; `.ordered` never drops and reports half-full
buffer to PageLifecycle (page leaves Frozen, stays hidden); built-in commands and calls to a frozen page ask
PageLifecycle to thaw in the same turn, then deliver; release sends held envelopes in seq order in one batch.
Acceptance: 0 envelopes to the script pipeline while held; seq order kept; each drop calls eventDeliveryDropped
once; a command to a frozen page thaws then delivers with no PageCallDeadline. Test: PageRouterFrozenDeliveryTests
red at base.

**024-027 MQ2 batches.** 024: ConfirmingPageProvider (forwards its wrapped value) and PageProviders.swift (2
providers). 025: SettingsPageProvider, MobilePairingPageProvider, UpdateSurfaceIsland, DebugSettingsPage. 026:
AgentActivityPageProvider, CloudPageProvider, KeybindingsPageProvider, IconPickerProvider, FilePageProvider,
PasswordsPageProvider. 027: AgentPageProvider (`.ordered`), ChiefViewsPageProvider, DiffPageProvider. Change: each
provider declares its policy with a one-line reason; append-only streams are never `.latest`; DaemonPageRelay is
`.resync`. Acceptance: the compiler requirement is satisfied for every provider; each touched file has a reason
comment. Test: suites of the touched modules.

**028 Freeze and thaw.** Files: PageChromiumHosting.swift, PageWebView+Lifecycle.swift, CEFPageChromiumPage.swift,
PageWebView+Pooled.swift, FakeChromiumPage.swift. Change: `setFrozen(_:) -> Bool` (SetPageFrozen on API 29,
DevTools lifecycle before); PageWebView freeze()/thaw() hold or release the router and freeze the engine. WebKit:
throttling and suppression preferences (gated), the view stays in the window with isHidden. Order: engine hidden
and `visibilitychange` before freeze; thaw before visible. Acceptance: freeze on a shown page refused; setFrozen
once per freeze; no sleep, no wait; an order test on both engines. Test: PageLifecycleTests; live WebKit hidden
page wakeups from about 11/s to <= 0.2/s.

**029 WebKit suspend spike.** Files: PageWKWebView.swift, Tests/.../PageWebKitSuspendTests.swift. Change: gated
`_suspendPage:`/`_resumePage:`; measure hidden-in-window, suspended and detached (wakeups over 30 s and show-turn
main-thread time). Acceptance: code lands only if suspend is better; detach is used only if hidden-in-window wakes
> 0.2/s and its show-turn cost is <= 4 ms; numbers in perf-lead.md. Test: macOS 26 and 27 live; Tart 14/15 for
the selector check.

**030 Discard and restore.** Files: PageWebView+Discard.swift (new), PageWebView+WindowImage.swift, PageWebView.swift,
webviews/src/pages/shared/pageClient.ts, Tests/.../PageDiscardTests.swift. Change: discard uses only the hide-time
snapshot and state (088), ends the engine page (031 or close on older forks), cancels subscriptions, keeps the
shell. Show draws the snapshot layer (no implicit actions) in the key's turn, makes the engine page through
WebUIHost in the same group and pane window (063), loads the route, restores state before first paint, and
removes the snapshot at first paint. Acceptance: discard makes 0 page calls and finishes in one turn; a discarded
shell holds no engine page and no subscriptions; 10 discard and restore cycles leave runtime.hosts.count
unchanged; a keep reason blocks discard. Test: PageDiscardTests; open bench discarded rows.

**031 Chromium discard binding.** Files: CEFShimLibrary.swift, CEFTab+Freeze.swift, CEFPageChromiumPage.swift,
PageChromiumHosting.swift. Change: `discard() -> Bool` through the optional shim; false on old forks. Acceptance:
symbol optional; the next load() reloads in place. Test: CmuxNextBrowserTests with a fake shim; pages10 renderer
memory freed.

**032 Native keep reasons.** Files: PageDescriptor.swift (PageNativeOp.keepAlive), PageWebView.swift,
WebUI/PageLifecycle.swift, pageClient.ts, webviews/src/pages/editor/store.ts, markdown/store.ts. Change: op
`cmux.page.keepAlive {reason, on}` for every page; native reasons popup, confirmation, file drop, inspector,
focused, dictation. Acceptance: page reasons clear on reload or crash; JS can only add reasons. Test:
PageLifecycleTests; `cd webviews && bun test src/pages/shared`.

**033 JS hooks.** Files: webviews/src/pages/shared/pageLifecycle.ts (new), pageLifecycle.test.ts (new),
pageClient.ts, the acpmux transport adapter. Change: usePageLifecycle, usePageInterval, usePageAnimationFrame
built on document.visibilityState and the freeze/resume events. No native stream. Acceptance: no timer starts
while hidden (fake-clock tests); resume makes no fetch (check-switch-fetches passes); a live test reads
visibilityState == "hidden" for a hidden and a parked page on both engines. Test: bun tests, `bun run check`.

**034-036 MQ4.** 034: ActivityLine, WorkingFor, SubagentGroup, HarnessesScreen (4). 035: NewTabExtras,
NowPlayingPlayer, RunBoard, CompareRunBoard, TimelineRunBoard, pullRequestStore (6). 036: ChiefViewsPage,
RunCard, streamDebug (debug feeder with `// wakeup-allow: debug feeder`). Elapsed labels compute from a start
time on resume. Acceptance: MQ4 drops by the batch; text identical after hide and resume; a hidden New Tab makes
0 callbacks in 60 s. Test: bun tests of the touched folders and web-lint.sh.

**037 MQ5 rAF.** Files: only self-rescheduling rAF hits of MQ5. Change: first measure GPU and renderer wakeups
with every page hidden (002). Move only the loops that the measurement names to usePageAnimationFrame. The
commit lists all 57 hits with a verdict. Acceptance: verdict list present; if the measurement is <= 0.2/s, only
the measurement lands. Test: pages10 with every page hidden.

**038 Agent chats join the lifecycle.** Files: CmuxNextApp/Hibernation/AgentPageHibernation.swift, AgentPaneView.swift.
Change: agent pages register with PageLifecycle; AgentPageHibernation's release becomes the discard step through
the planner with all its exemptions; turnRunning blocks freeze and discard; an untouched hidden New Tab may be
discarded. Acceptance: running hidden chat is neither frozen nor discarded; a hidden chat that receives 20,000
deltas thaws with the transcript intact; untouched New Tab discarded at 300 s; existing AgentPageHibernation tests
pass. Tell PL-memory. Test: CmuxNextAppTests filter AgentPageHibernation, PageLifecycleTests.

**039 Crash per group.** Files: PageWebView+Lifecycle.swift, PageCrashReloads.swift, WebUIHost.swift,
Tests/.../PageCrashGroupTests.swift. Change: reload at once only when shown; hidden pages go to needsReload and
reload on show; budget per group. Acceptance: 5 pages in one group, 1 shown: 1 reload; cap stops a loop; existing
tests updated, not deleted. Test: PageCrashGroupTests red at base; crash bench.

**040 Lazy page tabs.** Files: InternalPageTabStore.swift, InternalPageView.swift, InternalPageTabStore+Show.swift,
Tests/CmuxNextAppTests/InternalPageLazyTests.swift. Change: first commit the test (14 restored web page tabs in
background panes, plus a non-selected tab in a parked workspace, count makeView). If it is red, make
InternalPageView take a content factory. If every case is green at base, land only the test. Acceptance: 0
makeView calls until a tab shows. Test: InternalPageLazyTests.

**041 Lazy WKWebView.** Files: PageWebView.swift, +Chromium.swift, +EngineNeutral.swift. Change: WebKit pieces into
a lazily built PageWebKitEngine; built in Chromium mode only by fallBackToWebKit; engine-neutral calls through
`scriptTarget`. Acceptance: no WKWebView in a Chromium page or agent page subtree (test); fallback still immediate;
PageWebView.swift under its god-file cap. Test: PageWebViewChromiumTests, PageWebViewEngineNeutralTests.

**042 PreloadSelector.** Files: CmuxNextHibernation/PreloadSelector.swift, Tests/.../PreloadSelectorTests.swift.
Change: pure; candidates with last-used times, pressure, launch paint; output candidate and deadline (first
non-empty paint or 3 s, then 750 ms quiet). Acceptance: never more than one; none under pressure; deterministic.
Test: PreloadSelectorTests.

**043 PagePreloadSlot.** Files: WebUI/PagePreloadSlot.swift, PreloadablePage.swift (new), WebUIHost.swift,
Tests/.../PagePreloadSlotTests.swift. Change: the park state spike 090 chose. Park: load visible off screen at the
target size, wait for load and first paint, keep the cover frame, hide (and freeze if the spike chose it). A refit
during park thaws, lays out and parks again at idle. Claim: cover in the key's frame, thaw, reparent, show; the
cover goes at the live frame; no implicit actions. Slot drops on any non-normal pressure through WebUIHost's
subscription. Acceptance: claim main-thread time <= 4 ms with fakes (port PageHostPoolClaimReadyBenchmark); one
parked page at any time (property test). Test: PagePreloadSlotTests.

**044 New Tab onto the slot.** Files: CmuxNextApp/NewTab/NewTabSparePool.swift (deleted), NewTab/NewTabPreload.swift
(new), NewTabPage.swift, AgentTabs.swift, Control/DebugNewTab.swift, AgentPaneView.swift (PreloadablePage).
Change: keep pane-size fit, cross-window reparent, recycle and debug.new_tab fields as a thin adapter. Cmd-T stays
a bindEffect handler with `.done`. Acceptance: `final class NewTabSparePool` == 0; debug.new_tab keeps its fields;
the launch preload starts 250 ms after the first frame (cx-ec99). Test: CmuxNextAppTests filter NewTab; open:
Cmd-T cover p99 <= 16.7 ms light and STRESS.

**045 Pages onto the slot.** Files: PageHostPool.swift, +Build.swift, +Windows.swift (deleted), PageWebView+Claim.swift,
+Pooled.swift, PageFactory.swift, AppServices+AfterFirstFrame.swift, Control/AppControl.swift. Change: PageWebView
conforms to PreloadablePage on either engine; AfterFirstFrame calls `webUI.preload.start()`. Acceptance:
`final class PageHostPool` == 0; no WebKit process at Home with Chromium default; claim in the key's turn. Test:
ported PageHostPool tests as slot tests.

**046 WebKit warmup.** Files: AgentPaneView+Warmup.swift, AppServices+AfterFirstFrame.swift. Change: warm only when
the agent descriptor's engine is WebKit; delete startWarmup/finishWarmup if the slot's first WebKit build covers it
(measure agent_pane first-live). Acceptance: no WKWebView at launch with Chromium default; deletion only with a
fleet number. Test: CmuxNextAgentPaneTests; home bench.

**047 One pressure path.** Files: WebUIHost.swift, PageLifecycle.swift, ChromiumWarmup.swift, AppServices.swift,
CmuxNextApp/Hibernation/BrowserHibernation.swift. Change: WebUIHost holds the one observer; warning drops the
slot; critical also drops untaken spare windows and runs one ranker pass (092); BrowserHibernation's own observer
goes. Acceptance: one `memoryPressure.observe` in the D7 scope; drop order tested with ManualMemoryPressureSource.
Tell PL-memory. Test: WebUIHostPressureTests; pressure bench.
As built: PL-memory's coordinator had landed, so the one observer is `MemoryCoordinator`'s and the D7 count is 0;
WebUIHost registers the slot as a `SpareMemoryConsumer`, ChromiumWarmup's spare windows close only at critical
(`SpareMemoryConsumer.Closing.atCritical`), BrowserHibernation runs the ranked pass on the critical release slice.
Order tests: WebUIHostPressureTests (stand-ins), WebUIPressureOrderTests (the app's real registrations). The
pressure bench drives `debug.hibernation.pressure`. PL-memory told in p07-memory.md section 3.E. PL-cef-tab:
`CEFSpareWindow.setHeld` no longer closes the untaken spares; `CEFEngine.closeUntakenSpareWindows` does, at critical.

**048 Stand-in.** Files: PageWebView+Paint.swift, PageWebView.swift, InternalPageView.swift. Change: a themed
CALayer (WebTheme surface color, title through TypeScale) in the open's turn, removed at the first PagePaintProbe
paint; implicit actions off. Acceptance: no SwiftUI; removed in the paint callback's turn; no animation keys
(test). Test: PageStandInTests; a cmux-ci capture of a cold Settings open (light and dark).

**049 Split build.** Files: build-pages-web.sh, webviews/scripts/agent-pane/bundle.mjs, webviews/scripts/pages/build-pages.mjs
(new). Change: one esbuild run, every pages/<page>/main.tsx, splitting, esm, content-hashed shared chunk names
under Resources/pages/_shared/, `<script type=module>` plus modulepreload for first-load chunks, no inline JS.
Acceptance: `--check` works; no inline module code; a script test resolves every import. Test:
`build-pages-web.sh --check` locally, web-lint.sh.

**050 Shared origin.** Files: FirstPartyPageSchemes.swift, PageServedHosts.swift, PageSchemeHandler.swift, PageCSP.swift,
CEFShim/src/shim_page_scheme.mm, PageID.swift, webviews/scripts/pages/build-pages.mjs, cmux-tui-core
server/page_files.rs. Change: `cmux.shared` root serves only .js and .css, ACAO set to the
requesting first-party cmux-page origin, CSP `script-src 'self' cmux-page://cmux.shared`; cmux.shared cannot be
opened as a page. The page build names every shared chunk `cmux-page://cmux.shared/<chunk>.js` (entry imports and
modulepreload) and no page folder keeps a `_shared` copy; the daemon's /pages/ serves those URLs as /pages/_shared/.
Acceptance: a non-cmux origin gets no ACAO; navigation to it refused; React chunk URL identical
across pages. Test: MarkdownPageSecurityTests (shared case), PageSharedOriginTests, PageChromiumCoverageTests,
webviews pages-split-build.test.ts, cmux-tui-core page_files tests, bundle report.

**051 Bundle report.** Files: scripts/cmux-next/page-bundle-report.mjs (new). Change: per page first-load bytes,
shared bytes, total, request count, lazy chunk count, React chunk URL. Acceptance: prints every D8 field; agents run
it; not in CI. Test: `node scripts/cmux-next/page-bundle-report.mjs` after `build-pages-web.sh --out /tmp/pages`.

**052 Code cache spike.** Files: fork code_cache_host_impl allowed schemes; build-pages.mjs (optional). Change: try
in-memory code cache for cmux-page in the pages context with content-hash checks; record that build-time bytecode
is not available for custom schemes in CEF. Acceptance: code only if warm open p95 improves beyond noise;
otherwise a perf-lead.md row. Test: open bench with and without the flag on one mini.

**053 Agent pane shared chunk.** Files: build-agent-pane-web.sh, build-pages.mjs, the agent descriptor CSP. Change:
the agent entry joins the multi-entry run. Acceptance: same React chunk URL as pages; agent bytes excluding shared
do not grow; New Tab first paint does not regress. Test: `--check`, bundle report, open bench.

**054 Update card.** Files: UpdateSurfaceIsland.swift. Change: made through webUI.open in the privileged WebKit
group, registered with PageLifecycle, closed when dismissed. Acceptance: no page with no update; closed on dismiss.
Test: CmuxNextAppTests filter UpdateSurface.

**055 Ad blocker later.** Files: CEFRuntime.swift, CEFSwitches.swift, fork runtime extension load (if needed).
Change: after 001 confirms the third renderer, load the built-in extension at the first default-profile browser
tab. Acceptance: Home with no browser tab has 0 extension renderers; the extension loads before the first tab's
load call (test). Tell the browser owner. Test: home bench; fleet first-tab ad block test.

**056 Home footprint test.** Files: Tests/CmuxNextAppTests/HomeWebFootprintTests.swift (new),
AppServices+AfterFirstFrame.swift. Change: run startLaterTabWarmups with fake engines (Chromium default, then
WebKit) and a settled clock; check the registry and spares. Acceptance: red at base, green at head, both in the
commit. Test: HomeWebFootprintTests.

**057 Hang notice.** Files: PageChromiumHosting.swift, CEFPageChromiumPage.swift, PageWebView+Chromium.swift. Change:
forward OnRenderProcessUnresponsive/Responsive for page tabs; a shown page shows the "Page unresponsive" card
(CmuxDialogSpec); Exit ends the group renderer and 039 takes over. Acceptance: no main-thread wait; no NSAlert;
hidden pages show the card only when shown. Test: PageWebViewChromiumTests; page-hang-live.py.

**058 Chromium ended.** Files: PageWebView+Chromium.swift, WebUIHost.swift. Change: on `ended`, pages wait for the
helper-app supervisor restart; after its give-up (60 s), shown pages fall back to WebKit through their group;
hidden pages fall back when shown. Agreed with PL-cef-helper. Acceptance: 8 fake pages, 1 shown: 1 WebKit engine
after give-up, 0 before. Test: PageWebViewChromiumTests (fallback storm case, red at base).

**059 Cleanup.** Files: CEFTab+Freeze.swift, plans/cmux-next/react-pages.md, new-tab.md, speed-of-sound-DESIGN.md,
tab-lifecycle.md, threading-model.md. Change: delete dead spare code; update the docs rows for this program; list
the PageLifecycle and slot DemandTimer owners. Acceptance: `git grep freezeNeverShownPage` == 0 or one fork < API
caller with a reason. Test: compile-check --app and --package CmuxNext.

**060 Testing phase.** Files: plans/cmux-next/perf-lead.md. Change: run every D1-D12 row at the head, pinned and
train, light and STRESS, on macOS 26 and 27; launch smoke on 14 and 15 with os-matrix.sh; base baseline from
002. Acceptance: every row has a value, sha, host and job id; each failing row has a follow-up task id. Test: this
task.

**061 Close every page.** Files: InternalPageTabStore.swift, WebUIHost.swift, PageWebView.swift,
CmuxNextApp/TopPages/BrowserAppTopPages.swift, Tests/CmuxNextAppTests/PageTabCloseTests.swift (new). Change:
InternalPageTabStore.forget calls `webUI.close(view)` for every PageWebView in the closed tab's content; HistoryTopPage
and the other BrowserAppTopPages tabClosed call close(); in DEBUG, PageWebView's deinit asserts close ran.
Acceptance: open and close each of the 14 web page providers with a fake: 0 live pages and 0 registry entries; no
provider-specific code needed. Test: PageTabCloseTests red at base; tagged build, Keybindings open/close 10 times,
`debug.cef` tab count back to baseline.

**062 Remove closed hosts.** Files: CEFPaneHost.swift, CEFRuntime.swift, Tests/CmuxNextBrowserTests/CEFPaneHostReleaseTests.swift.
Change: when the last tab leaves a non-spare host whose pane is gone, remove it from `runtime.hosts` (page keys
always; browser panes when the pane closes). Acceptance: 20 opens and closes return hosts.count to its start;
spare giveBack keeps its host. Tell PL-cef-tab. Test: CEFPaneHostReleaseTests red at base.

**063 One Chromium window per pane for pages.** Files: ChromiumPageHost.swift, WebUI/PageOpenRequest.swift,
PageChromiumHosting.swift, InternalPageTabStore.swift. Change: PageOpenRequest carries the pane key; makePage uses
`cmux-page-<pane>-<window>`; page tabs of one pane are tabs of one Chromium window; a moved tab uses the existing
tab-move path. Acceptance: 5 page tabs in one pane: 1 CEFPaneHost; a move gives 2; moving back closes the empty
host. Tell PL-cef-layer, PL-cefhost, p03-rendering. Test: CmuxNextAppTests filter ChromiumPageHost,
CmuxNextBrowserTests; pages10: CEF windows <= panes in use.

**064 PageRetirer.** Files: WebUI/PageRetirer.swift (new), WebUIHost.swift, CmuxNextApp/NewTab/AgentPageRetirer.swift
(deleted), AgentTabs.swift. Change: retire detaches the view at once and closes the engine page on one DemandTimer
at a quiet moment, for every page; the routes, subscriptions and bridge end in the close's turn. Acceptance: 0
engine close calls in the close turn, 1 after the timer; the page's routes and subscriptions end in the close's
turn; `final class AgentPageRetirer` == 0. Test: PageRetirerTests, WebUIHostTests; CmuxNextAppTests
DebugSettingsHangWatchTests and InternalPageDiscardPolicyCoverageTests; bench-webui.py open
`settings.cmd_w_engine_close_calls` == 0 (`debug.webui` `retire`).

**064b Reopen Closed takes back a retired page.** Files: WebUI/PageRetirer.swift, WebUIHost.swift, PageRouter.swift,
CmuxNextApp/InternalPages/InternalPageTabStore.swift, Handlers/CloseUndoToasts.swift. Change: undo-close
re-adoption, left out of 064 (the daemon's closed history reopens a page tab as a new tab): keep each closed page
tab's view by its closed record while the retirer holds it; a Reopen Closed or close-toast Undo before the deadline
takes it back, gives its router the new routes and reloads its document in the same engine page. Chrome's
TabRestoreService makes a new WebContents, so the commit says what the reuse saves. Acceptance: a page tab closed
and reopened before the deadline shows the same view and its engine page never closes; one reopened later opens
a new page. Test: PageRetirerTests; CmuxNextAppTests filter ClosedHistory, CloseUndoToasts.

**065 Native pushes while frozen.** Files: PageWebView+EngineNeutral.swift, PageWebView.swift,
CmuxNextDesign/GlassLens/GlassBackdropFeed.swift, AgentPaneView.swift, Tests/.../PageFrozenEvaluateTests.swift.
Change: while frozen, PageWebView.evaluate keeps the last script per kind (theme, glass, scale, pointer: latest)
and sends them in the thaw batch before held router events; a user-initiated call thaws first (MQ12 verdicts).
GlassBackdropFeed drops its frame observers while its host is hidden. Acceptance: 0 evaluate calls to a frozen page
over 60 s of theme and wallpaper changes; one theme and one glass push on thaw; 0 GlassBackdropFeed observers while
hidden. Test: PageFrozenEvaluateTests, CmuxNextDesignTests.

**066 Provider freeze hooks and relays.** Files: PageProvider.swift, PageRouter.swift, CmuxNextApp/Pages/PageProviders.swift,
PageRelayChannel.swift, WebUIHost.swift. Change: `pageWillFreeze()`/`pageDidThaw()` (Chrome
OnJavascriptDisallowed/Allowed); DaemonPageRelay cancels `.resync` listens on freeze and sends one resync on thaw;
PageRelayChannel moves into WebUIHost and closes its daemon connection 30 s after its last listener and call.
Acceptance: 30 s after Settings and History freeze or close, 0 page-relay clients (fake DaemonService); one
resync per stream on thaw; MQ10 `channels` hit == 0. Test: CmuxNextAppTests filter PageRelayChannel.

**067 Daemon subscription filter.** Files: cmux-tui/crates/cmux-tui-core/src/server/cmd_subscribe.rs, event_bus.rs,
origin_gate.rs, tests. Change: compute an event-kind interest set from page_events once and pass it to
mux.subscribe; if the bus cannot filter, check the MuxEvent variant before building JSON. Acceptance: a page relay
for 'history-changed' receives 0 of 10,000 SurfaceOutput events and builds 0 JSON values; the wanted event still
arrives; normal subscribers unchanged. Read cmux-tui/AGENTS.md first. Test: `cargo test -p cmux-tui-core
cmd_subscribe` on the fleet; bench-idle with 4 relays and `yes`.

**068 Browser scripts skip pages.** Files: CEFDocumentScripts.swift, CEFAgentRelay.swift, ChromiumPageHost.swift,
Tests/.../CEFDocumentScriptsTests.swift. Change: page tabs skip the relay attach; every document script starts with
the cmux-page guard (or the shim takes a scheme exclusion). Acceptance: 0 bridge attaches for a page tab on the fork
24 path; table test checks every source's guard; browser tabs unchanged. Test: CEFDocumentScripts and
CEFAgentRelay suites.

**069 MQ4b polls.** Files: webviews/src/diff-viewer/freshness.ts, optchat-inspector/store.ts,
agent-session/acpmux/conversation/backgroundTaskOutput.ts, agent-session/acpmux/links.ts, and every other poll loop
in MQ4b. Change: verdict per hit; each poll loop pauses while hidden and checks once on resume. Acceptance: verdict
list in the commit; a hidden diff page makes 0 host reads in 60 s (fake clock); each commit <= 400 lines. Test: bun
tests of the touched folders; pages10 with diff hidden: diff provider wakeups 0/s.

**070 Frame pacer.** Files: AgentPaneFramePacer.swift, AgentPaneVisibilityProbe.swift, AgentPaneView+Transport.swift,
tests. Change: the pacer reads `isFrozen` from PageLifecycle: no calls and no fallback deadline while frozen; one
flush on thaw before the router batch; the probe reports to PageLifecycle instead of its own occlusion observer.
Acceptance: 60 s of frames while frozen: 0 calls, 0 deadlines; one call on thaw. Test: AgentPaneFramePacer suite.

**071 Web updates and OTA.** Files: CmuxNextWebUpdates/WebUpdates+SafePoint.swift, CmuxNextPages/WebDevOverrideWatcher.swift,
WebBundleOverlay.swift, WebUIHost.swift, webviews/src/web-abi.json, scripts/cmux-next/web-bundle-key.py, tests.
Change: the safe point goes through WebUIHost; only shown pages (both engines) are asked and reloaded; hidden and
frozen pages are marked stale; the slot drops and rebuilds; the previous tree's `_shared` files stay served while a
document from it lives; `_shared` in OUTPUTS; one abi bump for the branch; the watcher and served-views statics
move into WebUIHost. Acceptance: 1 shown and 4 frozen fake pages: 1 asked, 1 reloaded, swap never blocked; an old
frozen document loads its lazy chunk from its own tree; abi changes once in the branch diff. Test:
WebUpdatesFrozenPagesTests red at base; page-swap-visible-live.py.

**072 One shared chunk for every web tree.** Files: scripts/build-webviews-app.sh, build-agent-activity-web.sh,
web-overlay.sh, web-bundle-key.py, CmuxNextUpdater/WebUpdates/WebUpdateTree.swift, WebDevOverride.swift,
WebBundleOverlay.swift. Change: webviews-app and agent-activity import the shared React chunk; overlays serve
cmux.shared from the same update as the page. Acceptance: one React chunk URL across all trees; a swap test resolves
every chunk named by every index.html in the same tree; WebUpdateTreeTests pass. Test: build-web-bundles.sh, bundle
report, CmuxNextUpdaterTests filter WebUpdateTree.

**073 Delete the old agent host.** Files: AgentPaneView.swift, AgentPaneBridge.swift, AgentPaneSchemeHandler.swift,
AgentPaneNavigation.swift, AgentPaneView+Warmup.swift, AgentPaneTunables.swift, AgentTabs.swift. Change: remove the
path that runs only when agent.pageHost and agent.chromium are both off. Acceptance:
`git grep -n 'AgentPaneWKWebView\|static let processPool = WKProcessPool\|AgentPaneSchemeHandler' -- Packages/macOS/CmuxNext/Sources`
== 0; no `pageHost:` init parameter. Tell the agent pane owner. Test: CmuxNextAgentPaneTests, AgentTabs filter,
compile-check --app; tagged build New Tab and a chat on both engines.

**074 AgentPaneView engine-neutral.** Files: AgentPaneView*.swift, AgentPageRedraw.swift, Handlers/WebInspector.swift,
DevToolsHandlers.swift, Control/DebugAgentPane.swift, Hints/WindowHintTargets.swift. Change: every MQ13 site moves
to the PageWebView engine-neutral API or an optional WebKit engine. Acceptance: MQ13 == 0 outside CmuxNextPages; no
stored WKWebView in AgentPaneView. Test: CmuxNextAgentPaneTests, CmuxNextPagesTests, compile-check --app.

**075 AgentActivityHostView fallback.** Files: CmuxNextAgentActivity/AgentActivityHostView.swift,
CmuxNextApp/AgentActivity/AgentActivityPageTab.swift, AgentActivityThemeTests.swift. Change: delete the fallback;
show the standard page error notice. Acceptance: `AgentActivityHostView(` == 0 outside tests or the type is gone.
Test: compile-check --app, AgentActivity filter.

**076 Settings domains off main.** Files: SettingsPageProvider.swift, PageFactory.swift, SettingsPaletteSource.swift.
Change: compute font families and sounds once in a `@concurrent` function at launch settle or Settings preload
selection; the domains call awaits the cached value. Acceptance: no font or directory enumeration on the main actor
(injected source asserts); same values. Test: SettingsPage filter; open bench Settings cold; debug.hangs 0.

**077 Fork surface copy and native click.** Change: `cmux_shim_tab_copy_surface(browser, max_w, max_h, callback)`
(CopyFromSurface, encode on the thread pool), `cmux_shim_tab_send_mouse_move(browser, x, y, modifiers)`
(SendMouseMoveEvent with no button, for 078's debug hover) and the API 29 native click for debug input. If PL-cef-layer's
`cmux_browser_capture` exists in the train, reuse it and add nothing. Acceptance: after a copy, the renderer has no
DevTools agent and is still shareable. Test: fork browser test.

**078 Remaining DevTools sites.** Files: PageWebView+WindowImage.swift, +EngineNeutral.swift, +Debug.swift,
+ChromiumMenu.swift, +Evaluate.swift, CEFShimLibrary.swift, CEFPageChromiumPage.swift. Change: each MQ3 site moves
to tabEvaluate, copySurface or the native click; DevTools kept only for fork < 29. Acceptance: MQ3 only in the
fallback branch; 0 devTools() calls for snapshot, menu copy, evaluate and debug click (fake). Test:
PageWebViewChromiumTests, EngineNeutralTests; pages10 DevTools sessions 0 (train).
As built: `PageChromiumPage` gains `copiesSurface`, `sendClick(at:)` and `copySelection()`; the three
`Page.captureScreenshot` sites share `PageWebView.chromiumPictureData`, whose DevTools branch runs only when the page
cannot copy its surface. The copy is `cmux_shim_tab_copy_surface` (optional export, fork API 38, answered by
`CMUX_SHIM_REPLY`; webui-DESIGN.md "Binding"), so its fallback covers forks below 38, not only below 29. MQ3 went
from 17 to 11 hits. Of 078's sites three stay, each in the fallback branch of a fork without the path: the picture
fallback, the debug press fallback (below 29), and the debug hover's `mouseMoved` (below 38: the native move is
`cmux_shim_tab_send_mouse_move`, a `post` optional export with `fork_api` 38 that 077's fork line adds). The other
eight are 013's bridge and setup sites (5), 014's `devToolsEvaluate` fallback and the `.devTools` event case
(declared and matched). The press and the hover report the path that ran in `delivered` (`native` or `devtools`).
A surface copy keeps alpha, so `snapshotKeepsClearAreas` is true for a page that copies. Its answer stays base64 on
the main actor and is decoded on the `.cpu` lane (the hide picture through `PageSnapshotEncoder.unpack`). Test:
PageChromiumDevToolsFreeTests, PageChromiumWindowImageTests.aLargeSurfaceCopyIsDecodedOnTheCPULane,
PageDiscardTests.theAppEncoderUnpacksASurfaceCopyOnTheCPULane, CEFRendererPathsTests
(aTabOnForkAPI38CopiesItsSurfaceWithNoDevToolsCall, aForkBeforeTheSurfaceCopyAnswersNoPictureAtOnce,
aTabMovesTheMouseNativelyFromForkAPI38, aPerformedScriptLeavesWithNoWaiter). The copy and the menu's Copy start no
task: the copy's answer comes in a synchronous turn (`CEFSurfaceCopies`), and Copy is sent with no waiter
(`CEFTab.perform`).

**079 Push channel.** Files: fork include/cef_cmux.h, libcef/renderer/, ChromiumPageHostBridge.swift, pageClient.ts.
Change: a fork export posts a string to the page's registered receiver; router batches and replies use it.
Acceptance: 0 evaluate calls for deliveries; events queue until the receiver registers; code lands only with a
gain beyond noise in renderer CPU per 1,000 events or p99 delivery at 10 Hz x 10 pages. Test: fork test, bridge
suite, delivery bench with and without the flag.

**080 Frozen chats leave acpmux.** Files: AgentPaneTransport.swift, AgentPaneView+Transport.swift, AgentPageHibernation.swift.
Change: a frozen chat with no running turn closes its transport connection; thaw reconnects with replay from the
last delivered seq. Acceptance: 0 acpmux connections for a frozen idle chat; one reconnect on thaw; no transcript
gap. Tell PL-acpmux. Test: Transport and AgentPageHibernation filters; acpmux-overhead.sh with 10 hidden idle chats:
about 25/s to < 1/s.

**081 Settings lazy sections.** Files: webviews/src/pages/settings/App.tsx (or the section router),
settings/lazySections.ts (new), settings/claimPaint.test.tsx. Change: navigation and the shown section in the first
module; other sections are dynamic imports after first paint; `#/settings/<section>?focus=` loads that section
first. Acceptance: first load holds one section; another section paints in one extra chunk load; claimPaint tests
pass. Test: `cd webviews && bun test src/pages/settings`, `bun run check`, bundle report, open bench.

**082 Page state for every page.** Files: webviews/src/pages/*/store.ts (batches of 5), pageClient.ts. Change: each
MQ14 page saves route, scroll and unsent inputs (<= 64 KB) on hidden and restores before first paint. Acceptance: a
bun round-trip test per page. Test: `bun test src/pages`, web-lint.sh; pages10 discard and reshow compares DOM
state.

**083 Renderer priority and purge.** Files: bench-webui.py (priority mode), scripts/perf-bench/procs.py, fork helper
priority path and purge on all-frozen (only if needed), CEFSwitches.swift. Change: read task role, darwinbg and
QoS of each page renderer and WebContent process when all pages are hidden, one shown, and only the preload parked;
fix in the fork if CEF renderers never background; on freeze ask the renderer to purge. Acceptance: a bench row per
process kind and state; purge code only with a recorded footprint gain. Test: priority mode on macOS 26 and 27.

**084 Chrome runtime idle services.** Files: CEFSwitches.swift, perf-lead.md. Change: census of CEF utility
processes and browser timers at Home; turn off each unused service (component updater, optimization guide,
variations, Safe Browsing DB updates, GCM/sync, translate, media router) with a named constant that cites the
Chromium source. Acceptance: one comment per switch; browser automation suite passes; Safe Browsing or update
changes only with a written decision. Tell the browser owner. Test: home bench before and after; fleet browser
automation suite.

**085 Agent origin sharing.** Files: CEFSwitches.swift, Tests/.../CEFSwitchesTests.swift. Change: with rendererPaths,
the cmux-page entry in PL-memory's per-site sharing switch (ProcessPerSiteUpToMainFrameThreshold, cap 8 for
cmux-page sites, web tabs keep 2), constant cites content_features.cc. Acceptance: present only with rendererPaths;
test for API 28 and 29; reviewed by PL-memory. At 154.0.8037.98 the threshold policy refuses a site that is not
HTTP(S), so this entry alone does not share `cmux.agent`; the "5 chats" row needs 011's reuse and cap (spike 091).
Test: CEFSwitchesTests; with 5 chats, cmux.agent renderers == 1 (train, with 011), measured with
bench_renderer_sharing.py.

**086 Fork train.** Files: scripts/cmux-next/cef-manifest.json, remote-browser-host.pin.json, perf-lead.md. Change:
reserve one API number per p13 export (page groups, renderer-less spare, discard, surface copy if not reused, push
channel), merge them into the shared fork branch with other programs' exports, one dist, one pin bump. Acceptance:
one new tag; a perf-lead.md row lists each export and number; no number claimed twice. Test: ensure-cef.sh fetch,
compile-check --app at the new pin.

**087 Capability test.** Files: Tests/CmuxNextPagesTests/PageProcessGroupCapabilityTests.swift (new),
WebUI/PageProcessGroup.swift. Change: compute each descriptor's capability class from namespaces, nativeOps,
actions, confirmedOps, CSP remote sources and dynamic prefixes; fail if a group mixes classes, if a host-power op
(shell.*, git.push/commit/worktree.*, file save, harness.*, transport.*) shares a group with a page that renders
repo or remote content, or if passwords shares. Acceptance: failure lists each group's ops; red on the design's
original `content` group, green on section 3.B. Test: fleet suite.

**088 Hide-time snapshot and state.** Files: PageWebView+Snapshot.swift (new), PageWebView+Discard.swift,
WebUI/PageLifecycle.swift, PageChromiumHosting.swift, CEFPageChromiumPage.swift, webviews/src/pages/shared/pageLifecycle.ts.
Change: on hidden, before freeze, keep the last frame (Chromium surface copy or hosted IOSurface; WebKit takeSnapshot
while attached); encode only when the planner picks the page for discard, on a `.utility` queue with a task-owner
comment; the page saves state on visibilitychange. Acceptance: 0 devTools() calls; no encode on main (queue
asserted); snapshot exists before freeze; a page frozen 300 s with no keep reason is discarded (red with the old
design's discard-time call). Test: PageDiscardTests.

**089 Automatic keep reasons.** Files: webviews/src/pages/shared/pageClient.ts, pageEdits.ts (new), pageEdits.test.ts
(new), agent-session dictation and draft hooks, PageLifecycle.swift. Change: one capture-phase input and change
listener per document; the first trusted edit sends keepAlive userEdits once; cleared by `cmux.page.edits.saved`,
route change or reload; beforeunload listener present sets beforeunload; agent dictation sets capture; unsent draft
or attachments set draft. Acceptance: no per-keystroke IPC; untrusted events ignored; every page gets it with no
per-page code. Test: bun tests, web-lint.sh, PageLifecycleTests.

**090 Preload park-state spike.** Files: bench-webui.py, plans/cmux-next/webui-DESIGN.md. Change: measure Cmd-T key to
cover frame and key to live frame (light and STRESS, 120 Hz) and parked wakeups for frozen-hidden and
rendered-parked, on both engines. Acceptance: a table of p50, p95, p99 and max per variant with sha, host and job id;
the D4 live-frame target is written from it. Test: open and home benches.

**091 Fork spike: process lock.** Files: fork chrome_content_browser_client_cef.cc, tests/ceftests/cmux_page_process_test.cc
(new). Change: build option A and option B (section 3.B); open 3 origins of one group with localStorage, fetch and
postMessage; record process count, each ProcessLock and any bad-message kill. Acceptance: results of both in
webui-DESIGN.md; 011 names the winner; diff < 200 lines. Test: fork browser test.

**092 One discard ranking.** Files: CmuxNextHibernation/HibernationPlanner.swift, PageLifecyclePlanner.swift,
CmuxNextApp/Hibernation/BrowserHibernation.swift, PageLifecycle.swift, Tests/.../UrgentDiscardRankingTests.swift.
Change: pure UrgentDiscardRanker over browser tabs, chats and pages (Chrome page_discarding_helper order: longest
hidden first, recently visible protected), stops at the reclaim target or after one discard with no target.
Acceptance: property tests; one pass per critical event; BrowserHibernation tests pass. Agreed with PL-memory before
start. Test: UrgentDiscardRankingTests, BrowserHibernation filter, pressure bench.

**093 Scheme handler shared chunks.** Files: PageSchemeHandler.swift, PageSharedChunkCache.swift (new),
Tests/.../PageSchemeHandlerSharedTests.swift. Change: at warm start, one background read (declared QoS, task-owner)
maps `_shared` into an immutable table; webView(_:start:) answers cmux.shared synchronously; overlays fall back to
the async path. Acceptance: 0 `Task {` hops for a shared request; table holds only bundled files. Test: suite; open
--engine webkit main-thread time before and after.

**094 Origin rename.** Files: MQ15 hits, PageDescriptor.swift, a generated TS origin table. Change: only if 091 picks
option B after its measured run (blocked until then, webui-DESIGN.md section 5.1): every page origin becomes
`<page>.<group>`, built in one place. Acceptance: MQ15 literals only in the
origin table and tests; CSP, router namespaces and storage tests pass; risk:high. Test: CmuxNextPagesTests,
`bun run check`, compile-check --app.
