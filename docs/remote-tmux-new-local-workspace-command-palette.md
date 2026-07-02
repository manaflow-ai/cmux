# Design: "New Local Workspace" in the command palette

**Status:** Design placeholder, adversarially reviewed (follow-up to the *New
Local Workspace* File-menu item). No code yet — this doc is the spec for a
separate implementation PR.

This document specifies adding a **New Local Workspace** entry to the command
palette, gated so it only appears when plain New Workspace on the active
workspace would spawn a remote tmux session. It is a companion to the menu-item change,
which is the load-bearing piece; this palette entry is pure surface parity and is
split out to keep that change focused.

## Background

In a remote-tmux mirror window, plain **New Workspace** (⌘N / File → New
Workspace) spawns a new tmux session on the active workspace's host and
mirrors it in,
rather than creating a local workspace. The menu-item change adds a **New Local
Workspace** command that forces local creation, shown only when New Workspace
would otherwise go remote.

That change already provides the two pieces this work builds on:

- `AppDelegate.performNewLocalWorkspaceAction(tabManager:event:debugSource:)` —
  the shared action; routes through `performNewWorkspaceCreationAction(..., forceLocal: true)`.
- `RemoteTmuxController.wouldNewWorkspaceSpawnRemote(in:)` — the non-mutating
  decision ("would New Workspace in this tab manager route remote?", i.e. is its
  active workspace a live mirror), already the single source of truth behind the
  menu item's visibility and the ⌘N routing handler.

The command palette is the other primary way users create workspaces
(`palette.newWorkspace`, `palette.newBrowserWorkspace`), so New Local Workspace
should be reachable there too.

## Goal

Add `palette.newLocalWorkspace`, visible **only** when
`wouldNewWorkspaceSpawnRemote(in:)` is true for the palette window's tab
manager, and
executing the same `performNewLocalWorkspaceAction`. The command already has a
keyboard shortcut (⌃⌘N, added with the menu item), so the palette row should
surface that glyph — see §5.

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
/// Whether a plain New Workspace on this window's active workspace would spawn a remote tmux session.
public static let newWorkspaceRoutesRemote = CommandPaletteContextKeys(rawValue: "newWorkspace.routesRemote")
```

`CommandPaletteContextKeys` is a plain `Hashable, Sendable` wrapper over a
`rawValue: String`; it is not `CaseIterable` and nothing enumerates every key, so
this is the only declaration needed.

### 2. Populate the context snapshot

`Sources/ContentView.swift`, in `commandPaletteContextSnapshot(terminalOpenTargets:)`
— add at the top level (always emitted, next to the `browserDisabled` `setBool`).
Use the view's own captured `tabManager` — the same object the handler targets —
NOT a re-resolution through `tabManagerFor(windowId:)`, which can answer from a
recoverable (closed-window) route during teardown and let visibility and the
handler disagree about the target:

```swift
if let appDelegate = AppDelegate.shared {
    snapshot.setBool(
        CommandPaletteContextKeys.newWorkspaceRoutesRemote,
        appDelegate.remoteTmuxController.wouldNewWorkspaceSpawnRemote(in: tabManager)
    )
}
```

When `AppDelegate.shared` is nil or no workspace in this manager mirrors a
remote session (e.g. the beta flag is off), the key is never set or set false,
and `snapshot.bool(...)` defaults to false — the command hides. That is the
intended fail-safe and matches how the `authSignedIn` key is set conditionally.

The snapshot is rebuilt fresh whenever palette results recompute, and the value
feeds the results fingerprint, so the gate is correct every time the palette
opens, and a selection change while the palette is open already lands through
the existing fingerprint-recompute path. The one gap is a change to the MIRROR
SET itself with the selection unchanged (attach, or a detach that keeps the
workspace open locally): nothing recomputes the snapshot. Close it narrowly —
publish a mirror-routing revision from `RemoteTmuxController` when
`sessionMirrors` changes and observe it where the palette schedules refreshes —
rather than re-listening to the menu invalidator's focus/key signals, which the
fingerprint path already covers.

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
`enablement:` (a failed `enablement` currently filters the row out of results as
well). Use `when:` — the item should be **hidden**, not present-but-inert, when
it doesn't apply, matching the menu item (which is conditionally shown) and
sibling contextual commands like `palette.installCLI`.

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

### 5. Right-sidebar shortcut-hint switch — add the case

`Sources/ContentView+RightSidebarCommandPalette.swift`'s
`commandPaletteShortcutAction(forCommandID:)` maps a command ID to a
`KeyboardShortcutSettings.Action` purely to render a shortcut glyph on the row.
The menu-item change added a bindable `.newLocalWorkspace` action (default ⌃⌘N),
so add the matching case here (mirroring `palette.newWorkspace`) so the palette
row shows ⌃⌘N:

```swift
case "palette.newLocalWorkspace":
    return .newLocalWorkspace
```

The switch has a total `default: return nil`; without this case the command still
appears and runs, it just wouldn't show its shortcut glyph. Since the action now
exists, add the case.

### 6. Localization

`Resources/Localizable.xcstrings` — add `command.newLocalWorkspace.title` and
`command.newLocalWorkspace.subtitle` across all locales the sibling
`command.newWorkspace.*` keys carry (currently 19). Reuse the existing
`menu.file.newLocalWorkspace` translations verbatim for the title and the
existing `command.newWorkspace.subtitle` ("Workspace") translations verbatim for
the subtitle, so the palette and menu strings stay identical per locale.

## Consistency

Visibility and behavior both derive from the same primitives as the menu item:
`wouldNewWorkspaceSpawnRemote(in:)` for the gate and
`performNewLocalWorkspaceAction` for the action — one decision, one action. On
every palette open the gate re-derives the active workspace's state, so it
agrees with the menu item at open time, and selection changes while the palette
is open flow through the existing fingerprint recompute. The residual gap is a
mirror-set change with the selection unchanged; the narrow mirror-routing
revision described in §2 closes it for both surfaces.

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
- **A predicate-only test is not wiring coverage.** The gate test above still
  passes if the snapshot population, the contribution insertion, the handler
  registration, or the shortcut-glyph mapping is simply omitted — four
  connections, each a one-liner someone can drop in a refactor. Declare the
  command ID once (`static let newLocalWorkspaceCommandId = "palette.newLocalWorkspace"`)
  and use it at all four sites, then add connection assertions: the resolved
  command list from `ContentView.commandPaletteCommands(...)` contains the ID
  when the context key is set (proves population + insertion), the handler
  registry resolves the ID (proves registration), and
  `commandPaletteShortcutAction(forCommandID:)` maps it to `.newLocalWorkspace`
  (proves the glyph mapping).
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

- Any change to how New Workspace / ⌘N routes; this only adds a palette surface for
  the already-defined local action.
