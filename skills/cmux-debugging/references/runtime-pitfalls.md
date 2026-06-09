# Runtime Pitfalls

This reference expands the high-risk cmux runtime rules.

## Drag-and-drop UTTypes

Custom UTTypes must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`. Examples include:

- `com.splittabbar.tabtransfer`
- `com.cmux.sidebar-tab-reorder`

If drag/drop works only inside a narrow local test but fails across process or extension boundaries, check Info.plist before rewriting the drag model.

## Terminal rendering and typing latency

Do not add an app-level display link or manual `ghostty_surface_draw` loop. cmux relies on Ghostty wakeups and renderer scheduling. A second draw loop can make typing lag worse and hide the real invalidation source.

`TerminalSurface.forceRefresh()` in `Sources/GhosttyTerminalView.swift` is called on every keystroke. Do not add:

- allocation-heavy formatting
- file I/O
- logging to disk
- string interpolation in hot loops
- layout work

If you need to observe this path, use the smallest possible DEBUG-only probe and remove it before merge unless it is intentionally durable.

## Hit testing

`WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift` is called on every event, including keyboard events. Divider/sidebar/drag routing is intentionally gated to pointer events.

Do not add work outside the `isPointerEvent` guard. Even "small" checks compound on typing paths.

## Tab rows

`TabItemView` in `ContentView.swift` uses `Equatable` conformance plus `.equatable()` to skip body re-evaluation during typing.

Before adding any of these to the view:

- `@EnvironmentObject`
- `@ObservedObject`
- `@Binding`
- a plain store read in `body`
- a new parameter derived from mutable global state

Update the `==` function and verify the `ForEach` call site still uses `.equatable()`. Prefer passing precomputed immutable values.

## Terminal find layering

`SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift`, the AppKit portal layer. Do not mount it from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`.

Portal-hosted terminal views can sit above SwiftUI during split/workspace churn. Mounting the search UI at the wrong layer creates intermittently hidden or detached search controls.

## Snapshot boundary for list subtrees

In any SwiftUI panel whose `body` contains a `LazyVStack`, `LazyHStack`, `List`, or `ForEach` of rows, no view below that boundary may hold a reference to an `ObservableObject` or `@Observable` store. That includes:

- `@ObservedObject`
- `@EnvironmentObject`
- `@StateObject`
- `@Bindable`
- a plain `let store: SomeStore`

Rows and drop gaps receive immutable value snapshots plus closure action bundles only.

This avoids the class of bugs where an orthogonal published change invalidates every row and thrashes `LazyLayoutViewCache`, causing a main-thread spin loop. Reference patterns include `IndexSectionActions`, `SectionGapActions`, and `SessionSearchFn` in `Sources/SessionIndexView.swift`.

## No body-time mutation

A function called from SwiftUI `body`, directly or through a helper, must not:

- write observable state
- schedule `Task { @MainActor in store.x = ... }`
- call `DispatchQueue.main.async` to write store state

State-changing work triggered by "new data appeared" belongs in a reload completion, a `didSet`, or a property observer. It does not belong in the projection that feeds `ForEach`.

## OS-version repros

Foundation, SwiftUI, AttributeGraph, and WebKit behavior can change silently between macOS versions. A function that seems deterministic on macOS 26 may behave differently on macOS 14 or 15.

Concrete example: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returned `"/.."` on macOS 14 and 15 but `"/"` on macOS 26.

When a user reports a repro on an older macOS, test on that macOS before declaring the repro disproven. AWS M4 Pro builders such as `cmux-aws-mac`, `cmux-aws-m4pro`, and `aws-m4pro-1..6` are pre-provisioned on macOS 15.7.4 and are the preferred empirical repro path.
