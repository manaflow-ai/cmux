## Summary

Fix an infinite SwiftUI render loop in `BrowserPanelView` caused by writing to
an `@AppStorage` property inside its own `onChange` handler.

## Problem

The `onChange(of: browserThemeModeRaw)` handler normalizes the raw value and
writes the result back to `browserThemeModeRaw`. Because `@AppStorage` mutations
immediately invalidate the SwiftUI attribute graph, this write can trigger body
re-evaluation during the current render pass. When combined with
`panel.setBrowserThemeMode()` firing `objectWillChange` on the observed panel,
the attribute graph enters an infinite update cycle:

```
GraphHost.flushTransactions()
  → AG::Subgraph::update()
    → AG::Graph::UpdateStack::update()
      → BrowserPanelView.body.getter
        → addressBar / addressBarButtonBar
```

In a real incident, this consumed 100% CPU on the main thread for 26+ minutes,
completely blocking the event loop and preventing all UI interaction.

## Fix

Move the `@AppStorage` normalization write to `DispatchQueue.main.async` so it
executes on the next runloop iteration rather than during the current attribute
graph update. The `panel.setBrowserThemeMode()` call remains synchronous so the
panel state is updated immediately.

## Test plan

- [ ] Toggle browser theme mode in settings — verify the mode applies correctly
- [ ] Verify no render loop by monitoring CPU usage during theme changes
- [ ] Test with mismatched `browserThemeModeRaw` values in UserDefaults to
      confirm normalization still converges
- [ ] Run UI tests against a tagged debug build
