# Progress: Accessibility Integration Scout

## Status: COMPLETE

### Task
Scout the cmux codebase for the practical integration picture for accessibility improvements.

### Deliverable
Written to `/tmp/cmux-scout-accessibility-integration.md`

### Key Findings Summary

1. **Toolbar/Titlebar**: No SwiftUI `.toolbar` modifier. Uses dual-track system:
   - Standard mode: `NSTitlebarAccessoryViewController` hosting SwiftUI `TitlebarControlsView`
   - Minimal mode: AppKit `MinimalModeSidebarControlActionView` (NSViewRepresentable) in sidebar titlebar strip

2. **Toolbar ↔ Sidebar**: Separate view hierarchies. Titlebar controls live in AppKit titlebar zone; sidebar is in the SwiftUI content area HStack. Minimal mode bridges them via `HiddenTitlebarSidebarControlsView`.

3. **Existing accessibility patterns**: Extensive — ~150+ accessibility modifier uses across the codebase. Catalog covers `accessibilityIdentifier`, `accessibilityLabel`, `accessibilityHint`, `accessibilityElement(children:)`, `accessibilityHidden`, `accessibilityAction(named:)`, `accessibilityPerformPress()`, AppKit overrides (role, value, selectedText). Full catalog in deliverable.

4. **View hierarchy**: Full chain documented from NSWindow → NSTitlebarAccessoryViewController → TitlebarControlsView, and from ContentView.body → HStack → sidebarPanelWithBackdrop → VerticalTabsSidebar → workspace rows.

5. **`.accessibilityElement(children: .combine/.ignore)`**: Used correctly — `.ignore` on TitlebarControlButton to prevent duplicate announcements, `.combine` on sidebar workspace rows.

6. **NSViewRepresentable wrappers**: ~40+ wrappers identified. Key ones with AX implications: MinimalModeSidebarControlActionProxyView, GhosttyTerminalView, WindowDragHandleView.

### Constraints
- Must maintain dual-track fixes (SwiftUI + AppKit)
- Snapshot boundary rules apply to sidebar row views
- TitlebarControlButton uses `.accessibilityElement(children: .ignore)` — children hidden
- NSApplication accessibility swizzle in AppDelegate caches window lists
