# Workspace hibernation (2026-10-27)

Ask (Lawrence 14151): "we need the auto archive/hibernation feature ... should be configurable, but it
should pause workspaces that haven't been interacted with, and evict from RAM into disk reliably, and
be recoverable too".

Who else: Aziz (azooz2003-bit) owns manual archive (archiving-DESIGN.md, PR 25557 Archive Chief) and an
old `aziz/sidebar-lazy` branch (May, sidebar rows only). Nobody had workspace hibernation in flight.
Auto-archive (auto-archive-DESIGN.md, a678) only moves rows in the sidebar; it frees no memory. This
note is the memory half and reuses its idle signal and exemptions.

## What holds memory for a workspace nobody looks at (before)

| Holder | Where | Freed today |
| --- | --- | --- |
| Parked `WorkspaceContentController` (views, panes, strips, observations) | app | only at critical pressure (`releaseParked`); since issue 26046 also past 32 per window (`ParkedWorkspaceBudget`) |
| Terminal GPU surfaces | app | LRU warm set (4 to 12 hidden surfaces) |
| Browser pages (WebKit / Chromium renderer) | other processes, counted by the app's footprint | frozen after 30 s; discarded only when cmux.json sets `browser.hibernation` (off by default since #25791) |
| Agent chat pages (one web content process each, about 75 MB) | other processes | only when `browser.hibernation` is set |
| PTY, VT state and scrollback | `cmux-tui __terminal-host` (out of process) | never: that process *is* the terminal |
| Agent sessions | acpmux | never |

So the parked tree, its browser pages and its chat pages stay for as long as cmux runs: one window
that showed 50 workspaces keeps all 50 mounted.

## Behavior

A workspace is **hibernated** when it has not been shown in any window and nothing in it changed (output,
agent update, notification) for `workspaces.hibernation.idleMinutes` (default **60**). Hibernation:

1. Unmounts its parked content in every window (views, pane controllers, observations).
2. Destroys its terminal surfaces now (not at the LRU's leisure). Each keeps its last frame for an
   instant first paint; the terminal re-attaches from the terminal host's replay when shown.
3. Discards its browser pages through the browser hibernation path: the page's history and a
   compressed picture are kept, and the page restores (with its back/forward list and scroll) when
   the tab shows. Every page safety check still applies: edited form fields, playing media, capture,
   Web Audio, WebRTC, a connected device, an open DevTools, a download, an agent lease, an excluded
   host or a `beforeunload` handler keep that page awake. This is the one place pages are discarded
   without `browser.hibernation`: the person turned workspace hibernation on (it is on by default),
   and the checks keep every page whose loss they could notice.
   **This overrides #25791 ("a page never reloads unless the person asks") for hibernated workspaces
   only**: the person asked for real eviction from RAM (Lawrence 14151), so a page in a hibernated
   workspace reloads from its saved history when shown. Tabs in workspaces that stay awake keep
   #25791's rule. Pages the checks keep (form input, media, capture...) never reload.
4. Lets its agent chat pages go; the tab keeps its session and wake state (chips, shell text, scroll),
   and acpmux replays the chat when shown.

Nothing is paused or killed outside the app: PTYs, running programs and agents keep running; they are
never touched. "Evict to disk" for terminals is already the design: the terminal host owns the PTY
and scrollback out of process, writes its record before Ready, and survives app quit, update and
crash (pty-holder.md). A hibernated workspace's app memory is zero; its terminal state lives with the
host.

**Wake** is showing it: a click, Cmd-P, a link, a CLI focus. The window mounts it cold (as after a
launch), terminals attach from replay with their last frame shown first, pages restore from their
saved history.

### Never hibernated

- Shown in any window, including a `sidebar.multiView` companion and the workspace under a top page.
- Pinned.
- A command or an agent turn running in any tab, or an agent waiting on the person.
- **Keep Awake**: the person's per-workspace opt-out (workspace row ▸ Options, the palette,
  `cmux workspace toggle-keep-awake`). Stored per Mac (memory is per Mac), in one `UserDefaults` key.
- `workspaces.hibernation.enabled` false.

### Memory pressure

Warning: the idle time drops to 10 minutes. Critical: every eligible workspace hidden at least
60 seconds hibernates now (the existing `releaseParked` still unmounts parked views at once).

## Crash and restart safety

Hibernation writes nothing that restore depends on: the daemon's workspace journal, the terminal host
records and acpmux are the sources of truth before and after. A crash or quit in the middle of a pass
leaves each workspace either mounted or unmounted, and the next launch mounts nothing until shown, so
there is no half-evicted state to recover. The one write is the Keep Awake set (`UserDefaults`, atomic).
A discarded page's back/forward list lives in app memory (as for tab hibernation); after an app crash
that page restores from the daemon's URL.

## Cost

One `DemandTimer` deadline (the soonest workspace to come due, never sooner than 60 s after a pass).
A pass is O(workspaces + tabs) on the main actor, run at most once a minute; nothing per frame or key.
Showing a workspace and hiding one each add a dictionary write.

## Surfaces

| Surface | Entry |
| --- | --- |
| Settings > General > Hibernation | Hibernate Idle Workspaces (on), After (minutes) |
| cmux.json | `workspaces.hibernation.enabled`, `workspaces.hibernation.idleMinutes` |
| Workspace row ▸ Options | Keep Workspace Awake / Allow Workspace to Hibernate |
| Palette, CLI | Hibernate Workspace (`cmux workspace hibernate`), Keep Workspace Awake (`cmux workspace toggle-keep-awake`) |
| `debug.surfaces` | `hibernated_workspaces` |

## Files

- Domain (`CmuxNextHibernation`): `WorkspaceHibernationPlanner` (pure), `WorkspaceHibernation` (the
  coordinator: shown/hidden times, hibernated set, one deadline; `WorkspaceHibernationHost` and
  `WorkspaceHibernationDeadline` are its seams), `WorkspaceKeepAwakeStore` (the opt-out).
- Facts: `CmuxNextBridge/WorkspaceActivityFacts.swift` (newest activity, pinned, running, waiting).
- Ledger: `SurfaceLedger.evictHidden` destroys a hidden surface now.
- App: `AppServices+WorkspaceHibernationHost.swift` (one-line forwards), `WindowManager.releaseParked(_:)`,
  `TabContentCache.hibernateTabs`, `BrowserHibernation.hibernateForWorkspace`,
  `AgentPageHibernation.releaseForWorkspace`, handlers in `HibernationHandlers`.
- Settings: `schemas/settings/source/workspace-hibernation.json`, `WorkspaceHibernationSettings`.
- Tests: `WorkspaceHibernationPlannerTests` (planner, settings, ledger), `WorkspaceHibernationTests` (coordinator).

## Open

- The terminal host keeps an idle terminal's scrollback and 8 MiB output ring in its own RAM. Moving
  an idle host's ring to disk is a host-protocol change (the host is meant to never update,
  pty-holder.md D1-D5) and is left for that lane.
- Measured numbers: see the report in the commit that lands this.
