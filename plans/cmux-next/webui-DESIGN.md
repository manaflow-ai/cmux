# cmux pages work like Chrome WebUI

Status: design (p13-webui, chrome-parity program, 2026-10-25). Area doc for fault F3 in
[perf-lead.md](perf-lead.md). The full program spec, with counts, machine queues and the task list, is
[chrome-parity/p13-webui.md](chrome-parity/p13-webui.md); this file keeps the decisions a change in the area must
respect. Owner: PL-webui ([OWNERS.md](OWNERS.md)). `P/` = `Packages/macOS/CmuxNext/Sources/`. Chromium paths are in
chromium/src at main.

## 1. Goal

Every first-party page (Settings, History, New Tab, chats, viewers and the rest) shares a renderer with pages of the
same capability, is built only when it first shows, is told when it hides, freezes and later discards while off
screen (with Chrome's keep rules), and never wakes the app or the daemon while hidden. At Home idle, cmux holds at
most one parked preload (frozen or rendered-parked, per spike 090) in one renderer.

Pages stay in Chromium (Lawrence, F3: "we want a bunch of stuff in chromium"). The fix is cost, not engine. Every
rule below applies to WebKit pages too (F12: both engines stay).

## 2. Today

Measured in [speed-of-sound-DESIGN.md](speed-of-sound-DESIGN.md) sections 5 and 7: Home has 3 Chromium renderers
(185 MB, 1.78-2.02 % idle CPU), the whole tree is 793 MB against a floor of about 70 MB, and a hidden WebKit tab
(a browser tab, measured) wakes 11 times a second. The 3 Home renderers are probably the about:blank spare, the New
Tab spare and the built-in uBlock Origin MV2 background page; task 001 must confirm them. The causes:

- Each Chromium page has its own CEF window, its own renderer (each page id is its own site) and its own DevTools
  session, which also ends renderer reuse on the pinned fork. So every page tab opened after Home adds a renderer.
  Each WebKit page has its own non-persistent data store, so its own WebContent process.
- Four warmers run at launch: the about:blank CEF spare, NewTabSparePool (a full agent page off screen that is
  never told it is hidden), the PageHostPool WebKit Settings spare and the AgentPaneView WebKit warmup page.
- `TabContent.page` has no freeze and no discard. PageRouter delivers every event to hidden pages, and 33 native
  pushes (theme, wallpaper, scale, pointer, dictation, transport) skip the router.
- Closed page tabs can leak their engine page (four providers have no `tabClosed`; CEFPaneHost keeps page hosts).

## 3. Design

### 3.1 One owner: WebUIHost

The composition root builds one `WebUIHost` (`P/CmuxNextPages/WebUI/`). `open(PageOpenRequest)` is the only way to
make a page view; `close(view)` and `retire(view)` are the only ways to end one. The host tracks every page it
opened, so a closed tab always ends its engine page. It owns the one WKProcessPool (kept: it saves about 25 ms per
page build), the process groups, the lifecycle controller, the preload slot, the page relay channels and one
memory-pressure subscription shared with BrowserHibernation. Page statics move into it or are deleted.

### 3.2 Process groups by capability

A page shares a renderer only with pages of the same capability class, computed from its descriptor's namespaces,
native ops, actions, confirmed ops, CSP remote sources and dynamic prefixes. A unit test computes the table; when it
disagrees with this table, the test wins.

| Group | Pages | Why |
| --- | --- | --- |
| `agent` | agent (New Tab and every chat, one origin `cmux-page://cmux.agent`) | Same op set on every instance, as Chrome's NTP runs process-per-site |
| `privileged` | settings, cloud, apps, coderouter, keybindings, debugSettings, mobilePairing, history, stats, chiefUsage | Write ops on app state, no repository text or remote content |
| `viewer` | markdown, files, iconPicker, chiefViews, homeChannels, agentActivity, chiefInspector | Read or display ops only; they render repository text or remote images |
| `solo` | diff (`git.push`), editor (file save), changelog (remote media) | Host power or remote content with no peer of the same class: one process per page kind, each with a host label of its own (section 3.2) |
| `secrets` | passwords | Never shared (own host label, no process-per-site); discarded 60 s after it hides |

The group is not "renders untrusted text": that grouping put the agent page (`shell.run`, `git.push`) in one process
with markdown and changelog, which is weaker than one process per page.

Chromium mechanism. Chrome computes the process lock from the real URL, not the effective URL
(`content/browser/site_info.cc`, `MakeProcessLockComparisonKey`), and shares WebUI renderers through the TLD lock
rule (`IsWebUIAndUsesTLDForProcessLockURL`: `chrome://foo.bar/` locks to `bar`). A fork spike (task 091,
manaflow-ai/cef `cp/p13-webui-091` at `97674583`) builds that rule and the effective-URL option side by side and
records, for each group, the renderer count with two or more of its pages open, and any bad-message kill; its result
goes in section 5. It has not run.

Task 011 builds the TLD rule before 091 has a result (section 5 says why that is open). With it, the last host label
is the process lock, so only a shared group may own a last label. Pages of
`privileged` and `viewer` get `<page>.<group>` (`settings.privileged`, `markdown.viewer`), and the agent page keeps
`cmux.agent`. A `solo` or `secrets` page gets a single-label host of its own (`diff`, `editor`, `changelog`,
`passwords`), never `<page>.solo` or `<page>.secrets`: those would lock every page of the class to one label and share
one renderer. A one-label host never has a group's name (`viewer`, `agent`): it would get that group's lock. Hosts
are built only in `PageDescriptor.origin`.

A process lock only allows sharing; it does not cause it. Page tabs in different browsers or BrowsingInstances get
new processes unless the browser picks a live one. Chrome does that for top-chrome WebUI with
`ChromeContentBrowserClient::ShouldTryToUseExistingProcessHost`: `RenderProcessHostImpl::GetExistingProcessHost`
then takes a live renderer whose lock fits (`content/browser/renderer_host/render_process_host_impl.cc`). cmux-page
cannot share through process-per-site. Its map (`SiteProcessMap`, same file) is keyed on the whole SiteInfo
(`SiteInfo::MakeSecurityPrincipalKey`, which includes the full site URL and the AgentClusterKey), so it never
crosses origins. At 154.0.8037.98, `SiteInfo::ShouldUseProcessPerSite` (`content/browser/site_info.cc`) has no WebUI
rule (cmux-page has no WebUI controller and is not privileged embedder content), and
`ProcessPerSiteUpToMainFrameThreshold` refuses every site that is not HTTP(S) (`render_frame_host_manager.cc`,
`GetProcessReusePolicyForMainFrame`, `kSchemeIsNotHttpOrHttps`); plain process-per-site has no cap. So every shared
group (`agent`, `privileged`, `viewer`) uses existing-process reuse, and the fork applies the cap of 8 main frames
in a content hook (below), with the rules of Chrome's process-per-site threshold (`IsBelowReuseResourceThresholds`).
`secrets` and `solo` pages never look for a live renderer. Section 5.1 has the spike, which has not run.

The page bridge leaves DevTools: the host takes the sender's browser, frame and origin from the CEF frame that
delivered the message, never from the payload.

Fork implementation, proposed and not settled (task 077, manaflow-ai/cef `cp/p13-webui-077` at `d110ee57`, on the
cmux.33 line `c382c63b`). Nobody has built it or run its test, so 077 is not done. Snapshots stop using DevTools
(`Page.captureScreenshot`), because one DevTools agent ends main-frame renderer reuse for the whole browser
(`RenderFrameDevToolsAgentHost::WasEverAttachedToAnyFrame` in `render_frame_host_manager.cc`).

- One capture export. `cmux_browser_capture(browser_id, max_width, max_height, format, jpeg_quality, done, context)`
  is the export that PL-cef-layer planned for agent screenshots in the helper app
  ([cef-helper-app-DESIGN.md](cef-helper-app-DESIGN.md), "Page screenshots for agents"), built once here for both
  users; the train carries no second copy export. It copies the page as Chrome copies a tab thumbnail
  (`thumbnail_tab_helper.cc`, `RenderWidgetHostView::CopyFromSurface`), scales it down to fit (never up; the
  limiting side exactly at its limit, integer math) and encodes it on Chromium's thread pool as a fast PNG with alpha
  or as a JPEG. `done` runs exactly once on a thread pool worker, never on the main thread; a 2 s Viz deadline answers
  a page that never draws. `cmux_tab_devtools_state(browser_id)` reports a session on the page (the app's own
  protocol client included) and the process-wide ever-attached flag, which Chromium never clears.
- Native debug input. Debug clicks use the API 29 native click that already exists: `cmux_shim_tab_send_click`
  (`CefBrowserHost::SendMouseClickEvent`, view points, `CEFTab.sendClick`, host op `kOpTabSendClick`). Debug hovers
  use a move with no button, `cmux_shim_tab_send_mouse_move(browser_id, x, y, modifiers)`
  (`CefBrowserHost::SendMouseMoveEvent`, view points, `CEFTab.sendMouseMove`, host op `kOpTabSendMouseMove`): a
  `post` optional export with `fork_api` 40, the capture's number in the fork train (086), which gates it with the
  capture. A drag (a move with a button held) has no native path, so 078 keeps DevTools input for it.
- Binding (078, as built). The shim wraps the capture export as
  `cmux_shim_tab_copy_surface(browser_id, reply, max_width, max_height, format, jpeg_quality)`, an `async` entry in
  `optional_exports` of [chromium-host-ops.json](chromium-host-ops.json) with `fork_api` 40: the fork train (086,
  manaflow-ai/cef `cp/p13-webui-086`) numbers the capture 40 (`CEFForkFeatures.surfaceCopyForkAPI`); that line lacks
  API 28 and 29, so 40 alone does not mean the API 29 click.
  Its answer is a `CMUX_SHIM_REPLY` under the caller's reply id, as `cmux_shim_download_favicon` answers its image:
  value = width | height << 32 in pixels (0: no picture), json = the image in base64. The site-reply path already
  carries that event through the generated host wire, so no new event kind is needed. `CEFTab.copySurface` sends
  the request in the caller's turn, so the picture the page lifecycle takes as a page hides leaves before the hide.
  The answer stays base64 text (`CEFSurfaceCopy`, `PageSurfaceCopy`) on the main actor: a full window is megabytes,
  so its base64 and image decodes run on the `.cpu` lane (the hide picture through `PageSnapshotEncoder.unpack`,
  the other pictures in `PageWebView.chromiumPictureData`), as Chrome decodes images off its UI thread
  (services/data_decoder/public/cpp/decode_image.h).
  Its answer comes in a synchronous turn (`CEFSurfaceCopies`, as the built-in extension loads: the reply, a refused
  start, a deadline on the main deadline queue, or the browser's close), with no task waiting. It gates on
  `CEFForkFeatures.surfaceCopy` (the fork API at least 40, plus the shim export), never on a raw dlsym of the fork.
- The page host's DevTools sites (MQ3, 078). Window image, cover snapshot and debug snapshot use the surface copy
  (`PageWebView.chromiumPictureData`); the debug press uses the native click and the debug hover the native move,
  and both report the path in `delivered` (`native` or `devtools`); the menu's Copy sends `execCommand('copy')`
  through `tabEvaluate` with a user gesture and no waiter (`CEFTab.perform`); the selected text goes through
  `evaluate`. DevTools stays only in the fallback of a fork without the path (pictures and hovers below API 40,
  clicks and Copy below 29).
- Gate. A fork build must pass `ceftests --gtest_filter=CmuxTabSurfaceTest.*` in its own process, in order. Every
  page test fails at once if the ever-attached flag is already set when its page draws. The capture test then checks
  the exact fitted size (including a width limit that floating-point math missed by one pixel), an answer off the
  UI thread, no session, and the flag still clear. The positive control (a protocol message shows as attached) runs
  last. The test does not open a second same-site page to watch it share a renderer. On this line no main-frame
  reuse policy is on by default (`kNoReuseFeatureEnabled`), so two same-site pages get two renderers with or
  without DevTools. Sharing is measured by 011's `CmuxPageProcessTest` and 012's pages10 renderer count.

WebKit mechanism. One non-persistent data store per group, every view in the host's process pool,
`_setRelatedWebView:` per group, 8 pages per process, every SPI gated with `responds(to:)`
(`WebProcessGroups`, owned by `WebUIHost`; p07-memory-087 built the groups, task 015 the store per group).
Each membership (`.group(PageProcessGroup)`, or `.page(id)` for a `solo` page that asks) has one in-memory store,
made at its first page and kept for the app's life (`WebProcessGroups.dataStore(for:)`): two pages of one group
share localStorage, IndexedDB and storage events, and pages of different groups never do. Agent pages (the New
Tab page and chats) always share the agent store and their processes; the WebKit warm-up view takes the agent
store. With `webKitPageProcessGroups` every page of a sharing group joins it; without it only pages that ask
(`sharesWebKitProcess`) do, and every other page has a store of its own, freed when the page closes. A page that
shows in Chromium joins no WebKit group, and a `secrets` page never does.

Fork implementation, proposed (task 011, manaflow-ai/cef `cp/p13-webui-011` at `17a7f8ff`, on spike 091's branch).
Nobody has built or run it: the mechanism comes from reading Chromium 154.0.8037.98, not from a measurement. Do not
pin a dev dist from this ref, and do not start 012's pages10 check on it, until a fork build (`cmux-ci build cef`)
passes `ceftests --gtest_filter=CmuxPageProcessTest.*` and `ceftests --cmux-page-groups-off
--gtest_filter=CmuxPageProcessTest.*`. Record the renderer count per group and any kill in section 5.

- `cmux_page_scheme_set_group(host, group)` registers each host before CefInitialize. It refuses a host whose
  last label is not its group, a one-label host with a registered group's name, and a group with a registered
  one-label host's name, so a one-label page never gets a group's lock.
- With a group registered, `cmux-page` is a WebUI scheme (`GetAdditionalWebUISchemes`), so `<page>.<group>` locks
  to `<group>` and a one-label host to itself. With no group registered it is not one.
- An entry of PL-memory's `--cmux-page-scheme-process-per-site=<site>:<cap>[,...]` names a host (`cmux.agent:8`) or,
  with groups, a group (`privileged:8`). A registered `<page>.<group>` host uses its own entry, else its group's,
  and tries a live renderer first (`ShouldTryToUseExistingProcessHost`). Today 085 writes only `cmux.agent:8`, so
  the privileged and viewer groups share only when 012 or 085 adds `privileged:8,viewer:8`, from the same
  PageDescriptor table that names the groups.
- The content patch `cmux_page_process_groups` adds `ContentBrowserClient::ShouldUseExistingProcessHost`, asked only
  in `RenderProcessHostImpl::GetExistingProcessHost`. There the fork refuses a renderer that holds `cap` main frames,
  a page of another group, or a frame with a DevTools agent, as Chrome's threshold does. Pages that still talk
  through DevTools (until 013) therefore never share. The cap is not in `IsSuitableHost`, so a navigating page never
  moves off a full renderer.
- Without a registered group, a host the switch names shares only with its own host (085's agent page). A one-label
  host (`passwords`, `diff`) never shares. cmux-page never uses process-per-site.
- API 42, from the fork train (086, manaflow-ai/cef `cp/p13-webui-086`, on the API 31 line, which lacks 28 and 29).
  The app finds the export with dlsym (012); the switch goes only to a fork at 42 or later
  (`CEFForkFeatures.pageSiteSharingForkAPI`).
- What the WebUI scheme changes, which the fork build must show to be harmless (`content/browser/loader/
  navigation_url_loader_impl.cc` `Start`, `render_frame_host_impl.cc` subresource factories): a cmux-page
  navigation skips the navigation interceptors (service worker, DevTools network), and its terminal loader is
  `CreateWebUIURLLoaderFactory`, so the page loads only because CEF's `WillCreateURLLoaderFactory` proxy (the scheme
  handler) answers first. The page's own subresources get the same WebUI factory behind that proxy. The test's
  localStorage, same-origin fetch and postMessage on each page, and its check for renderer kills, cover these
  changes.
- An unregistered host whose last label is a group's name (`rogue.privileged`) gets that group's lock. The fork
  never sends it to a live renderer, but content's other reuse paths compare only locks. The scheme handler serves
  only the first-party hosts the app registered, so every host it serves must be registered.

### 3.3 Lifecycle: Active, Hidden, Frozen, Discarded

- One visibility source: ContentLifecycle (TabContentCache+Lifecycle) for `.page` content and agent tabs. No
  polling; one DemandTimer for the next deadline. The planner lives in CmuxNextHibernation next to
  HibernationPlanner, with one urgent-discard ranker for browser tabs, chats and pages
  (`components/performance_manager/policies/page_discarding_helper.cc` order).
- Hidden: the engine is told at once and the page sees `visibilitychange`. The page saves its state and native
  takes the snapshot of the last shown frame while the view is still attached. The router holds delivery.
- Frozen after 10 s hidden: Chromium SetPageFrozen; WebKit stays hidden in the window (suspend SPI if a spike shows
  it measures better). Providers stop their native sources and daemon relays. A thaw runs in the show's own turn,
  before the page is visible and before the held events, which go out as one batch. A built-in command or
  `evaluate()` to a frozen page thaws it first in the same turn.
- Discarded after 300 s hidden (60 s at warning, 10 s at critical): Chromium in-place discard, WebKit drops the
  view. Discard makes no call into the page. Show draws the snapshot in the key's frame and loads behind it.
- Keep reasons that block freeze and discard: visible, loading, recently visible (10 s), most recently used (the
  last hidden page), inspector open, focused, file drop pending, popup or sheet open, dictation or capture, an agent
  turn running. Block discard only: user edits, form interaction, a `beforeunload` listener, an unsent agent draft,
  pinned, a shell command ran, waiting on the person, a remote chat, and every Memory Saver reason that applies.
  Page JS can only add keep reasons.
- Each provider declares its frozen delivery policy (`.latest`, `.resync`, `.queue(limit)` or `.ordered`); the
  requirement has no default. Pages use `document.visibilityState` and the standard `freeze`/`resume` events, not a
  custom stream.
- A renderer crash marks every page of its group: shown pages reload once, hidden pages reload when shown, with a
  crash budget of 3 per 600 s per group.

Fork in-place discard (task 018, manaflow-ai/cef `cp/p13-webui-018` at `f844f729`; not built or run yet; API 39
in the fork train, 086; the app finds the exports with dlsym). `cmux_tab_discard(browser_id)` does what
Chrome does with `WebContentsDiscard` (`chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`
`FinishDiscardAndPreserveWebContents`): `AttemptFastKillForDiscard`, then `WebContents::Discard`. The fast kill ends
the renderer only when `RenderProcessHostImpl::FastShutdownIfPossible` allows it: no other page in the process, and
no beforeunload, unload, pagehide or visibilitychange listener, keepalive fetch or worker. Most sites have one of
these. So the result says which: `CMUX_TAB_DISCARD_DONE` (the process ended) or `CMUX_TAB_DISCARD_DONE_RENDERER_KEPT`
(the frames are gone and the page reloads when shown, but the process still runs). The tab keeps its WebContents, so
its browser id, its window slot, its NavigationEntry list and its session storage stay. When the page shows again,
`NavigationControllerImpl::SetActive` reloads the same URL and the document sees `document.wasDiscarded`.
The fork refuses, and changes nothing, in these cases:
- The page is not hidden: VISIBLE, or OCCLUDED, which shows as soon as its window is uncovered
  (`CMUX_TAB_DISCARD_VISIBLE`).
- The page is hidden but Chromium still paints it for a capture, Picture-in-Picture or XR
  (`CMUX_TAB_DISCARD_PAINTING`).
- Only the initial entry is committed, as in a renderer-less placeholder (017) or a first navigation that has not
  committed. A show would reload nothing (`CMUX_TAB_DISCARD_NOTHING_TO_RELOAD`).
- A navigation waits to commit (`CMUX_TAB_DISCARD_REFUSED`).

Every other keep reason is native's. `cmux_tab_was_discarded` stays 1 until the reload starts. The fast kill is a
`TERMINATION_STATUS_NORMAL_TERMINATION`, which CEF never sends to `OnRenderProcessTerminated`, so the crash budget
never counts a discard. A real crash of a group renderer that still holds a discarded page is reported and counted
as usual. The fork does not change Chrome's default: `WebContentsDiscard` stays off and `cmux_tab_discard` returns
`CMUX_TAB_DISCARD_UNAVAILABLE`. The binding (031) adds a default-off feature in `schemas/features/features.d`; when it
is on, the app passes `--enable-features=WebContentsDiscard` in `OnBeforeCommandLineProcessing`. Test:
`ceftests --gtest_filter=CmuxDiscardTest.*` (its browser delegate turns the feature on the same way).

### 3.4 Why cmux freezes WebUI when Chrome does not

Chrome never freezes WebUI: `CannotFreezeReason::kWebUI`
(`components/performance_manager/public/freezing/cannot_freeze_reason.h`) blocks it, beside `kLoading`,
`kRecentlyVisible` and `kMostRecentlyUsed`. The hazard it guards against: browser features call into WebUI pages and
wait for an answer, and a frozen page cannot answer. Chrome can accept the cost because a browser holds few WebUI
tabs at once. A hidden Chrome WebUI tab keeps its message handlers, observers and Mojo pushes live; hiding does not
disallow JavaScript (`WebUIImpl::DisallowJavascriptOnAllHandlers`, `content/browser/webui/web_ui_impl.cc`, runs only
when the renderer goes away or the page navigates or reloads).

cmux is different. A session holds many page tabs, each with a daemon subscription stream and native pushes, and
the targets ask for at most 1 idle wakeup a second and hidden memory near zero. A hidden page that keeps its timers,
streams and pushes misses both targets. So cmux freezes pages, and removes the kWebUI hazard: every built-in
command, `evaluate()` and held delivery to a frozen page thaws it first, in the same turn (section 3.3). Two more
rules keep a hidden page quiet: the router holds delivery while a page is hidden or frozen, and providers stop their
native sources on freeze. Chrome's three other reasons (loading, recently visible, most recently used) stay as keep
reasons, so a page the person just left never freezes under them.

### 3.5 One preload slot

At most one preloaded page document in the app, as Chrome's
`chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.h`. It replaces NewTabSparePool, PageHostPool
and the AgentPaneView warmup. It preloads New Tab by default (or a recently opened Settings, History or Cloud), none
under warning or critical pressure, after the first non-empty paint or a 3 s deadline, then 750 ms of quiet input,
so the off-screen load and first paint never run while the person types. It loads visible off screen at the target
pane size, keeps its first frame as the cover, then parks: frozen-hidden or rendered-parked (JS paused through
visibility, 0 wakeups), as spike 090 decides. Chrome's preload is never frozen; a frozen park is a cmux choice that
the spike must justify. A claim in the key's turn shows the cover in
that frame, then thaws and shows the page; open handlers stay `registry.bindEffect` handlers that return `.done`.
CEF spare windows keep the window with no renderer.

Fork implementation, proposed (task 017, manaflow-ai/cef `cp/p13-webui-017` at `dfdbea5a`, on the cmux.33 line
`c382c63b`). Nobody has built or run it. A Chrome-style browser created with an empty URL and
`extra_info[CMUX_EXTRA_INFO_NO_RENDERER] = true` gets a first tab made with
`WebContents::CreateParams::desired_renderer_state = kNoRendererProcess` and no navigation, as Chrome makes restored
tabs (`chrome/browser/ui/browser_tabrestore.cc`; it is active, so it is hidden only in a minimized window). No
`chrome://ignore/` load runs, so the tab takes no spare renderer and starts none. Its CEF browser is made before the
insertion, so in a tabbed embedder window it owns the window's BrowserView, and tabs added with `cmux_tab_add` are
plain tabs that load as before. `CefBrowserHostBase::Create` removes the key from extra_info in both runtime styles, so
no renderer sees it. `cmux_tab_renderer_state(browser_id)` reports whether the main frame's own RenderFrame is live
(`RenderFrameHost::IsRenderFrameLive`): a placeholder whose frame Chromium put in a shared live process above the
renderer process limit still reports 0. API 38 in the fork train (086); the app honors the key only
when it finds `cmux_tab_renderer_state` with dlsym (019, which also passes the key from the shim's window create).
On a fork build, `ceftests --gtest_filter=CmuxPlaceholderTest.*` (a regular Chrome window, the key in both styles)
and `scripts/test-cmux-embedder.sh <cef> placeholder placeholder-shared` (the tabbed embedder window the spare
uses, and the placeholder at `--renderer-process-limit=1`) decide whether it stays.

### 3.6 Lazy loading, shared chunks and the Home floor

No page view until its tab first shows, and no WKWebView in Chromium mode until a fallback needs it. Every page is
built against one shared, content-hashed chunk set served from `cmux-page://cmux.shared/`; Settings renders its
navigation and the shown section first (`chrome/browser/resources/settings/lazy_load.ts`). One web abi bump covers
the program.

Allowed at Home idle: app, daemon, the Chromium engine processes when Chromium is the default, and one renderer
(the agent group) with the parked New Tab preload (frozen or rendered-parked, per spike 090). Not allowed: the
about:blank renderer, the WebKit Settings spare, the WebKit warmup page, a WebKit process for the update card, and
the ad-blocker background page before the first browser tab.

Chromium's own spare renderer, proposed (task 020, manaflow-ai/cef `cp/p13-webui-020` at `5d16aa91`, on 017's
`1cb02dc4`). Nobody has built or run it. Chrome keeps one spare for the profile that last took a new process
(`content/browser/renderer_host/spare_render_process_host_manager_impl.cc` PrepareForFutureRequests), with no
destroy timer on desktop (only Android's kAndroidWarmUpSpareRendererWithTimeout sets one) and
kKillSpareRenderOnMemoryPressure disabled by default. The fork patch `cmux_spare_renderer_policy` adds
`ContentBrowserClient::ShouldWarmupSpareRenderProcessHost`; with `--cmux-spare-renderer-after-first-tab`
(`CEFSwitches.spareRendererAfterFirstTab`) a profile gets a spare only after one of its browser tabs starts an
http(s) navigation. The spare keeps Chrome desktop's lifetime (no timeout). The app passes the switch only with the
default-off feature `chromiumSpareAfterFirstTab`. Expected, not yet measured: the pages profile gets no spare, a page
open keeps the browser profile's spare, and Home with no browser tab has none. A cost to measure: today the default
profile's spare comes from the ad-blocker background page at launch and the first browser tab takes it; with the
policy, that first tab starts a renderer cold. The feature turns on by default only after a fork build gives these
numbers: bench-webui.py home (0 spare renderers with no browser tab) and open (first-tab and later
`cef_tab.new.visible` within the noise band), with the feature off and on. No fork ceftest checks the spare count yet.

### 3.7 Observability

`debug.webui` (DEBUG and bench builds) lists each page, spare and renderer with group, engine, pid, state, held
events, keep reasons and preload. Release signposts: `webui.lifecycle`, `webui.open`, `webui.preload`,
`webui.scheme`. `scripts/cmux-next/bench-webui.py` drives the existing benches; agents run it on the fleet. No CI
gate and no budget rows.

## 4. Rules for a change in this area

1. A hidden page gets 0 native pushes and 0 router deliveries (the router holds them); its timers run only as the
   engine throttles a hidden page. A frozen page also gets 0 timer ticks.
2. Groups never mix capability classes. Only a shared group (`agent`, `privileged`, `viewer`) owns a last host label;
   a `solo` or `secrets` page has a host label of its own, never `<page>.solo`. A change to a descriptor's ops reruns
   the capability test; group changes are `risk:high`.
3. Every WebKit SPI and optional shim symbol is gated, and the old-fork path keeps working.
4. Layers this area adds (cover, snapshot, stand-in) run with actions disabled.

## 5. Spike results

Spikes write their results here: the process-lock mechanism (fork, task 091, with the renderer count per group),
the preload park state (task 090), the WebKit suspend SPI (task 029) and the code cache (task 052). None has run yet.

### 5.1 Process lock across page origins (tasks 091 and 011): open, not run

Refs, status 2026-10-26:

| Ref | What it holds | Built | Run | Result |
| --- | --- | --- | --- | --- |
| manaflow-ai/cef `cp/p13-webui-091` at `97674583` | Spike: `--cmux-page-process-lock=off`, `effective-url` (A) and `webui-scheme` (B); the A/B ceftests | No | No | None. Expected per mode (privileged/viewer/secrets/agent of 9): off 3/2/1/9, A 3/2/1/1, B 1/1/1/2 |
| manaflow-ai/cef `cp/p13-webui-011` at `17a7f8ff` | B only, as the proposed mechanism (section 3.2); the spike modes are removed | No | No | None |

The A/B comparison can run only on the 091 ref: 011 removed option A. 011 chose B by reading Chromium, not by a
measurement. The reasons: A cannot share a process across origins (process-per-site keys on the whole SiteInfo,
and the lock comes from the real URL), and process-per-site with Chrome's threshold refuses non-HTTP(S) sites. Run 091's three modes
(`cmux-ci build cef` of `97674583`, then `ceftests --gtest_filter=CmuxPageProcessTest.*` with each
`--cmux-page-process-lock` value) and 011's two runs, then write the renderer counts per group and any kill here.
If B does not give 1 renderer for 3 origins with 0 kills, 011 and 012 change before 012 depends on the fork.

Status: open. The fork has not been built and the test has not run, so nothing in this section is measured and task
091 is not done. 011's ref is not pinned and task 094 stays blocked until the Measured column has a job id and values. The expected
values come from reading the Chromium source, and they are a hypothesis (expected B, unmeasured). The spike exists
to show where that reading is wrong.

Fork branch `cp/p13-webui-091` on manaflow-ai/cef (`9767458`, on `cmux/8037-cmux34-hosted-switch`), Chromium
154.0.8037.98. The switch `--cmux-page-process-lock` (browser process, off by default) selects an option in
`libcef/browser/chrome/chrome_content_browser_client_cef.cc`:

- `effective-url` (A): `GetEffectiveURL` maps `cmux-page://<page>.<group>/` to `cmux-page://<group>/`, and
  `ShouldUseProcessPerSite` is true for cmux-page.
- `webui-scheme` (B): `cmux-page` is an additional WebUI scheme (`GetAdditionalWebUISchemes`), so
  `IsWebUIAndUsesTLDForProcessLockURL` locks `cmux-page://settings.privileged/` to `cmux-page://privileged`.
  `ShouldTryToUseExistingProcessHost` is true for every grouped host (`<page>.<group>`, and the agent origin
  `cmux.agent` too), as Chrome does for `chrome://*.top-chrome/`. `IsSuitableHost` refuses a grouped renderer that
  already holds 8 main frames. This is the one cap of 8 for every group and every reuse path.

With the switch on, the browser logs each cmux-page renderer lock (`cmux-page-process-lock: site <url> lock
<lock>`). The test `ceftests --gtest_filter=CmuxPageProcessTest.*` opens one browser at a time (one BrowsingInstance
each, as page tabs are): `settings.privileged`, `cloud.privileged`, `apps.privileged`, `markdown.viewer`,
`files.viewer`, `passwords` (single label, the secrets class) and nine pages of `cmux.agent`. Each page uses
localStorage, a same-origin fetch and postMessage. The test asserts the renderer count of each group, that no
renderer holds pages of two groups, and that no renderer terminates (a bad-message kill). It logs each page's
renderer pid and each group's count.

| Option | Lock of `settings.privileged` | Renderers: privileged (3 pages) / viewer (2) / passwords (1) / agent (9) | Bad-message kills | Measured (job id, counts, logged locks, kills) |
| --- | --- | --- | --- | --- |
| off (Chrome default) | `cmux-page://settings.privileged` (expected) | 3 / 2 / 1 / 9 (expected) | 0 (expected) | not run |
| A `effective-url` | `cmux-page://settings.privileged` (expected) | 3 / 2 / 1 / 1 (expected) | 0 (expected) | not run |
| B `webui-scheme` | `cmux-page://privileged` (expected) | 1 / 1 / 1 / 2 (expected) | 0 (expected) | not run |

Why the source predicts these values. Under A, `SiteInfo::Create` computes the lock from the real URL
(`GetAgentClusterKeyForURL(..., /*effective_url=*/std::nullopt)`), the site-process map key includes that
AgentClusterKey, and `IsSuitableHost` refuses a renderer with another lock. Thus only pages of one real origin (the
nine agent pages) share, and with no cap. A lock override that forced A to share would fail
`CanAccessDataForOrigin` on the first localStorage access of a second origin, which kills the renderer. Under B, a
group has one lock, so the security checks see the lock that the navigation used. The ninth agent page passes the
cap and gets a second renderer.

Risks of B that the run must show are absent:

- A navigation to a WebUI scheme skips the navigation interceptors and uses `CreateWebUIURLLoaderFactory`
  (`content/browser/loader/navigation_url_loader_impl.cc`). That factory is still wrapped by
  `WillCreateURLLoaderFactory`, where CEF's proxy runs the scheme handler factories. If cmux's handler does not serve
  the page, the page does not load and the test times out.
- `ChildProcessSecurityPolicyImpl::CanRequestURL` lets only a renderer locked to `cmux-page` request a `cmux-page`
  URL. Web tabs then cannot load page resources. This is stricter than today and is wanted.
- The WebUI scheme list is read once per process (`URLDataManagerBackend::GetWebUISchemes`), so the choice is fixed
  at launch.
- In the 091 spike the cap is in `IsSuitableHost`, which `SiteInstanceImpl::IsSuitableForUrlInfo` also asks. A new
  navigation of a page whose renderer holds 8 main frames then moves to another renderer. Chrome keeps its own
  main-frame threshold out of `IsSuitableHost` (`IsBelowReuseResourceThresholds` in `render_process_host_impl.cc`),
  and 011 does the same: its cap is in the content patch `cmux_page_process_groups`, asked only in
  `GetExistingProcessHost` (section 3.2). The 091 run shows whether the spike's cap moves a page.
- `RenderProcessHost::ForEachRenderFrameHost` skips speculative frames, so pages that start to load in the same turn
  can pass the cap. The test opens pages in order; 011 measures concurrent opens.

Size. The fork diff is 344 lines (libcef 134, test 197, wiring 13), which is more than the 200-line limit of task 091.
Review asked for all four groups, the ninth-frame case and the cap in the spike, and the test carries most of the
lines. The lead accepts the size or asks for a cut.

No measured winner is named. After the run: if B gives 1 / 1 / 1 / 2 with 0 kills and every page loads, 011 uses B and 094 can
start. If B fails on page loading, the next try is the same last-label rule as a content patch (`site_info.cc`, a
scheme list from the embedder) without the WebUI scheme. If that also fails, groups fall back to one origin per
process (p13-webui.md risk 2). Run: `cmux-ci build cef --ref 976745836370f6b40e216235b198371d2b210bd3` for the fork,
then `ceftests --gtest_filter=CmuxPageProcessTest.*` three times (no switch, `--cmux-page-process-lock=effective-url`,
`--cmux-page-process-lock=webui-scheme`). Put the job id, the counts, the logged locks and the kills in the Measured
column.

### 5.2 Preload park state (task 090): open, not run

Status 2026-10-26: the bench is ready, the run is not. The table below is what the spike
fills; no cell is measured yet.

| Park | Engine | Session | Key to cover (ms) p50 / p95 / p99 / max | Key to live (ms) p50 / p95 / p99 / max | Parked wakeups/s p50 / p95 / p99 / max | sha | host | job |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| frozen | chromium | light | not run | not run | not run | - | - | - |
| rendered | chromium | light | not run | not run | not run | - | - | - |
| frozen | webkit | light | not run | not run | not run | - | - | - |
| rendered | webkit | light | not run | not run | not run | - | - | - |
| frozen | chromium | stress | not run | not run | not run | - | - | - |
| rendered | chromium | stress | not run | not run | not run | - | - | - |
| frozen | webkit | stress | not run | not run | not run | - | - | - |
| rendered | webkit | stress | not run | not run | not run | - | - | - |

The variants. Frozen-hidden: the preload is hidden to its engine, then frozen (Chromium SetPageFrozen; WebKit hidden
in its window with the throttling SPI, task 028); the census reports it `frozen`. Rendered-parked: the preload is
hidden to its engine and not frozen, so its JS sees `visibilitychange`, pauses its own work, and the engine keeps its
rendered frame; the census reports it `hidden` with `engine_visible` false. Chrome parks its preloaded WebUI the
rendered way and never freezes it (`chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.cc`,
`CannotFreezeReason::kWebUI`), so rendered is the default and frozen must earn its place.

How it runs: `scripts/cmux-next/bench-webui.py park --park frozen|rendered` (one variant per run; the bench sets the
debug tunable `webui.preloadPark`), 120 Hz host, light and `--session stress`, `--engine chromium` and `webkit`:
8 runs, each through the fleet entry
`cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/webui-bench.sh --ref <sha>
--artifact artifacts/webui-bench --arg=--modes=park,home --arg=--park=<state> --arg=--engine=<engine>
[--arg=--session=stress]`. Each run measures, from a preload parked as asked: the preload process's wakeups/s in
1 s windows over `--measure` s, Cmd-T key to the cover frame, key to the live frame (the first frame the page
painted after its show, when the cover goes), and the key's turn. A run whose build does not park as asked prints
every row `unscored` and is never a sample. Then, anywhere:
`python3 scripts/cmux-next/bench-webui.py park-table --run <job id> <artifact>/park/webui-park.json ...` prints the
rows above with sha, host and job id, and the decision with its targets.

The decision rule (`park_decision` in the bench): frozen wins only if, for every engine and session, its key to live
p95 is at most one 120 Hz frame (8.3 ms) worse than rendered's and at most 50 ms, and its parked process wakes less
(p50). Otherwise rendered. The D4 key to live frame target of each session is the chosen state's worst engine p95,
rounded up to whole 120 Hz frames, never above 50 ms.

D4 key to live frame target, until the run: <= 50 ms p95, light and STRESS (the ceiling in p13-webui.md D4). The
run replaces this line with the target the rule writes.

What the run needs first, read on perf/chrome-parity after 028 and 043 landed:

- Freeze and thaw on both engines (028): on the tip (`PageWebViewLifecycle.freeze()` asks the page view to freeze).
- A preload owner that reads `webui.preloadPark` and parks as asked: not on the tip. 043 (PagePreloadSlot,
  NewTabPreload) landed with one switch, feature `newTabParksHidden` (park hidden with the slot's cover, or render
  as the spare always did), and reads no tunable. Until the slot reads `webui.preloadPark` (or the bench selects
  the park through that feature), the census never shows the park asked and both variants print `unscored`. The
  default then follows the decision.
- `debug.new_tab bench_open` reporting `live_ms`: not on the tip. It reports the cover frame only (`visible_ms`),
  so key to live prints `unscored` (in the `open` mode too).

### 5.4 Code cache for cmux pages (task 052): open, not run

Status 2026-10-26: the fork change exists and has not been built; no number exists. No cmux product code changed: the
app passes the switches only through the Debug-only `CMUX_NEXT_CEF_EXTRA_SWITCHES`, so no build ships the cache.

What Chrome does. Chrome caches V8 bytecode of chrome: scripts only with `WebUICodeCache` (default off at 154):
`content/renderer/render_thread_impl.cc` registers chrome: and chrome-untrusted: as "code cache with hashing" (an
entry is used only for the same source text, `ScriptCachedMetadataHandlerWithHashing`), and
`content/browser/renderer_host/code_cache_host_impl.cc` accepts such a script only from a renderer locked to a WebUI
scheme, keys it by that lock and keeps it in its own `GeneratedCodeCache` (`webui_js`), never with the open web. Any
other custom scheme gets no code cache (`CheckSecurityForAccessingCodeCacheData`: "Invalid URL scheme for code
cache."). An off-the-record partition gets no code cache at all (`StoragePartitionImpl::Initialize`: V8 already keeps
one copy per renderer). cmux pages are `cmux-page://` in the off-the-record pages profile, so today a page's new
renderer compiles every script again. Build-time bytecode (`WebUIBundledCodeCache`, `generate_code_cache` in
`docs/webui/webui_build_configuration.md`) maps GRIT resource ids in the renderer; cmux pages come from the
embedder's scheme handler, so it is not available for them, and `webviews/scripts/pages/build-pages.mjs` does not
change.

The spike: manaflow-ai/cef `cp/p13-webui-052` at `a65b72d6` (code at `c6af944a`, on the pinned `c8953bc6`,
`cmux/8037-helper-items`; patch `cmux_page_code_cache`; 267 added lines with the libcef part and the doc rows).
`--cmux-code-cache-schemes=cmux-page` with `--enable-features=WebUICodeCache` gives cmux-page scripts the WebUI
rules above: accepted only from a renderer locked to cmux-page (an http(s) renderer that writes one is a bad-message
kill), keyed by the lock, kept in the WebUI cache; a renderer locked to cmux-page does not cache open-web scripts.
The renderer registers the listed scheme with hashing (`CefRenderManager::WebKitInitialized`; the switch is copied
to renderers). An off-the-record partition gets the WebUI
cache alone, in memory (`GeneratedCodeCacheContext::InitializeInMemory`: a `MEMORY_CACHE` backend of
`kMaxWebUICodeCacheSize`, 5 MB). Web, file, chrome and extension schemes are never listed. No export, no API number.
Chrome's own hot-script rule still applies: Blink stores only a timestamp on a script's first load, the code cache on
its second load within 72 h (`v8_code_cache.cc` `kHotHours`, `ProduceCacheOptions::kSetTimeStamp`), and uses it from
the third. The cache keys a script file by its URL: inline scripts get none (Chrome's `InlineScriptCache` is http(s)
only). The split build (049) has no inline script, and since 050 every page names every shared chunk by the shared
origin (`webviews/scripts/pages/build-pages.mjs`: `SHARED_ORIGIN`, `cmux-page://cmux.shared/<chunk>.js`), so a chunk
has one URL whichever page loads it. That one URL does not give one cache entry: the browser keys an entry by the
script's URL and by the lock of the renderer that ran it (`GetSecondaryKeyForCodeCache` returns
`process_lock.GetProcessLockURL()`, and the fork adds cmux-page to that rule). On this fork ref each page origin is its
own lock (`cmux-page://cmux.settings`, `cmux-page://cmux.history`), so a Settings renderer and a History renderer store
the same chunk under two keys, and each compiles it once. Two pages share a chunk's entry only under one lock: the
group lock of option B (section 5.1, `--cmux-page-process-lock=webui-scheme` on the 091 ref, the mechanism of 011),
where the pages of one group lock to `cmux-page://<group>`. This fork ref is on the pinned base, which has neither
mechanism, so this measurement shows no sharing across pages and claims none. The gain it can show is a renderer that
loads page scripts that another renderer of the same lock already ran twice: a cold Settings open after the Settings
renderer ended.

Cold open replaces the warm open of the task's acceptance (p13-webui.md 052: "warm open p95"; D4: "Warm open (group
renderer live)"). In a warm open the page runs in a live renderer that already compiled its scripts, so V8's
per-isolate cache serves them and the code cache is not read. A second page of the same group in that live renderer
does not help either: on this ref it gets a renderer of its own (a cold open), and under the group lock the live
renderer has already compiled the shared chunks at the same URLs, while the page's own entry has no code cache before
its second load. So no warm open can show this cache. The rule that lands code is therefore the cold row alone, and
the warm row is the control. The fork's `CMUX.md` row says the same since `a65b72d6`.

The measurement (`bench-webui.py open --page-code-cache`, task 052's arm; refused, exit 2, when a Chromium renderer
lacks the switch before the mode, while the first Settings open shows, or at the end, and when no renderer runs while
Settings shows):

0. A build that has 049 and 050 (`page-bundle-report.mjs`, task 051, shows the page's .js files and its
   `cmux-page://cmux.shared/` chunks). Settings is one page under one lock, so its entries are the same in both arms
   whether or not other pages run the chunks.
1. `cmux-ci build cef --arch arm64 --ref a65b72d6 --tag cef-stage-a65b72d6-arm64` (the fork branch head: `c6af944a`'s
   code and the `CMUX.md` row), staged with `scripts/cmux-next/cef-pin-staging.sh pin` on a test-only branch (never
   landed), then a Debug tagged build of that branch.
2. On one mini, the same build, alternating arms, 3 runs each:
   `bench-webui.py open --app APP --runs 20 --cold-runs 20 --chat-turns 0` and the same with `--page-code-cache`.
   The first open of each run sets only timestamps, so its cold sample is the same in both arms.
3. The deciding row is `settings.cold_open_ms`, p95 (p50 reported). `settings.open_ms` (warm) is the control: it must
   not get worse beyond the same noise. Noise is the spread of the off arm's three p95 values. A gain is an on-arm
   p95 that is lower than every off-arm p95 by more than that spread.

Result: not run. If the cold row does not gain beyond noise, or the warm row gets worse beyond it, the fork branch is
not pinned and perf-lead.md's row says so. If the cold row gains, the next step is a default-off feature that adds the
two switches, and the fork patch joins the train (178). Sharing across the pages of a group is measured only after
011's group lock is on the fork pin, with a cold open of a second page of the group in this arm.
