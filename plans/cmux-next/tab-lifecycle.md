# cmux next: tab content lifecycle, warm sets, hibernation

Written 2026-09-30 for dogfood nxdog9 reports: fast tab switching is slow; a
page can disappear during fast switching and comes back after Ctrl-Tab then
Ctrl-Shift-Tab; fast workspace switching flashes the terminal; terminal and
browser switching lags; Chromium pages must hibernate (Chrome Memory Saver
parity), configurable and fully off.

## 1. One owner for "is this content visible"

Before: a tab's visibility was decided by three owners with no order
between them.

| Owner | What it did |
| --- | --- |
| `TabContentCache.applyRendering` | `Task { await tab.setOccluded(!render) }` per change: unordered, fire-and-forget |
| `CEFTab.setOccluded(true)` | awaited a `Page.captureScreenshot`, then hid the host view if the tab was still flagged occluded |
| `CEFPaneHost.present` | unhid the host view whenever the tab's content view entered a window |
| Chromium | echoed the activation of every tab it created or cmux activated; the echo, arriving late, selected that tab again |
| `CEFTab.attach` | applied focus asked for during creation (`SetFocus` activates and orders the page window front) even when the page was no longer shown |

Journal evidence (probe build, 200 rapid selections over 20 mixed tabs):
108 page hides; 59 of their screenshots completed after the tab was shown
again and were dropped only by the per-engine `isOccluded` flag.

After: `ContentLifecycle<Key>` (CmuxNextBridge, pure) holds one record per
tab, owned by the process-wide `TabContentCache`:

```
unmounted --show--> restoring --mounted(token)--> mountedVisible <--show/hide--> mountedHidden
mountedHidden --hibernate--> hibernated --show/wake--> restoring (restore effect)
any --crashed--> crashed --recovered--> mounted*
```

Every event bumps the tab's generation. Effects (`mount`, `reveal`,
`conceal`, `release`, `restore`) carry a token; an asynchronous completion
(terminal preview, page created or restored, hibernation probe) is applied
only while its token is current. `reveal`/`conceal` are applied
synchronously, hides before shows, so a pane never shows two tabs and a late
completion can never show, hide or reparent a newer selection's view.

- `BrowserTab.setContentVisible(_:)` replaces `setOccluded(_:) async`: the
  CEF page window is hidden before the call returns (Chromium then reports
  the page hidden: `document.visibilityState`, rAF, timers; measured by the
  no-spin agent). No screenshot on hide.
- `CEFPaneHost.present` keeps a hide the lifecycle applied.
- A Chromium activation echo selects a tab only when it is a choice made
  inside Chromium (another tab of a multi-tab window, not the host's own
  last activation).
- Focus asked for during creation applies only if the page is still shown.

Invariant (`SurfaceInvariantMonitor`, `debug.surfaces`): every visible
pane's selected tab has its content installed and drawing; a page's window
is visible over the pane (`content_visible`, `content_reason`); no other
tab's page window covers the pane (`foreign_pages`).

## 2. Switching performance

- Selection is coalesced per display frame: `applySelection` highlights the
  strip at once and queues `showSelected` on the frame scheduler, so holding
  Ctrl-Tab creates, attaches or reveals content only for the tab selected
  when the frame runs.
- Terminal warm set sized by memory (`WarmSetBudget`: 1/128 of RAM at 48 MB a
  surface, 4 to 12 hidden surfaces; pressure warning 4, critical 0). Browser
  pages no longer count in (or evict terminals from) that LRU; hibernation
  manages their memory.
- Workspace switches park the previous workspace (`WindowController.parked`):
  its layout view leaves the window but its panes stay in the keep-alive
  band (mounted, paused, never evicted). Switching back swaps the view in
  within the frame: no pane controller rebuild, no surface re-attach, no
  blank frame. Budget: at most 8 parked workspaces per window and as many
  parked panes in total as the terminal warm set (4 to 12); pressure warning
  one workspace of up to 2 panes, critical none. Many small workspaces stay
  warm; a few large ones do not crowd memory.
