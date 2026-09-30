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

## 5a. Concurrency: no hangs, no UI lag (user requirement 2026-09-29)

The old app hangs and lags under CLI load. The new app must never block the main thread, and heavy CLI traffic must not drop frames.

Rules (enforced by `scripts/cmux-next/check-concurrency.sh` in the merge gate, plus review):
- The main thread never waits. Banned in CmuxNext sources: `DispatchQueue.main.sync`, `DispatchSemaphore.wait`/`DispatchGroup.wait`, `Thread.sleep`, `usleep`, blocking `FileHandle`/`read`/`write`/`connect` on the main actor, `Process.waitUntilExit` on main, `NSLock`/`os_unfair_lock` held across an `await` or across IO, synchronous XPC. Exceptions need an inline `// concurrency-allow: <reason>` reviewed comment.
- Every cross-process call is async with a deadline: daemon requests, socket replies, git, shell env capture. A deadline miss is a typed error, never a hang. Default 2 s for control-plane requests, no deadline for streaming attach.
- Read-only CLI queries (`identify`, `list-*`, `tree`, `action.list`, `read-screen`, status) are answered off the main actor from an immutable `ControlSnapshot` that the main actor publishes after each model settle (copy-on-write value types, published via an atomic reference). They never touch `@MainActor` state.
- Mutating CLI requests go through one bounded `MainActorWorkQueue`: FIFO per client connection, global cap (e.g. 1024 pending; beyond that the request fails fast with `busy`). The queue drains at most ~4 ms of work per display frame, then yields to the run loop, so input and rendering always get the frame. Bursts are coalesced where the daemon supports batching.
- The daemon is the serialization point for layout mutations. The app sends commands and applies optimistic patches; it never waits for a reply on the main actor.
- The control socket server runs on its own queue/actors: accept, read, parse, and write off main. A slow or stuck CLI client can only block its own connection (per-connection write buffer cap, then disconnect).
- No unbounded buffers anywhere (terminal output, socket queues, event streams): each has a cap and an overflow policy (drop-oldest for telemetry, disconnect/reattach for streams, `busy` for commands).
- Hang instrumentation: a main-run-loop watchdog (CFRunLoopObserver + background timer thread) records any main-thread stall > 50 ms with a stack sample to a ring buffer, exposed as `debug.hangs` over the socket and logged in debug builds. Dogfood builds report the count.

The one allowed exception: Chromium's own main-thread steps. `CefInitialize` (once per process) and creating a Chromium window (once per pane that shows Chromium tabs; the first one per process is the slowest) must run on the main thread (Chromium's UI thread) and take about 70-160 ms each. Nothing else CEF does may block: the framework `dlopen` runs off the main thread (`CEFRuntime.loadLibrary`). The App keeps `CefInitialize` out of user interaction when it can predict a Chromium tab (`ChromiumWarmup`): it maps the framework a few seconds after launch, and runs `CefInitialize` at the next idle moment (no input to the app for 750 ms, no menu tracking) once a Chromium tab exists in any window or the user opens the "+" engine menu or reaches the palette's Chromium entry. A Chromium tab opened with no such hint (for example straight from the CLI) still starts cold and may show the two stalls. `scripts/cmux-next/check-first-chromium.py` enforces this: `--mode cold` allows at most the two Chromium stalls, `--mode warm` (a Chromium tab was likely) requires `CefInitialize` to have run before and allows only the new window's stall.

Verification (bench harness, section 6): a CLI storm test fires 2,000 mixed CLI requests from 32 concurrent clients (reads, creates, sends, renames, closes) while the app renders and a terminal streams output. Pass criteria: 0 main-thread stalls > 50 ms, p99 frame time < 16.7 ms, every request answered or failed fast (no request waits > deadline), app RSS back within 10% of baseline afterwards.

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
