# Design: "New Local Workspace" in the command palette

**Status:** Design placeholder, adversarially reviewed (follow-up to the *New
Local Workspace* File-menu item). No code yet — this doc is the spec for a
separate implementation PR.

This document specifies adding a **New Local Workspace** entry to the command
palette, gated so it only appears when plain New Workspace in the active window
would spawn a remote tmux session. It is a companion to the menu-item change,
which is the load-bearing piece; this palette entry is pure surface parity and is
split out to keep that change focused.

## Background

In a remote-tmux mirror window, plain **New Workspace** (⌘N / File → New
Workspace) spawns a new tmux session on the window's host and mirrors it in,
rather than creating a local workspace. The menu-item change adds a **New Local
Workspace** command that forces local creation, shown only when New Workspace
would otherwise go remote.

That change already provides the two pieces this work builds on:

- `AppDelegate.performNewLocalWorkspaceAction(tabManager:event:debugSource:)` —
  the shared action; routes through `performNewWorkspaceCreationAction(..., forceLocal: true)`.
- `RemoteTmuxController.wouldNewWorkspaceSpawnRemote(windowId:)` — the
  non-mutating decision ("would New Workspace in this window route remote?"),
  already the single source of truth behind the menu item's visibility and the
  ⌘N routing handler.

The command palette is the other primary way users create workspaces
(`palette.newWorkspace`, `palette.newBrowserWorkspace`), so New Local Workspace
should be reachable there too.

## Goal

Add `palette.newLocalWorkspace`, visible **only** when
`wouldNewWorkspaceSpawnRemote(windowId:)` is true for the palette's window, and
executing the same `performNewLocalWorkspaceAction`. No new keyboard shortcut.

## Design

The palette wires a command through: a **context key** (per-window boolean), a
**snapshot population** that sets it, a **contribution** (title/subtitle/keywords
+ a `when:` visibility gate), and a **handler** (the action to run). Command IDs
are plain strings — there is no central registry enum — so the load-bearing pair
is *contribution + handler*. A contribution without a matching handler is
asserted-then-dropped by the app-side resolution loop
`ContentView.commandPaletteCommands(...)` (`assertionFailure` in Debug, silently
`continue`d in Release) — it is that loop, not the handler registry type, that
enforces the pairing.

### 1. Context key

`Packages/macOS/CmuxCommandPalette/Sources/CmuxCommandPalette/Context/CommandPaletteContextKeys.swift`
— add alongside the other boolean keys (e.g. after `authWorking`):

```swift
/// Whether a plain New Workspace in this window would spawn a remote tmux session.
public static let newWorkspaceRoutesRemote = CommandPaletteContextKeys(rawValue: "newWorkspace.routesRemote")
```

`CommandPaletteContextKeys` is a plain `Hashable, Sendable` wrapper over a
`rawValue: String`; it is not `CaseIterable` and nothing enumerates every key, so
this is the only declaration needed.

### 2. Populate the context snapshot

`Sources/ContentView.swift`, in `commandPaletteContextSnapshot(terminalOpenTargets:)`
— add at the top level (always emitted, next to the `browserDisabled` `setBool`).
`ContentView` has a stored `let windowId: UUID`, so it reuses the exact same
source of truth the menu item uses:

```swift
if let remoteTmux = AppDelegate.shared?.remoteTmuxController {
    snapshot.setBool(
        CommandPaletteContextKeys.newWorkspaceRoutesRemote,
        remoteTmux.wouldNewWorkspaceSpawnRemote(windowId: windowId)
    )
}
```

`remoteTmuxController` is a non-optional `let`, so the `if let` only guards
`AppDelegate.shared == nil`; when it is nil (or the beta flag is off, so no
window has a host and `wouldNewWorkspaceSpawnRemote` returns false) the key is
never set and `snapshot.bool(...)` defaults to false — the command hides. That is
the intended fail-safe and matches how the `authSignedIn` key is set
conditionally.

The snapshot is rebuilt fresh whenever palette results recompute, and the value
feeds the results fingerprint, so the gate is correct every time the palette
opens. **Reactivity caveat (see Consistency below):** the menu item re-evaluates
its visibility on every focus/selection change (it reads
`focusHistoryMenuInvalidator.revision`); the palette has no equivalent hook, so a
tab/window switch *while the palette stays open* is not guaranteed to re-derive
the gate. To keep the two surfaces in lockstep even in that case, add an
invalidation hook mirroring `refreshCachedDefaultTerminalStatus` — clear
`cachedCommandPaletteFingerprint`, and if presented call
`scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true, ...)` — on
the same signals the menu invalidator listens to
(`.tabManagerFocusHistoryRevisionDidChange` and `NSWindow.didBecomeKeyNotification`).

### 3. Contribution (with visibility gate)

`Sources/ContentView.swift`, in the contributions builder — add after the
`palette.newBrowserWorkspace` contribution:

```swift
contributions.append(
    CommandPaletteCommandContribution(
        commandId: "palette.newLocalWorkspace",
        title: constant(String(localized: "command.newLocalWorkspace.title", defaultValue: "New Local Workspace")),
        subtitle: constant(String(localized: "command.newLocalWorkspace.subtitle", defaultValue: "Workspace")),
        keywords: ["create", "new", "local", "workspace"],
        when: { $0.bool(CommandPaletteContextKeys.newWorkspaceRoutesRemote) }
    )
)
```

