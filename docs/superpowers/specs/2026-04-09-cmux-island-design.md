# cmux Island — MVP design

**Issue:** manaflow-ai/cmux#2590 — Pluggable macOS Dynamic Island Overlay for cmux.
**Date:** 2026-04-09
**Status:** Design approved — pending implementation plan.
**Scope:** MVP only. Explicit non-goals enumerated in §7.

---

## 1. Problem

Users running multiple AI agents inside cmux need a lightweight, persistent surface that tells them *which specific agent session needs attention right now* and lets them jump to the corresponding workspace + terminal split in one click. Today, a user has to scan the sidebar, hunt through splits, and interpret free-form status entries. There is no at-a-glance view across workspaces.

The issue proposes a notch-anchored Dynamic Island style overlay. The MVP in this spec delivers the monitoring and jump half of that vision; approvals and bidirectional hook routing are explicit non-goals, designed to slot in cleanly as Phase 2 without reshaping any MVP code.

## 2. User story (MVP)

> As a cmux user running Claude Code in one workspace, Codex in another, and Copilot CLI in a third, I want a small overlay at the top of my main display that shows me how many agent sessions are active and what state each is in, so I can click the one I care about and jump directly to that terminal split without hunting through the sidebar.

## 3. Goals and non-goals

**Goals (MVP):**

1. Always-on-top, click-to-expand island overlay anchored under the notch on the main display.
2. Zero new user-facing CLI. Light up automatically for anyone whose agents already call `cmux set-status <agent_kind> <phase>` per `docs/notifications.md`.
3. Click a row → cmux comes to the front, the corresponding workspace is selected, the corresponding panel is focused.
4. Opt-in, off by default, enabled through Settings and mirrored in `~/.config/cmux/settings.json`.
5. Module lives in `Sources/Island/` with a narrow, well-defined `IslandStateProvider` seam so a future `cmuxIsland.app` companion target can be extracted mechanically.
6. Covered by unit tests that exercise the projection, sort, and routing logic — no source-shape tests, no plist tests, nothing that CLAUDE.md's test quality policy forbids.

**Non-goals (deliberately deferred):**

