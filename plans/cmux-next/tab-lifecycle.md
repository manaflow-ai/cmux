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
  "hibernationExclusions": ["mail.google.com", "*.figma.com"],
  "hibernatePinnedTabs": false
}
```

- Triggers: time since last visible (one one-shot deadline for the earliest
  page), the memory pressure dispatch source (warning: 10 min, or every
  eligible page when aggressive; critical: every eligible page), and the
  Hibernate Tab action. No polling. "off" disables every trigger.
- Never: pinned tabs (unless `hibernatePinnedTabs`), excluded hosts, open
  DevTools, camera or microphone in use, unmuted media playing, edited form
  fields (probe script with a 2 s deadline; no answer counts as busy), pages
  whose engine cannot restore their history.
- A hibernated tab keeps URL, title, favicon, back/forward history with page
  state (scroll, form data) and a snapshot for the hover preview; its icon
  and title are dimmed in the strip. Selecting it restores the page; a
  navigation from the placeholder restores first.
- WebKit: `WKWebView.interactionState`. Chromium: fork API 10
  (`cmux_tab_navigation_state`, `cmux_tab_restore_navigation`, session
  restore format); the page is recreated with an empty URL and its entries
  restored. On a fork before API 10 (API 7-9 refused every restore: a new browser holds its initial entry and a pending chrome://ignore/ navigation), Chromium pages are exempt
  (`unsupported`) rather than reloaded into a blank history.
- Actions: `browser.hibernation.off|moderate|aggressive` (palette, CLI
  `settings turn-off-tab-hibernation` etc.), `hibernateTab`, `wakeTab`
  (palette, tab context menu, CLI `tab hibernate`, `tab wake`).

## 4. Not done / open

- Root cause of the user's disappearing page not reproduced on a
  no-activate tagged build: the activation-dependent paths (page window key,
  `SetFocus` activating a hidden page's window) cannot run without app
  activation. The fixes remove every late-completion and second-owner path
  found; the invariant now reports the symptom if it recurs.
- A terminal surface shown after a pause can draw its last frame before the
  current one (no Ghostty "presented" signal yet); cold workspaces still
  attach at most one new surface per frame.
- Screen capture (getDisplayMedia) and WebAudio are not detected by the
  hibernation probe.