- No screenshot or PNG decode on the main thread on hide.

Bench: `scripts/cmux-next/bench-tab-switch.sh <tag>` (Ctrl-Tab held over 20
mixed tabs, terminal/Chromium toggling, back-and-forth, workspace switching;
frames, stalls, footprint, invariant).

## 3. Hibernation (Chrome Memory Saver)

cmux.json:

```jsonc
"browser": {
  // "hibernation" is unset by default: hidden pages only freeze, never discarded on their own.
  // Writing it turns discards on: "off" | "moderate" (30 min) | "aggressive" (10 min) | minutes
  "hibernationExclusions": ["mail.google.com", "*.example.com"],
  "hibernatePinnedTabs": false,
  "freezeHiddenTabs": 30,             // "off" | seconds: hidden Chromium pages freeze (power, msg 2654)
  "keepNeighborTabsAwake": 1          // 0-3 tabs on each side of a shown tab never freeze or hibernate
}
```

- Freeze (before hibernation, independent of its mode): a hidden Chromium
  page past `freezeHiddenTabs` seconds gets `Page.setWebLifecycleState
  frozen` (timers, tasks, rendering stop; memory and state stay). It thaws
  when shown, when an agent drives it (before the call goes out) and before
  the hibernation probe. Pinned tabs (unless `hibernatePinnedTabs`), excluded
  hosts, open DevTools, capture, playing media and Web Audio stay awake; a
  page kept for media is asked again after `freezeHiddenTabs`.

- Neighbors (plans/cmux-next/neighbor-tabs-DESIGN.md): the tabs beside each
  pane's shown tab (`keepNeighborTabsAwake`, wrapping) never freeze or
  hibernate and wake as soon as they become neighbors; a hovered tab wakes
  too. Memory pressure and Low Power Mode turn this off.