1. Pending permission / approval tracking and approve/deny buttons.
2. New `cmux session` CLI or any typed session-lifecycle protocol.
3. Bidirectional or blocking hook RPC where the island answers hook-side permission prompts.
4. A separate Xcode target / companion `.app`. The extraction seam is designed; extraction itself is Phase 3.
5. Multi-display support. MVP is main display only.
6. Mark-read or dismiss-notification action invoked from inside the island.
7. Auto-dismiss of idle rows. Idle sessions remain until their status entry is cleared.
8. Hover-to-expand (click only, simpler, safer under cmux's focus policy).
9. Configurable left/right placement of the collapsed content (hardcoded left; trivial flip later).
10. Sparklines, token counts, chat preview, or any content deeper than `(workspace title, panel title, agentKind, phase, elapsed, unread count)`.
11. Monitoring agent sessions that run **outside** cmux panels. The island is cmux-panel-scoped by definition — that is what makes the jump action meaningful. (Claude Island already covers the non-cmux case.)
12. Auto-installing hooks into `~/.claude/hooks` or similar. Users keep the existing `cmux set-status` integrations documented in `docs/notifications.md`.

## 4. Architecture

### 4.1 Module layout

```
Sources/Island/
├── IslandStateProvider.swift    — protocol; the only interface the view observes
├── IslandStateStore.swift       — concrete provider; projects TabManager → IslandSession list
├── IslandSession.swift          — value type + supporting enums
├── IslandFocusSink.swift        — protocol the router calls to focus workspace/panel
├── IslandJumpRouter.swift       — translates row taps into focus calls
├── IslandWindowController.swift — NSWindowController owning the NotchPanel
├── NotchPanel.swift             — NSPanel subclass
├── NotchShape.swift             — SwiftUI Shape (port from claude-island)
└── IslandRootView.swift         — SwiftUI view for closed/expanded states
```

### 4.2 Decoupling seam

The SwiftUI view layer (`IslandRootView`, debug windows) depends **only** on `IslandStateProvider`. `IslandStateStore` is the concrete production implementation, which reads `TabManager` / `Workspace` / `TerminalNotificationStore`. Tests use `InMemoryIslandStateProvider`. A Phase 3 `SocketIslandStateProvider` that consumes a new `island.subscribe` socket command would be a drop-in replacement — **no view code changes**.

Write-back from the island is equally confined. `IslandJumpRouter` calls methods on `IslandFocusSink`. The production implementation wraps `TabManager` / `NSWindow`; tests use a spy.

No other cmux source file imports the Island module. Removing `Sources/Island/` removes the feature entirely with no leftover references.

### 4.3 Data flow (read-only projection)

```
Workspace.statusEntries  ─┐
TerminalNotificationStore ─┼─► IslandStateStore ─► @Published sessions ─► IslandRootView
Workspace.panels/titles  ─┘        (Combine,
                                   debounced
                                   0.05s)
```

Debounce avoids flapping when multiple status entries update in the same runloop turn (e.g. an agent hook that fires `set-status` and `notify` back to back).

### 4.4 Integration with AppDelegate

`AppDelegate` observes `@AppStorage("island.enabled")`:

- `enabled = true`, controller is `nil` → instantiate `IslandWindowController`, attach its `IslandStateStore` to the shared `TabManager`, `orderFront` only when `sessions` is non-empty.
- `enabled = false`, controller is non-`nil` → call `close()`, release the `NSPanel`, cancel all Combine subscriptions. After disabling, the process must hold zero Island-owned timers, observers, or windows.

Rapidly toggling the Setting must never produce a stuck panel or orphaned observer (covered by the debug menu's rapid toggle path during PR review).

## 5. Data model

### 5.1 Types

```swift
/// Known agent kinds the island monitors. A panel is an island session iff its
/// Workspace.statusEntries contains at least one entry whose key equals one of these.
enum IslandAgentKind: String, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude_code"
    case codex      = "codex"
    case copilotCli = "copilot_cli"
    case openCode   = "opencode"
    case geminiCli  = "gemini_cli"
    case cursor     = "cursor"
    case amp        = "amp"
    case droid      = "droid"

    var displayName: String { … }   // "Claude Code", "Codex", …
    var color: NSColor      { … }   // stable brand color per kind
    var monogram: String    { … }   // single character for the 20pt chip
}

/// Normalized session phase. Derived from SidebarStatusEntry.value via a
/// case-insensitive lookup table. Unknown values fall into .unknown.
enum IslandSessionPhase: String, Hashable, Sendable {
    case running
    case idle
    case waiting
    case error
    case unknown

    static func from(rawValue: String) -> IslandSessionPhase
}

/// One row in the island. Immutable value; regenerated on every store tick.
struct IslandSession: Identifiable, Equatable, Sendable {
    let id: UUID                // stable: panelId
    let workspaceId: UUID
    let panelId: UUID
    let agentKind: IslandAgentKind
    let phase: IslandSessionPhase
    let workspaceTitle: String
    let panelTitle: String
    let lastActivity: Date      // from SidebarStatusEntry.timestamp
    let unreadCount: Int        // from TerminalNotificationStore filtered by panelId
    let rawStatusValue: String  // kept for tooltip + debug window
}

protocol IslandStateProvider: AnyObject {
    var sessions: AnyPublisher<[IslandSession], Never> { get }
}
```

### 5.2 Projection rules

Given a `Workspace`, for each `panelId` referenced in `workspace.panels`:

1. Collect all `statusEntries[key]` where `key ∈ IslandAgentKind.allCases.map(\.rawValue)`.
2. If the collection is empty, the panel contributes no session.
3. Otherwise pick the highest-priority entry (highest numeric `SidebarStatusEntry.priority` first, ties broken by most recent `timestamp`). In MVP, two concurrent agents in the same panel are not supported — the winner defines the session.
4. Map `entry.value` → `IslandSessionPhase.from(rawValue:)`.
5. Populate `workspaceTitle` from `workspace.customTitle ?? workspace.title`, `panelTitle` from `workspace.panelCustomTitles[panelId] ?? workspace.panelTitles[panelId]` with fallback to the panel's `displayTitle`.
6. Populate `unreadCount` from `TerminalNotificationStore` filtered by `panelId`.
7. Populate `lastActivity` from `entry.timestamp`.

Across all workspaces, flatten and sort:

```
sortKey(session) = (phaseRank, -lastActivity.timeIntervalSince1970)
phaseRank: running=0, waiting=1, error=2, idle=3, unknown=4
```

### 5.3 Phase normalization table

`IslandSessionPhase.from(rawValue:)` is a single static dictionary, case-insensitive, trimmed:

| Raw value (case-insensitive)                               | Normalized phase |
|-------------------------------------------------------------|------------------|
| `running`, `running_tool`, `processing`, `starting`         | `.running`       |
| `idle`, `` (empty), `ready`                                 | `.idle`          |
| `waiting`, `waiting_for_input`, `needs_input`, `needsinput` | `.waiting`       |
| `error`, `failed`, `failure`                                | `.error`         |
| (anything else)                                             | `.unknown`       |

Adding a new synonym is a one-line change in the dictionary; no UI code changes.

### 5.4 Visibility predicate

```
visible = !sessions.isEmpty
```

No "always visible" mode. No auto-hide delay for idle rows. If an agent hook crashes and leaves a stale entry behind, the row will stay on the island until the user runs `cmux clear-status <agent_kind>`. Acceptable for MVP; revisit in Phase 2.

### 5.5 Aggregate indicator color

The collapsed pill shows a single dot. Its color is the highest-severity phase currently present:

| Any session phase is… | Dot color |
|------------------------|-----------|
| `.running`             | green     |
| `.waiting`             | yellow    |
| `.error`               | red       |
| only `.idle` or `.unknown` | gray  |

## 6. UI

### 6.1 Window: `NotchPanel`

`NSPanel` subclass, ported from `farouqaldori/claude-island`. Configuration:

```swift
styleMask                = [.borderless, .nonactivatingPanel]
isFloatingPanel          = true
becomesKeyOnlyIfNeeded   = true
isOpaque                 = false
backgroundColor          = .clear
hasShadow                = false
isMovable                = false
collectionBehavior       = [.fullScreenAuxiliary, .stationary,
                            .canJoinAllSpaces, .ignoresCycle]
level                    = .mainMenu + 3
```

Positioned with `frame.origin.x = screen.frame.origin.x`, `frame.size.width = screen.frame.width`, `frame.size.height = 750`, `frame.origin.y = screen.frame.maxY - 750`. Only the inner `NotchShape` is painted; the rest of the panel is transparent.

`ignoresMouseEvents` is toggled based on open/closed status so that, when collapsed, clicks outside the hit region pass through to the menu bar and apps underneath.

Target screen is `NSScreen.screens.first(where: { $0.hasPhysicalNotch }) ?? NSScreen.main`.

### 6.2 Shape: `NotchShape`

Direct port of claude-island's `NotchShape.swift`. Single contiguous path with:

- Inward-curving quadratic top-left and top-right corners (`topCornerRadius`) — these disappear into the screen bezel on notch Macs, and read as rounded corners on non-notch Macs.
- Outward-curving quadratic bottom-left and bottom-right corners (`bottomCornerRadius`) — these form the visible "bottom" of the notch extension.

`animatableData` is an `AnimatablePair` of the two radii so the shape can interpolate during open/close.

Let `ext = max(28pt, leftContentWidth)`. The shape is always horizontally symmetric around the notch: `shapeWidth = notchWidth + 2 × ext`. The right side gets the same `ext` width as the left, empty.

| State  | Width                          | Height                      | Top radius | Bottom radius |
|--------|--------------------------------|------------------------------|------------|---------------|
| Closed | `notchWidth + 2 × ext`         | `notchHeight` (≈ 32pt)       | 6          | 14            |
| Opened | `560pt`                        | `64 + rowCount × 56`, cap 540| 19         | 24            |

Animations:

- Open: `spring(response: 0.42, dampingFraction: 0.8)`
- Close: `spring(response: 0.45, dampingFraction: 1.0)`
- Closed-state dot/count/color changes: `.smooth`

### 6.3 Closed layout

```
[ ● 3 ] [     NOTCH     ] [       ]
  ^^^                      ^^^^^^^^
  left extension           right mirror (empty, same width, symmetry only)
```

- Dot: 6pt filled circle, color per §5.5, optional 6pt soft glow.
- Count: `sessions.count`, SF Pro 11pt semibold, tabular numerals.
- Left content (dot + count) measured, padded to at least 28pt. Right mirror copies the same `ext` width per §6.2 so the shape stays symmetric around the notch.
- **Hit region is the left extension only.** The right mirror is dead space. The physical notch area is never drawn or hit-tested.

Click → `viewModel.open(reason: .click)` → expand.

### 6.4 Opened layout

```
┌────────────────────────────────────────┐
│  cmux Island                     [·]   │
├────────────────────────────────────────┤
│  [C] cmux · fix-zsh-autosuggestions    │
│      Claude Code · 4m      ┃ RUNNING   │
│  [X] web · issue-2674-scrollbar        │
│      Codex · 12m           ┃ IDLE      │
│  [G] daemon · main                     │
│      Copilot CLI · 1m      ┃ ERROR     │
└────────────────────────────────────────┘
```

- Header: 22pt strip with localized title `island.header.title` ("cmux Island"). No close button; click-outside handles it.
- Row: 56pt tall, 8pt vertical spacing, 12pt internal padding.
- Leading chip: 20pt rounded square, `IslandAgentKind.color`, monogram in white bold.
- Line 1: `workspaceTitle · panelTitle`, head-tail truncated if wider than the row content area.
- Line 2: `agentKind.displayName · <elapsed>` in 11pt secondary text. Elapsed is derived from `lastActivity` and re-computed once per second while expanded, never while collapsed.
- Trailing: phase pill (`RUNNING` / `IDLE` / `WAITING` / `ERROR` / `UNKNOWN`) with a phase-specific background + foreground color, plus a `· N` unread badge when `unreadCount > 0`.
- Max visible rows without scrolling: 8. 9+ enables a vertical scroller inside the expanded panel; shape height caps at 540pt.

### 6.5 Interactions

| Trigger                                    | Effect                                                          |
|--------------------------------------------|-----------------------------------------------------------------|
| Click collapsed pill                       | Expand (spring animation)                                       |
| Click row                                  | `IslandJumpRouter.jump(to: session)`, then collapse             |
| Click outside expanded panel               | Collapse                                                        |
| Press `Esc` while opened                   | Collapse                                                        |
| Session list changes while collapsed       | Pill updates in place (count + dot color); no auto-expand       |
| Session list becomes empty                 | `window.orderOut(nil)` and stop redraw timers                   |
| Session list becomes non-empty from empty  | `window.orderFront(nil)`, start in closed state                 |

No hover-to-expand in MVP.

### 6.6 Jump routing

`IslandJumpRouter.jump(to: session)` performs the following, in order, against `IslandFocusSink`:

1. `selectWorkspace(session.workspaceId)` — probe first. Routes through the same code path that the existing `workspace.select` socket command uses. Returns false if the workspace has been torn down since the session was projected.
2. **If the probe returned false:** log `dlog("island.jump failed: workspace … not found")` in DEBUG builds and jump straight to step 5. The app is **not** activated. This preserves the user's current focus context when the click would otherwise land on a stale row.
3. `activateApp()` — only reached on the happy path where the workspace still exists. This is the single place in the island code that is allowed to activate cmux. The call is an explicit user focus intent (the row click), which satisfies the focus-intent exception in cmux's socket focus policy (CLAUDE.md §"Socket focus policy"). No other island code path activates the app.
4. `focusPanel(session.panelId, inWorkspace: session.workspaceId)` — routes through the same code path that the existing `pane.focus` / `surface.focus` socket commands use. If it returns false (panel gone but workspace still present), log `dlog("island.jump failed: panel … not found …")` in DEBUG builds and continue.
5. `collapseIsland()` — always, exactly once, regardless of which step (if any) failed. No error UI in MVP.

**Sequence note:** earlier drafts of this spec ordered `activate` before `select`. That order was abandoned because it would steal macOS focus for a workspace that might already be gone. The current order — select first, activate only on success — satisfies the same user-intent exception while preserving focus on the miss path.

### 6.7 Non-notch Mac behavior

- `viewModel.hasPhysicalNotch` is used only to drive the initial fade-in opacity.
- The same `NotchShape` is drawn. With no physical cutout between the inward top corners, it reads as a floating dark pill centered at the top of the screen.
- All other behavior (projection, visibility, expand, collapse, routing) is identical.

## 7. Configuration and opt-in

### 7.1 Source of truth

`@AppStorage("island.enabled")` is the single source of truth.

Mirrored in `~/.config/cmux/settings.json`:

```json
{
  "island": {
    "enabled": false
  }
}
```

`CmuxConfig.swift` gains an `IslandConfigSection` with one boolean. The existing `CmuxConfigExecutor` pipeline handles reload-on-change so that editing the file is equivalent to flipping the Settings toggle. Default value is `false`.

### 7.2 Settings UI

A new sidebar entry **"Island"** is added to the Settings window, positioned after "Notifications". Contents:

- Single toggle: **"Show agent session island overlay"** (key `island.settings.enable.label`).
- Descriptive help text under the toggle explaining what it does, when it appears, and which known-agent keys it looks at — localized strings only.

All strings live in `Resources/Localizable.xcstrings` with English + Japanese per CLAUDE.md. Keys:

- `island.settings.title`
- `island.settings.enable.label`
- `island.settings.enable.help`
- `island.settings.known_kinds.help`
- `island.header.title`
- `island.phase.running`, `island.phase.idle`, `island.phase.waiting`, `island.phase.error`, `island.phase.unknown`
- `island.tooltip.raw_status` (debug-window row tooltip, DEBUG only)

### 7.3 Debug UI (DEBUG builds only)

Under `Debug > Debug Windows`, add an alphabetically-ordered entry **"Island Controller"** that opens a singleton `NSWindowController` containing:

- An "Enable island" toggle bound to the same `island.enabled` key (not a separate preference).
- A live table of the current `IslandSession` rows showing `workspaceId`, `panelId`, `agentKind`, `phase`, `rawStatusValue`, `unreadCount`, `lastActivity`.
- An "Inject test session" button that pushes a synthetic `IslandSession` through the store for visual iteration without needing a real agent running.

Per CLAUDE.md this is wrapped in `#if DEBUG` / `#endif`.

### 7.4 Discoverability

No first-run prompt, no in-app tip, no notification. Release notes and `CHANGELOG.md` announce the feature and instruct users to toggle it on.

## 8. Testing

Per CLAUDE.md "Test quality policy", tests exercise observable runtime behavior. Per "Testing policy", tests run in CI (`cmux-unit` scheme / `test-e2e.yml`), never locally.

### 8.1 Unit tests (`cmuxTests/Island/`)

1. **`IslandSessionPhaseTests`** — pure function tests over `IslandSessionPhase.from(rawValue:)`. Every synonym in §5.3 maps to the expected phase; unknown strings map to `.unknown`. Table-driven.

2. **`IslandStateStoreProjectionTests`** — store constructed with a fake `IslandStateSource` (a protocol wrapping the minimum `TabManager` surface the store reads). Assertions:
   - Workspace with no known-kind entries → zero sessions.
   - Workspace with `statusEntries["claude_code"] = Running` → exactly one session with the right fields.
   - Two known-kind entries on the same panel → highest-priority wins per §5.2.
   - `unreadCount` is read from the notification source, never guessed.
   - Clearing a status entry removes the corresponding session in the next emission.
   - Updating `panelTitle` rewrites the emitted session without changing `id`.

3. **`IslandSessionSortTests`** — ordering predicate. Asserts running → waiting → error → idle → unknown, tiebreak by `lastActivity` descending.

4. **`IslandVisibilityTests`** — given a `sessions: [IslandSession]` publisher stream, asserts the downstream `visible: Bool` stream matches §5.4.

5. **`IslandJumpRouterTests`** — router depends only on `IslandFocusSink`. Spy implementation records calls. Test verifies `jump(to: session)` produces the sequence `activate → selectWorkspace(id) → focusPanel(id) → collapse`. A test for the "workspace deleted" edge case verifies the router collapses without calling `activate`.

6. **`IslandConfigRoundTripTests`** — `island.enabled` written via `@AppStorage` round-trips through `CmuxConfig` → `settings.json` → `CmuxConfig`, so editing the file is equivalent to the Settings toggle.

### 8.2 Non-goals for automated tests

- Snapshot tests of `NotchShape`. Per CLAUDE.md these would be source-shape tests. Instead, the debug-window "Inject test session" path lets a reviewer verify the shape interactively during PR review.
- NSPanel lifecycle on full screen / space switches / multi-display. Too environment-dependent for unit tests. Covered by a manual PR smoke-test checklist (see §9).
- `IslandJumpRouter`'s downstream effect on `TabManager` — the existing `workspace.select` / `pane.focus` tests already exercise that code path; we don't duplicate.

### 8.3 Regression test commit policy

Per CLAUDE.md, bugs discovered during implementation that warrant a regression test follow the two-commit pattern: failing test first, fix second.

## 9. Manual PR smoke test checklist

The reviewer runs the following against a tagged `reload.sh --tag island-mvp` build:

1. Settings → Island → toggle on; no sessions yet → island should **not** appear.
2. In a cmux terminal, run `cmux set-status claude_code Running` → pill appears with green dot, count `1`.
3. Click the pill → expands; row shows the current workspace + panel, phase RUNNING, elapsed 0m counting up.
4. Click outside the panel → collapses.
5. In a second workspace, `cmux set-status codex Idle` → collapsed pill still visible, count `2`, dot still green (because Claude Code is still running).
6. `cmux set-status claude_code Error` → dot turns red.
7. Click the pill → expand → click the Claude Code row → cmux comes to front, the Claude Code workspace is selected, the panel is focused.
8. `cmux clear-status claude_code` on the first workspace → row disappears; count drops to `1`.
9. `cmux clear-status codex` on the second → row disappears; island orderOut's with no artifacts.
10. Switch to another Space, then to a full-screen app → island follows (`.canJoinAllSpaces`, `.fullScreenAuxiliary`).
11. Rapidly toggle Settings → Island off/on 10 times → no leftover panel, no orphaned observers (verified via Debug > Debug Windows > Island Controller live row count resetting correctly).
12. On a non-notch Mac: island renders as a floating pill at top-center; all other behavior identical.

## 10. Phase 2+ extension points (not built in this PR)

| Extension                                       | How the MVP enables it                                                                                                                                                                                                                                                            |
|-------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Pending permission approvals                    | Add an `IslandPendingApproval` case the store projects alongside sessions. Row template gains approve/deny buttons. New `cmux approve`/`cmux deny` CLI or blocking socket RPC. No existing MVP code changes — the row model is additive.                                         |
| Extraction to `cmuxIsland.app`                  | Swap `IslandStateStore` for a `SocketIslandStateProvider` that subscribes to a new `island.subscribe` socket command streaming `IslandSession` JSON. The SwiftUI layer already only depends on `IslandStateProvider`.                                                             |
| Multi-display                                   | Promote the singleton `IslandWindowController` to a `[CGDirectDisplayID: IslandWindowController]` dictionary, plus a Settings dropdown to pick which displays get an island.                                                                                                      |
| Explicit session CLI (`cmux session start`)     | Adds a third source to `IslandStateStore` alongside `statusEntries` and `notifications`. No UI changes.                                                                                                                                                                           |
| Mark-read from island                           | Add `IslandActionSink` next to `IslandFocusSink`; route clicks on the unread badge to `TerminalNotificationStore.markRead(panelId:)`.                                                                                                                                             |
| Hover-to-expand                                 | One-line addition in `IslandRootView` (`.onHover { … }`).                                                                                                                                                                                                                         |
| Auto-dismiss idle rows after N minutes          | Add an optional `idleTTL: TimeInterval` to `IslandStateStore` and drop expired rows during projection. Off by default.                                                                                                                                                            |

## 11. References

- **Issue:** manaflow-ai/cmux#2590.
- **Claude Island** (code reference, Apache 2.0): https://github.com/farouqaldori/claude-island. Port `NotchPanel`, `NotchShape`, and the `NSPanel` configuration directly; do **not** port `ClaudeSessionMonitor`, `HookSocketServer`, or `HookInstaller` — those implement a hook-driven session model that is out of scope for cmux Island MVP.
- **Vibe Island** (UX reference, closed source): https://vibeisland.app. Referenced only for interaction model (click row → jump) and the four-verbs framing (Monitor / Approve / Ask / Jump — MVP covers Monitor + Jump only).
- **cmux notifications / set-status convention:** `docs/notifications.md`.
- **cmux focus policy:** `CLAUDE.md` §"Socket focus policy".
- **cmux test quality policy:** `CLAUDE.md` §"Test quality policy" and §"Testing policy".
- **cmux localization requirement:** `CLAUDE.md` §"Pitfalls" — user-facing strings via `Resources/Localizable.xcstrings`.
- **cmux debug menu convention:** `CLAUDE.md` §"Debug menu".
