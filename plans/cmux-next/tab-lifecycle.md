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
  "hibernation": "moderate",          // "off" | "moderate" (60 min) | "aggressive" (10 min) | minutes
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

- Triggers: time since last visible (one one-shot deadline for the earliest
  page), the memory pressure dispatch source (warning: 10 min, or every
  eligible page when aggressive; critical: every eligible page), and the
  Hibernate Tab action. No polling. "off" disables every trigger.
- Never: pinned tabs (unless `hibernatePinnedTabs`), excluded hosts, open
  DevTools, camera, microphone or screen capture in use, unmuted media
  elements playing, edited form fields (probe script with a 2 s deadline; no
  answer counts as busy), pages whose engine cannot restore their history.
  A running Web Audio context (`web_audio`) also keeps a page, except under
  critical memory pressure: it can be silent (a chat app's notification
  sounds, a game), and Chrome exempts audible tabs only. Web Audio and
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
  camera, microphone or screen capture; open DevTools; the person's form
  input or a POST result; a running download the tab started (`downloading`);
  an agent's browser lease (`agent_lease`, also never frozen) or an agent
  call in the last 30 s; neighbors of a shown tab and hovered tabs; pinned
  tabs and Never Hibernate hosts unless the settings say otherwise.
- Never Hibernate This Site (tab context menu, palette, `tab
  never-hibernate-site`) adds the host to `browser.hibernationExclusions`.

### 3b. One memory budget for hidden live pages (PL-hidden-memory, 2026-10-23)

Before: a hidden live page kept its whole renderer until the timeout (55 MB
per Chromium tab, 29 MB per WebKit tab, cmux20 2026-10-22), so 20 hidden
Chromium tabs held 1.1 GB for half an hour, and the floor is a 50 KB record
(speed-of-sound-DESIGN.md 3.3, F8 in perf-lead.md).

Now hidden live pages share the one warm-set budget with the hidden terminal
surfaces (`WarmSetBudget.pageCapacity`: 1/64 of memory at 56 MB a page,
4 to 16; warning 2; critical 0). `HibernationPlanner.plan(warmPages:)`
counts every eligible hidden page except the neighbors and hovered tabs, the
probe's recent keeps, the exemptions and the warm fronts. Each pane's shown tab
(`NeighborTabs.fronts`, what a switch shows again) is a front, grouped by
workspace: the fronts of a workspace on screen (its off-screen columns) and of
the workspace left last (`Front.warm`) stay out of the budget together, so a
column scroll or a switch back to the last workspace wakes nothing, however
many panes it has (the STRESS workspace has 12). The fronts of workspaces left
before that (`Front.parked`) count, in one idleness order with every other
page, with a bounded credit (`frontCreditShare`, one show: 5 min at the 30 min
default). So a tab left a minute ago in the pane the person works in still
ranks before a workspace left twenty minutes ago, and parked workspaces do not
each hold a renderer (before 2026-10-23 every front was out of the budget, so
every parked workspace held one for the whole timeout: O(workspaces), the
STRESS session's 10 Chromium workspaces ~550 MB; a first fix ranked all fronts
after every other page, so once they filled the budget no other hidden tab
stayed live, and the last workspace's panes past the budget went after a
minute). Hidden-page memory is bounded by the budget plus two workspaces'
fronts. A switch to a workspace left before the last one may wake its shown
pages (picture first; the Chromium wake cover until first contentful paint is
still open, below). Past the budget the least valuable (`overBudget`) are due
once hidden `overBudgetMinimumHidden` (60 s, the planner's "the person just
left it"), at the normal pace, through the same probe (form input, media,
capture stay). The timeout and memory pressure rules are unchanged; "off"
still disables everything. `debug.surfaces` hibernation reports
`page_budget` and `hidden_live_pages`. Tests: `HiddenPageWarmBudgetTests`.

Agent chat pages (one web content process each, about 75 MB) had no budget
either and waited for the whole timeout: a STRESS pane's five hidden chats held
~375 MB. `AgentPageHibernation` now applies a budget of the same size
(`pageCapacity`, a second budget, not a share of the browser pages': hidden
live pages are up to twice `pageCapacity`, on a 16 GB Mac 4 x 55 MB + 4 x
75 MB, about 520 MB) to the hidden chat pages it may release, ranked by the
same `HibernationPlanner.overBudget` (warm fronts out, parked fronts with the
credit, then the most recently left): the rest go once hidden
`overBudgetMinimumHidden`. A busy turn, pinned, New Tab and shell chats still
stay. A pane reports its new shown tab after it hid the old one, so a chat
hidden by a switch inside its pane is first planned as a front; the fronts'
change replans the chats (`frontsDidChange`). A released chat keeps its
session, wake state and last frame, as before. Tests:
`AgentPageHibernationTests.hiddenChatsPastTheWarmBudgetLetGoAfterAMinute`,
`parkedWorkspacesShownChatsCountInTheBudget`,
`aChatHiddenByASwitchInItsPaneCountsOnceTheFrontsMove`.

Review fixes (2026-10-23):
- Pace for chats. A switch that parks a workspace moved all its chat fronts past
  the budget in one call, and every release (wake-state JS, WKWebView snapshot
  and encode, retire) started inside the switch's frames. Chats and browser
  pages now share one pacing rule (`HibernationPlanner.paced`): at most
  `Pace.perPass` jobs in flight, counting the probes and releases still running,
  the next pass after `Pace.interval`. The extra events of one switch start no
  extra jobs. Tests: `chatsPastTheBudgetGoAFewAtATime`,
  `HiddenPageWarmBudgetTests.probesInFlightTakeTheirShareOfThePass`.