- A page never reloads unless the person asks (Leo, 2026-10-26: "why does
  cmux-next's browser keep refreshing and reloading? this happened before
  with austin using google maps"). A discarded page reloads when it wakes
  (script state gone; a page behind a login or sudo prompt can come back at
  the sign-in page), so with no `browser.hibernation` in cmux.json hidden
  pages only freeze and nothing is discarded on its own, at any memory
  pressure (`keeps_state` in `debug.surfaces`). Writing `browser.hibernation`
  (cmux.json, a timeout in Settings or the palette) turns the timeout and
  pressure discards below on. Settings and the palette show unset as "Never
  Discard", a choice of its own: the schema row has no
  default, so any written value ("moderate" included) is customized and
  Reset, or picking Never Discard, removes the key. Hibernate Tab always
  discards. A Chromium tab whose renderer ended shows
  the crash notice when shown and reloads only from its Reload button. Every
  discard (with its cause), restore, renderer end and Chromium-to-WebKit
  fallback is logged at notice or error level, so the field log keeps it.
- Triggers: time since last visible (one one-shot deadline for the earliest
  page), the memory pressure dispatch source (warning: 10 min, or every
  eligible page when aggressive; critical: every eligible page), and the
  Hibernate Tab action. No polling. "off" disables every trigger.
- Never: pinned tabs (unless `hibernatePinnedTabs`), excluded hosts, open
  DevTools, camera, microphone or screen capture in use, unmuted media
  elements playing, edited form fields (probe script with a 2 s deadline; no
  answer counts as busy), pages whose engine cannot restore their history.
  A running Web Audio context (`web_audio`) also keeps a page, at every
  memory pressure (lead rule 2026-10-24: audio, capture, form input, a running
  download and a `beforeunload` that asks are never discarded). It can be
  silent (a chat app's notification sounds); only the engine knows whether it
  is heard (Chromium's `WebContents::IsCurrentlyAudible`, a fork request).
  A `beforeunload` that asks (`before_unload`): the discard probe dispatches a
  `BeforeUnloadEvent` to the top document, as a close would, if the person
  used it (Chromium and WebKit ask only after a use); a child frame the person
  used reports whether it has a handler, which counts as asking. A connected
  `RTCPeerConnection` (`web_rtc`) keeps the page and stops it freezing, and
  so does an open USB, HID or serial device or a connected Bluetooth GATT
  server (`connected_device`; Chrome's kConnectedToUSB/Bluetooth). A child
  frame the person moved into that has no recorder (Chromium's cross-origin
  frames) counts as holding their input (`unreadable_frame`) while it is in
  the document; a frame the page focused itself does not. A page
  whose last answer kept it keeps the benefit of the doubt while it does not
  answer (`PageProbeHistory`). Web Audio and
  capture streams have no element, so a page-world recorder
  (`BrowserPageBusy`, installed at document start next to the media hub's
  actions script) wraps `AudioContext`, `getUserMedia` and `getDisplayMedia`;
  it is also the only capture signal for Chromium tabs, whose engine reports
  none. `scripts/cmux-next/hibernation-busy-live.py` checks Web Audio (top
  document and iframe) on a live build.
- A hibernated tab keeps URL, title, favicon, back/forward history with page
  state (scroll, form data) and a snapshot for the hover preview; its icon
  and title are dimmed in the strip. Selecting it restores the page; a
  navigation from the placeholder restores first.
- Snapshots (PR 23083): each hibernated page's last frame is kept
  JPEG-compressed at full size in its own 64 MB LRU (`HibernationSnapshots`),
  and the placeholder decodes it off the main thread while a pane shows it, so
  every hibernated tab wakes to its picture. They used to share the decoded
  32 MB preview cache at up to a quarter of it each, so only the last four kept
  one. Debug Settings > Tab Hibernation turns the old behavior back on.
- A woken page keeps the tab's last frame over it until the page's own first
  contentful paint (`BrowserWakeStandIn`; WebKit: `WebKitFirstPaintHandler`,
  Paint Timing in its own content world), or until its load ends with nothing
  painted, fails, is stopped, its process ends or the tab closes, and at most
  500 ms (a page that paints later shows itself loading; `uncovered_wakes_total`
  in `debug.surfaces` counts wakes whose page could show no picture). The web view
  stays visible to the engine under the picture, so it paints. Chromium tabs
  get the same with layer hosting (the picture over the page's CALayerHost,
  PL-cef-layer); until then a woken Chromium page shows the theme color until
  it paints. Known gap: WebKit restores the scroll position after the load,
  so a page that paints before that shows its top for a moment.
- Wakes are timed from the restore effect to the page being back and to its
  load ending, with whether a snapshot covered the pane and whether the tab
  was shown (`debug.surfaces` `wakes`, the latest 32).
- Bench: `scripts/cmux-next/bench_hibernation.py` (Chromium and WebKit tabs
  on local pages with a form and a stand-in heap): footprint and CPU awake,
  frozen and hibernated, counted from the processes that exit; wake times;
  scroll and form restore. Baseline on a capture mini (6e097d649d4, DEV build,
  6 tabs each, 40 MB heap): a hibernated Chromium tab freed 79 MB (its
  renderer exited) and a WebKit tab 61 MB; 6 hidden pages cost 0.03 to 0.08 %
  CPU (Chromium throttles hidden timers; freezing saved little more); a wake
  was back in 255 ms (Chromium) and 148 ms (WebKit) and usable in 302 and
  197 ms through the CLI, with scroll and form restored in 12 of 12. With
  PR 23083 the app's own times are: back in 41 ms and loaded in 157 ms
  (Chromium, p50), 57 and 161 ms (WebKit); all 12 kept a picture, 3.5 MB in
  total. The old cache held 12 there too: the capture mini's 1x display
  makes each decoded picture about 2 MB, while a large pane at 2x is capped
  at 8 MB, so four fit.
- WebKit: `WKWebView.interactionState`. Chromium: fork API 10
  (`cmux_tab_navigation_state`, `cmux_tab_restore_navigation`, session
  restore format); the page is recreated with an empty URL and its entries
  restored. On a fork before API 10 (API 7-9 refused every restore: a new browser holds its initial entry and a pending chrome://ignore/ navigation), Chromium pages are exempt
  (`unsupported`) rather than reloaded into a blank history.
- Actions: `browser.hibernation.off|moderate|aggressive` (palette, CLI
  `settings turn-off-tab-hibernation` etc.), `hibernateTab`, `wakeTab`
  (palette, tab context menu, CLI `tab hibernate`, `tab wake`).

### 3a. Which page goes first (smarter hibernation, 2026-10-21, msg 9103)

Before: every hidden page past one age threshold (`moderate` 60 min,
`aggressive` 10 min; 10 min under warning pressure) hibernated in the same
pass, and under critical pressure every eligible hidden page went at once.

Now (`HibernationPlanner.plan`):

- Ranking: idleness = seconds hidden, less a sixth of the timeout per
  doubling of shows in the last hour (at 30 min, 15 shows: 20 min later), plus under memory pressure 1 min per
  100 MB of the page's memory (at most 10 min; sampled from the resource
  source only under pressure, at most every 30 s). Least valuable first.
- Timeout: `moderate` is 30 min (default), `aggressive` 10 min, or minutes;
  under pressure at most 10 min.
- Relief: under warning or critical pressure with no page past the timeout,
  the least valuable page still goes.
- Pace (never all at once): normal 2 pages per pass, next pass after 5 s;
  warning 1 per 15 s; critical 3 per 3 s. A page hidden less than 60 s
  (10 s critical) never goes under pressure; without pressure the timeout
  decides. Under pressure a page the probe kept in the last 60 s comes last,
  so it does not hold up the rest.
- Never: shown pages; playing, muted-playing or Picture in Picture media;
  Web Audio; camera, microphone or screen capture; open DevTools; the
  person's form input or a POST result, also in a child frame cmux cannot
  read; a `beforeunload` that asks; a connected WebRTC peer; an open device;
  without memory pressure, a page whose site may show notifications
  (`notifications`, WebKit tabs; Chrome's kNotificationsEnabled keeps such a
  tab from proactive discards only); a running download the tab started (`downloading`);
  an agent's browser lease (`agent_lease`, also never frozen) or an agent
  call in the last 30 s; neighbors of a shown tab and hovered tabs; pinned
  tabs and Never Hibernate hosts unless the settings say otherwise.
- Never Hibernate This Site (tab context menu, palette, `tab
  never-hibernate-site`) adds the host to `browser.hibernationExclusions`.

## 4. Not done / open

- Root cause of the user's disappearing page not reproduced on a
  no-activate tagged build: the activation-dependent paths (page window key,
  `SetFocus` activating a hidden page's window) cannot run without app
  activation. The fixes remove every late-completion and second-owner path
  found; the invariant now reports the symptom if it recurs.
- A terminal surface shown after a pause can draw its last frame before the
  current one (no Ghostty "presented" signal yet); cold workspaces still
  attach at most one new surface per frame.
- A WebKit page's form fields come back from hibernation only if WebKit saved them, which it
  does when the page goes from shown to hidden. A page whose window was never on screen
  wakes scrolled with empty fields (measured on CI minis, PR 23083), so
  `aWokenPageHasItsScrollAndFormBack` checks the fields only when its window is on screen and
  `bench_hibernation.py` checks them on a capture mini. Reading the fields at hibernation
  and filling them in on wake would remove that dependence.
- Camera, microphone and screen capture exemptions are not checked live
  (they need a permission prompt and a device on the test host).
- The recorder misses: Chromium cross-origin iframes (out-of-process frames
  get no `Page.addScriptToEvaluateOnNewDocument` script without
  `Target.setAutoAttach`), legacy `navigator.webkitGetUserMedia`, a cloned
  track that outlives its stopped original, and contexts or streams a page
  made before the recorder was installed.
