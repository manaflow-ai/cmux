# One browser tab in two workspaces

Status: first implementation, 2026-10-25. Ask (Lawrence, 2026-10-25): "ideally if a agent is
using cua on a browser like i see it on the right of the workspace. so we need to make it possible
for a browser tab to be in multiple different workspaces, and for cua stuff to be synced".

Related: [chief-browser-use-DESIGN.md](chief-browser-use-DESIGN.md) (`cmux browser right`, the
lease), [agent-cursor.md](agent-cursor.md), [tab-lifecycle.md](tab-lifecycle.md),
[computer-use-lead.md](computer-use-lead.md).

## 1. What existed

- A browser tab has one page, keyed by tab id (`TabContentCache.browsers`), never by pane. The
  surface ledger (`SurfaceLedger`) gives that page one presenter at a time; a pane that presents
  the key takes the view from the previous pane (`surfaceWasDisplaced`) with no reload. This is how
  a tab moved between panes keeps its page.
- A tab in a parked workspace is withdrawn: its page is hidden, frozen after 30 s
  (`browser.freezeHiddenTabs`) and later hibernated. So an agent working in its own workspace drives
  a page nobody sees, and `screenshot` of it may have no fresh frame.
- The agent cursor draws on a window-level layer and resolves one place per tab
  (`AgentCursorSnapshotBuilder` → `AgentCursorVisibilityResolver`): the tab's own pane when its
  workspace shows, else its sidebar row.
- No tab kind showed another tab's content. Chromium can hand out its page window's CA context
  (`CEFLayerHosting`, `browserResize.layerHosting`, off by default), which a second `CALayerHost`
  could draw, but that is Chromium only, takes no input, and is off.

## 2. Options

| Option | Cost | Input in the second place | Engines |
| --- | --- | --- | --- |
| A. Mirror chip: the second pane lists the same tab id and takes the one live view while it shows it | no new page, no new renderer, no frame copy; O(1) per switch (one reparent) | yes (it is the page) | both |
| B. Second `CALayerHost` on Chromium's CA context | no new page; WindowServer composites twice | no | Chromium, behind an off flag |
| C. Snapshot/stream frames into the second place | a capture and an encode per frame | no | both, at CPU and memory cost |
| D. A second page on the same URL | a whole renderer, diverging state | separate page | both; wrong (not the same tab) |

Picked A. It costs nothing while not shown, keeps one page, needs no new engine work, and the person
can take over in Home (click, type) because it is the real page. The one limit: one page view draws
in one place at a time. While another pane draws the page on screen (its own pane in another window,
or a second window's mirror), a mirror yields and shows nothing; it takes the page on its next show
once that pane stops drawing it. B is the follow-up for showing both at once.

## 3. Behavior

- Only a tab whose page the app draws can be mirrored (not a daemon-rendered or app browser tab).
- `browser.page.mirror {tab, pane?, off?}` (`cmux browser <tab_…> mirror [--pane P] [--off]`): lists
  the tab in `pane`'s strip too, default the column right of the Home chat. Selected unless the
  person's focus is in that pane. `off` takes it out of `pane`, or of every pane. It drives nothing,
  so it takes no lease. Refused for the tab's own pane (`invalid_params`).
- Home mirror: an agent's first write on a tab outside the Home workspace (any `browser.page.*`
  write naming `agent`) mirrors that tab into Home's right column; the agent's next such tab
  replaces its earlier mirror (at most one mirror per agent). A tab is mirrored once: a mirror the
  person closed does not come back when the agent writes again after its lease lapsed. A tab already in Home, or a request
  with no agent name, mirrors nothing.
- Showing the mirror presents the tab's page in Home's pane. While it is on screen it is the page's
  presenter, so the page renders and is not frozen or hibernated, though its own workspace is parked.
  Going back to the agent's workspace re-shows its selection there and takes the page back.
- The agent cursor follows the mirror: for a window whose shown workspace mirrors the target tab,
  the cursor snapshot places the tab in the mirroring pane (clicks, typing captions and the name tag
  draw over the mirror). The lease holder, `browser.page.state`'s `driver` and the tab's presence dot
  are the tab's own, so they are the same in both places.
- `browser.page.right` treats a mirrored tab the column shows as the shown tab (reads it without a
  lease; writes need `--take`, as for the person's own tab).
- The topology lists `mirrored_tabs` on a pane that has any; `tabs` stays the daemon's.
- Closing the mirror chip (×, Cmd-W) takes the mirror out; the tab and its page stay (the page's
  beforeunload never runs for a mirror's close). Closing the tab removes
  its mirrors. Mirrors are session state (not restored after a relaunch).

## 4. Screenshots

`browser.page.screenshot` stays refused for agents (`unavailable`) since 45fe246e9ab
(lawrencecchen, 2026-10-20, "fix(security): refuse unguarded app screenshots"): the app's page path
cannot reproduce the browser host's fail-closed secret mask (vault, TOTP and per-tab typed secrets
live only in `cmux-browser-host`). Not unblocked here. The safe route is gap 3 of
computer-use-lead.md: run Chromium tab captures through the host's CDP driver with its
`CAPTURE_MASK`. The mirror covers the person's need (watch live); agents keep `snapshot`.

## 5. Tests

- `BrowserTabMirrorTests` (CmuxNextControlTests): mirror defaults to Home's right column, names a
  pane, `off`; never into the tab's own pane; unavailable without a host; no lease; the Home mirror
  on an agent's first write, once; the next tab replaces it; unselected while the person works in
  that column; none for a tab in Home or an unnamed request; `right` reads a mirrored shown tab;
  pane JSON.
- `page_browser_use_tests.rs` (cmux-tui): the `mirror` verb and its flags.

## 6. Open

- B (a second `CALayerHost`) for two windows showing both places at once.
- A small "mirrored from <workspace>" mark on the chip; today it shows the page's title, favicon
  and the agent's presence dot.
- Agent screenshots through the browser host (section 4).
