---
name: cmux-debugging
description: "Debug logging, Debug menu, runtime pitfalls, typing-latency-sensitive paths, SwiftUI list snapshot boundaries, OS-version repros, and local visual iteration for cmux. Use when adding debug probes, diagnosing UI/runtime issues, touching terminal rendering, tab/sidebar list views, drag/drop UTTypes, or using the Debug menu."
---

# cmux Debugging

## Debug event log

When adding debug event instrumentation, put events (keys, mouse, focus, splits, tabs) in the unified DEBUG build log. This is not a blanket requirement to add logs to every new code path. Most temporary probes should be added only during the dogfood debug loop and removed before merge.

```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

- Untagged Debug app: `/tmp/cmux-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/cmux-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/cmux-last-debug-log-path`
- `reload.sh` writes the selected dev CLI path to `/tmp/cmux-last-cli-path`
- `reload.sh` updates `/tmp/cmux-cli` and `$HOME/.local/bin/cmux-dev` to that CLI
- Implementation: `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift`
- App shim: `Sources/App/DebugLogging.swift`
- Free function `cmuxDebugLog("message")` logs with timestamp and appends to file in real time from cmux code
- The package implementation and app shim are `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `CMUXDebugLog.DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`

## Debug menu

The app has a **Debug** menu in the macOS menu bar only in DEBUG builds. Use it for visual iteration.

- **Debug > Debug Windows** contains panels for tuning layout, colors, and behavior. Entries are alphabetical with no dividers.
- To add a debug toggle or visual option: create an `NSWindowController` subclass with a `shared` singleton, add it to the "Debug Windows" menu in `Sources/cmuxApp.swift`, and add a SwiftUI view with `@AppStorage` bindings for live changes.
- When the user says "debug menu" or "debug window", they mean this menu, not `defaults write`.

## Runtime pitfalls

- Custom UTTypes for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`.
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- `WindowTerminalHostView.hitTest()` is typing-latency-sensitive. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
- `TabItemView` uses `Equatable` conformance plus `.equatable()` to skip body re-evaluation during typing. Do not add environment/store/binding reads without updating equality and the call site.
- `TerminalSurface.forceRefresh()` is called on every keystroke. Do not add allocations, file I/O, or formatting there.
- `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift`, not from SwiftUI panel containers.
- List subtrees with `LazyVStack`, `LazyHStack`, `List`, or `ForEach` must pass immutable row snapshots plus closures below the boundary. Do not pass observable stores into row views.
- Functions called from SwiftUI `body` must not mutate state or schedule store writes.
- Foundation, SwiftUI, AttributeGraph, and WebKit semantics can change between macOS major versions. Test on the reporter's macOS before declaring a user repro disproven.

## Detailed references

- Read [references/debug-event-log.md](references/debug-event-log.md) when adding or interpreting debug log probes.
- Read [references/runtime-pitfalls.md](references/runtime-pitfalls.md) before touching terminal rendering, hit testing, tab rows, list virtualization, search overlay layering, or OS-version-sensitive code.