`CommandPaletteCommandContribution` supports both `when:` (visibility) and
`enablement:` (grey-out). Use `when:` — the item should be **hidden**, not
disabled, when it doesn't apply, matching the menu item (which is conditionally
shown) and sibling contextual commands like `palette.installCLI`.

**Testability seam.** The New Workspace / New Browser Workspace contributions are
appended inline inside the *private instance* method
`commandPaletteCommandContributions()`, which no unit test can invoke. To make
the gate unit-testable (see Testing), expose the new contribution through a
`static` factory the way `commandPaletteAuthCommandContributions()` and
`commandPaletteRightSidebarModeCommandContributions()` already do — e.g. a small
`static func commandPaletteNewLocalWorkspaceCommandContribution()` that the
instance builder appends — so a test can construct it, run its `when:` against a
hand-built snapshot, and assert presence/absence.

### 4. Handler

`Sources/ContentView.swift`, in `registerCommandPaletteHandlers(...)` — add after
the `palette.newWorkspace` handler, passing the palette view's own `tabManager`
so the local workspace lands in the palette's window (mirrors `newWorkspace`):

```swift
registry.register(commandId: "palette.newLocalWorkspace") {
    AppDelegate.shared?.performNewLocalWorkspaceAction(
        tabManager: tabManager,
        debugSource: "palette.newLocalWorkspace"
    )
}
```

Synchronous, like `newWorkspace` (the `newBrowserWorkspace` handler only wraps in
`DispatchQueue.main.async` because it focuses the omnibar afterward).

### 5. Right-sidebar shortcut-hint switch — no change

`Sources/ContentView+RightSidebarCommandPalette.swift`'s
`commandPaletteShortcutAction(forCommandID:)` maps a command ID to a bindable
`KeyboardShortcutSettings.Action` purely to render a shortcut glyph on the row.
It has a total `default: return nil`, so omitting a case yields "no glyph" — the
correct behavior, since New Local Workspace has no bound shortcut. **Do not** add
a case here unless a bindable `.newLocalWorkspace` action is introduced (which
would pull in the full shortcut policy: enum case, Settings visibility,
`cmux.json` support, and docs).

### 6. Localization

`Resources/Localizable.xcstrings` — add `command.newLocalWorkspace.title` and
`command.newLocalWorkspace.subtitle` across all locales the sibling
`command.newWorkspace.*` keys carry (currently 19). Reuse the existing
`menu.file.newLocalWorkspace` translations verbatim for the title and the
existing `command.newWorkspace.subtitle` ("Workspace") translations verbatim for
the subtitle, so the palette and menu strings stay identical per locale.

## Consistency

Visibility and behavior both derive from the same primitives as the menu item:
`wouldNewWorkspaceSpawnRemote(windowId:)` for the gate and
`performNewLocalWorkspaceAction` for the action — one decision, one action. On
every palette open the gate re-derives the current window's state, so it agrees
with the menu item at open time. The one way they can diverge is timing: the menu
re-evaluates on every focus/selection change, the palette only on results
recompute. Adding the invalidation hook above closes that gap; without it, the
palette gate is still correct per-open, just not live while the palette stays
open across a tab/window switch.

Note the gate's `hasManager == false` branch (a window with a host but no
resolvable tab manager, mid-teardown) returns true, so the command could show
while the action — which always forces local — creates a local workspace. This is
benign (New Local Workspace's whole job is to create local) and vanishingly rare
(the palette is hosted by the same view that owns the tab manager), but it means
the gate is "would New Workspace route remote" in the normal case, not a
hard guarantee in that teardown sliver.

## Testing

- **Gate test (the important one), auth-command style — not search-engine style.**
  The search-engine suites (`CommandPaletteSearchEngineTests`) only feed hand-built
  fixture corpora into the fuzzy matcher; they never build a
  `CommandPaletteContextSnapshot` or evaluate a contribution's `when:`, so they
  cannot prove "shown when true / hidden when false." The gate lives in
  `ContentView.commandPaletteCommands` via `contribution.when(context)`. Test it the
  way `CommandPaletteAuthCommandTests` does: build a `CommandPaletteContextSnapshot`,
  `setBool(CommandPaletteContextKeys.newWorkspaceRoutesRemote, true/false/unset)`,
  take the contribution from the static factory above, and assert `when(snapshot)` is
  true / false / false respectively. This is why the contribution must be reachable
  from a static seam.
- **Where the test goes.** The gate/snapshot wiring lives in the app target, so the
  behavior-level test belongs in the `cmuxTests` XCTest suite (which can
  `@testable import cmux_DEV`), not the `CmuxCommandPalette` package Tests suite
  (which can only reach pure search ranking). Note the command-palette search tests
  are duplicated across both locations; if a ranking fixture is ever added, update
  both to avoid drift.
- **Wiring.** Prefer appending to an already-wired suite
  (`cmuxTests/ShortcutAndCommandPaletteTests.swift` already exercises these context
  keys). If a new test file is added instead, wire it into
  `cmux.xcodeproj/project.pbxproj` and run `scripts/lint-pbxproj-test-wiring.sh`,
  or Xcode silently ignores it ("Executed 0 tests").
- The remote-vs-local decision itself is already covered by
  `RemoteTmuxNewWorkspaceRoutingTests` (from the menu-item change); no duplication
  needed.

## Out of scope

- A bindable keyboard shortcut for New Local Workspace (would trigger the shortcut
  policy end-to-end).
- Any change to how New Workspace / ⌘N routes; this only adds a palette surface for
  the already-defined local action.
