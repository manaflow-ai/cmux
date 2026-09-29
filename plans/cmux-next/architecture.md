# cmux next architecture: state ownership, AppKit, performance

Priorities, in order: correct state ownership, low RAM, low idle CPU, input latency, then visual polish. Every rule below exists because the old app violated it.

## 1. State ownership

One owner per fact. The app never keeps a second copy that can drift.

| Fact | Owner | App holds |
| --- | --- | --- |
| Terminals: PTY, process, scrollback, grid, graphics, cwd, title | cmux-tui daemon | Only surfaces that are on screen. No scrollback in the app. |
| Layout: workspaces, workspace groups, screens, columns, splits, panes, tabs, tab groups, pins, order, names, colors | daemon shared tree (journaled) | A read-only mirror, updated from deltas. |
| Notifications and unread state | daemon | Mirror. |
| Saved tab groups (Chrome "save group") | daemon (session-wide, not per pane) | Mirror. |
| Browser tab url/title/favicon/profile | daemon tab record; the engine is the live source and writes back | Engine instance for visible and recently used tabs only. |
| Window list, frames, which workspace each window shows, sidebar width/collapsed | daemon `personal` frontend projection | Mirror, written back debounced (500 ms). |
| Focus, selection, hover, scroll offsets, drag state, palette query | app, in memory, per window | Never persisted, never sent. |
| Settings (density, shortcuts, colors) | cmux.json on disk | `DesignSettings`, `ShortcutStore` loaded from the file, file watcher reloads. |
| Auth tokens | Keychain (existing service names) | Nothing cached beyond the request. |

Rules:
- Mutations are intents: the app sends a daemon command with a transaction id, applies an optimistic local patch, and drops the patch when the delta carrying that transaction id (or a rejection) arrives. No heuristics like "daemon wins on the Nth snapshot".
- No app-side persistence of layout. Quit is free: nothing to save, because the daemon already has it. Relaunch = connect + snapshot.
- No singletons for model state. `DesignSettings.shared` and the daemon connection are the only process-wide objects; everything else is owned by a window controller and dies with it.

## 2. Model layer

- `DaemonConnection` (actor) owns the socket, decodes JSON off the main thread, and delivers coalesced deltas to the main actor at most once per frame (display-link aligned). A burst of 500 deltas becomes one model update.
- `SessionStore` (@Observable, main actor) holds the mirror as value types keyed by stable ids (`[WorkspaceID: Workspace]` + ordered id arrays). Views observe the smallest object they render: a tab row observes one `TabRecord`, not the store. Observation's per-property tracking only helps when models are fine-grained, so records are small final classes (@Observable) per workspace/tab/group, reused across deltas (identity stable, fields patched), not rebuilt.
- Derived data (sorted tab order with pins first, group spans, sidebar flattening) is computed incrementally when its inputs change, cached on the record, never recomputed per frame.

## 3. AppKit-first UI

SwiftUI is allowed only for low-frequency, form-like surfaces: Settings, onboarding, sheets. Everything on the hot path is AppKit with layer-backed views:

| Surface | Implementation |
| --- | --- |
| Window, titlebar, toolbar | `NSWindow` full-size content, custom titlebar view |
| Sidebar | custom layer-backed view, row view reuse (only visible rows exist), CALayer-based selection pill and drag gaps |
| Tab strip | one `NSView` per strip; tabs are CALayers (text via `CATextLayer` or pre-rendered glyph layers), not NSViews, so 100 tabs cost 100 layers, not 100 views with constraints |
| Layout (splits, columns) | manual frame layout in `layout()`, no Auto Layout in panes, one `CADisplayLink` per window for animations |
| Palette | `NSPanel` + custom list with row reuse; search runs off-main on a snapshot of the index, results delivered by generation number |
| Terminal | Ghostty Metal surface; paused (`ghostty_surface_set_occlusion`) when not visible |
| Menus | `NSMenu` built lazily from the action registry at open time |

Auto Layout is used only for static chrome (toolbar buttons, settings). No `NSHostingView` inside rows, tabs or panes.

## 4. RAM budget

Targets for dogfood (measure against the old app on the same machine, same workload: 20 workspaces, 120 terminal tabs, 5 browser tabs):