- "Just left" counts from the right event. A front hidden for minutes in the
  workspace left last became parked when a third workspace showed, and it was
  due in that same turn. Now the 60 s grace runs from the later of the hide and
  the moment the page started to count (`countedAt`, `Candidate.countedFor`), in
  both planners. Tests: `aFrontThatJustStartedToCountWaitsAMinute`,
  `aChatFrontThatStartsToCountWaitsAMinute`.
- "Left last" is per window (`NeighborTabs` takes the pane's `WindowState`), so
  a switch in one window does not park the workspace another window left last.
  Test: `NeighborTabsTests.eachWindowKeepsItsOwnWorkspaceLeftLast`.
- `NeighborTabs` is incremental: it keeps per-group pane counts, shown tabs and
  each window's group left last, and a pane report returns the fronts it moved.
  A switch costs O(switched panes), not O(switched panes x all mounted panes).
  Test: `incrementalFrontsMatchAFullRecompute` (3,000 seeded steps compared to a
  full recompute).
- A probe or frame that ends checks that the page is still due by a new plan
  (budget membership can revert while it runs) before the swap or the release.
- A page the probe keeps stays out of the budget, and without pressure is not
  probed again, for a backoff that doubles with each keep in a row (1 to 32 min,
  `keptHold(times:)`), not a fixed 60 s. Test:
  `aPageKeptTwiceIsNotProbedAgainAfterAMinute`.

Fleet test fixes (2026-10-23, after 04c2a95e2f7):
- A chat release counted as in flight only until its frame was taken, not
  while the frame was held (encoded): the pace undercounted, and
  `chatsPastTheBudgetGoAFewAtATime` ended while a release still ran, which then
  read the freed test rig (the crash on macOS 26 and 27). A release now counts
  until the page is gone or stays; the plan ranks the releases in flight (they
  are live until they go) and a pass starts only the others, so a release that
  checks it is still due sees the same plan.
- A connected chat that did not say in time what it holds stayed first in the
  budget order, so every pass asked it again and the chats behind it never went
  (the chats check: 1 of 3 released). It now stays out of the budget for
  `keptHold(times:)`, as a page the probe kept, and is asked again after that.
  Test: `aChatThatDoesNotSayWhatItHoldsDoesNotHoldUpTheOthers`.
- A one-line `<select>` with no default option counted as form input to a probe
  without the recorder's baseline (Chromium's late recorder, or no recorder):
  it shows its first enabled option, which no option's `defaultSelected` says.
  The field probe and the recorder share one comparison
  (`BrowserPageBusy.differsFromDefault`). The light bench's 4-5 kept pages.
  Test: `HiddenPageHibernationTests.aMenuWithNoDefaultOptionIsNoEditToTheFieldProbe`.
  `bench_hidden_memory.py` prints the reasons of the live bench pages (`live_kept`).

Review fixes (2026-10-23, after 0d76b05e5d2):
- The keptHold change removed the head-of-line block but not why a connected
  chat gave no wake state in 3 s: page script failures map to an empty state,
  so nil is a timeout, and with perPass 2 at least two chats timed out again and
  again. A release asked the page only when it went, a minute to half an hour
  after its hide, when a hidden web content process may answer late or not at
  all (background throttling, process suspension; differs by macOS). The page
  is now asked as it hides (`AgentPageHibernation.leftWith`); its hidden
  composer and transcript place do not change (a chip still encoding reaches
  the host's kept chips by itself), so the release uses that answer and asks
  the hidden page only when it gave none. The keptHold backoff stays for a page
  that is really busy. Test: `aChatThatAnsweredAsItHidGoesWithoutAskingItsHiddenPage`.
  Not yet measured: run the bench on the fleet and count the
  `kept: no wake state in time (asked at its hide: ...)` lines per chat.
- A chat that stays (no wake state) no longer takes a page snapshot first.
- The tests inject the frame (`AgentPageHibernation.pageFrame`), so every
  release holds one on every macOS, and the rig captures weakly; `settle`
  records an issue when a release outlives its cap.
- `differsFromDefault`: an option in a disabled `<optgroup>` is not enabled.

Wake picture: a hibernated page's JPEG took 10 to 30 ms to decode off the
main thread after its placeholder entered a window, so a woken tab showed an
empty pane for those frames. Each large picture now also keeps a decoded
preview (long side 384 px, ~360 KB, counted in the 64 MB store), shown in the
turn the placeholder enters a window until the full picture is decoded.
Tests: `HibernationWakePictureTests`.

A WebKit page restores in the same turn its tab shows, so the placeholder's
picture never reached a frame: the pane showed the new, unpainted web view.
The woken page's chrome now keeps the picture the placeholder showed
(`HibernatedBrowserTab.wakePicture`, decoded) over the page
(`BrowserChromeView.holdPicture(whileWaking:)`, no hit testing) until its
first load ends, its process exits, 400 ms after its document commits, or
2 s after the wake. In-view pages only: a Chromium page is a child window
above the chrome, so it still shows its theme-colored base from creation to
its first contentful paint (open). Tests: `WakePictureCoverTests`.

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
