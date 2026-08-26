# Runtime Pitfalls

Why the rules in [../SKILL.md](../SKILL.md) exist, and what to check when one bites.

## Drag-and-drop UTTypes

Custom UTTypes are declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`, for example `com.splittabbar.tabtransfer` and `com.cmux.sidebar-tab-reorder`. If drag/drop works in a narrow local test but fails across a process or extension boundary, check Info.plist before rewriting the drag model.

## Terminal rendering and typing latency

A second draw loop (an app-level display link or manual `ghostty_surface_draw`) can make typing lag worse and hide the real invalidation source. cmux relies on Ghostty wakeups and renderer scheduling.

`TerminalSurface.forceRefresh()` runs on every keystroke: no allocation-heavy formatting, file I/O, disk logging, hot-loop string interpolation, or layout work. `WindowTerminalHostView.hitTest()` runs on every event including keyboard, so divider/sidebar/drag routing stays inside the `isPointerEvent` guard. Even "small" checks compound on typing paths.

## Tab rows

Before adding `@EnvironmentObject`, `@ObservedObject`, `@Binding`, a store read in `body`, or a parameter derived from mutable global state to `TabItemView`, update the `==` function and confirm the `ForEach` call site still uses `.equatable()`. Prefer passing precomputed immutable values.

## Terminal find layering

Portal-hosted terminal views can sit above SwiftUI during split/workspace churn, so mounting `SurfaceSearchOverlay` from a SwiftUI panel container such as `Sources/Panels/TerminalPanelView.swift` produces intermittently hidden or detached search controls. It belongs in `GhosttySurfaceScrollView` (the AppKit portal layer) in `Sources/GhosttyTerminalView.swift`.

## Snapshot boundary for list subtrees

Below a `LazyVStack` / `LazyHStack` / `List` / `ForEach` boundary, no view may hold an `ObservableObject` or `@Observable` store reference: not `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, nor a plain `let store: SomeStore`. Rows and drop gaps take immutable value snapshots plus closure action bundles.

Violating this reintroduces the class of bug where an orthogonal published change invalidates every row and thrashes `LazyLayoutViewCache` into a 100% CPU main-thread spin loop, which hit the Sessions panel and the workspace sidebar (https://github.com/manaflow-ai/cmux/issues/2586). Reference patterns: `IndexSectionActions`, `SectionGapActions`, `SessionSearchFn` in `Sources/SessionIndexView.swift`.

## No body-time mutation

A function called from `body`, directly or through a helper, must not write observable state, schedule `Task { @MainActor in store.x = ... }`, or `DispatchQueue.main.async` a store write. That is a re-render feedback loop, the same root-cause family as the snapshot-boundary rule. State-changing work triggered by "new data appeared" belongs in a `reload()` completion, a `didSet`, or a property observer, never in the projection feeding `ForEach`.

## OS-version repros

Foundation, SwiftUI, AttributeGraph, and WebKit behavior changes silently between macOS majors. From https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26, because Apple fixed CFURL normalization. The repo's `macos-26` CI and every maintainer's machine were on the fixed side; every reporter was on the broken side.

Test on the reporter's macOS before declaring a repro disproven. AWS M4 Pro builders (`cmux-aws-mac`, `cmux-aws-m4pro`, `aws-m4pro-1..6`) are pre-provisioned on macOS 15.7.4 and are the preferred empirical repro path.