| Metric | Target |
| --- | --- |
| App resident memory, idle | < 150 MB (daemon measured separately) |
| Per hidden terminal tab in the app | ~0 (no surface; recreated on show from daemon replay) |
| Per visible terminal surface | < 15 MB beyond Ghostty's atlas |
| Per background WebKit tab | released after 10 min hidden (snapshot kept for preview, reload on show); CEF tabs likewise via discard |
| Hover previews | downscaled CGImages, LRU cache capped at 32 MB total |

Mechanisms:
- Terminal surfaces exist only for tabs that are visible (selected tab of on-screen panes) plus a small LRU (default 8) for fast switching. A hidden tab's surface is destroyed; showing it again attaches and replays from the daemon (replay is bounded by the daemon's replay budget; measure switch latency, target < 50 ms).
- Offscreen niri columns keep surfaces alive while within one viewport width of the visible range, otherwise they are released like hidden tabs.
- No per-tab timers, no per-tab observers of global notifications.

## 5. CPU budget

| Metric | Target |
| --- | --- |
| Idle CPU, window visible, nothing changing | 0.0% average over 60 s (no timers, no polling) |
| Idle CPU, window hidden | 0.0% |
| Keystroke to glyph (local daemon) | p50 < 8 ms, p99 < 16 ms |
| Tab switch (hot LRU) | < 1 frame; cold (replay) < 50 ms |
| 10 MB/s terminal output in one tab | app main thread < 25% |

Mechanisms: event-driven only (daemon deltas, AppKit events, file watchers); display link runs only while an animation or scroll is active and stops itself; delta coalescing per frame; JSON decode off main; git/cwd/agent status computed by the daemon, not the app.

## 6. Verification

A `cmux-next-bench` harness (scripted through the app control socket) records the metrics above into `artifacts/cmux-next-bench/<sha>.json` and compares against the old app baseline. Every dogfood build reports them. Regressions over 10% block the merge into feat-cmux-next.

## 7. Chrome tab group parity

Model (daemon): per pane, ordered tab groups; each tab placement belongs to at most one group; members contiguous. Saved groups are session-wide records that outlive their placements.

| Chrome feature | cmux |
| --- | --- |
| Create group from tab(s) ("Add tab to new group"), add to existing group | yes, tab context menu submenu lists existing groups with color dots |
| Name (empty name shows color dot only) | yes, inline edit in the group editor bubble |
| Color: Grey, Blue, Red, Yellow, Green, Pink, Purple, Cyan, Orange | same 9 choices, rendered as muted tints tuned for the gray UI (user group colors are content, not accent; "no blue" applies to app chrome) |
| Group editor bubble on chip click-and-hold / right-click: name field, color swatches, New tab in group, Ungroup, Close group, Move group to new window, Save group | yes, Liquid Glass bubble; every item is also an action (CLI, palette, shortcut) |
| Collapse/expand by clicking chip, collapsed shows chip only (+ count) | yes, animated |
| Collapsing moves selection out of the group | yes |
| Drag chip moves whole group, within strip, to other panes/windows, tear off to new window | yes, plus new split, new column, new workspace |
| Drag tab into/out of group by position | yes, with hysteresis |
| New tab opened from a grouped tab joins the group | yes (browser popups, "new tab to the right") |
| Pinned tabs cannot be grouped | yes |
| Saved groups (pin group): appear in the saved-groups bar; closing a saved group keeps it; clicking reopens it; unsave; delete | yes: saved groups show in a compact row at the top of the strip area or the sidebar (setting), persisted in the daemon, restorable into any pane, including terminal tabs (restore reattaches live terminals if still running, else starts new ones in the saved cwd) |
| Group keyboard navigation | yes, plus shortcuts for every group action (Chrome lacks these) |
| Group appears in tab search | yes, palette shows groups and their tabs |

Workspace groups mirror the same verbs in the sidebar (create, rename, color, collapse, pin/favorite, move, ungroup, close).

## 8. What to delete, not port

Everything in the old app that exists to own state the daemon now owns: session snapshot/restore, workspace persistence, bonsplit trees, surface lifecycle registries, port scanning in-app, agent journal projections in-app, per-surface timers. The inventory's DELETE list stands; the new app starts from zero and adds only what this document lists.
