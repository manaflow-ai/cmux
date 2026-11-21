# Native pane + menu

`tabs.plusMenu` is an ordered subset of `terminal`, `localWorkspace`,
`machineWorkspace` and `host`.
Its default is `[]`, which keeps the direct New Tab action. For example:

```json
{"tabs":{"plusMenu":["terminal","localWorkspace","machineWorkspace","host"]}}
```

The General > Tabs setting uses the standard ordered choices editor. The descriptor
also exposes the setting through the palette, CLI and MCP. A primary mouse-down or
accessibility press opens the existing themed native menu anchored under +. There
are no new dimensions, animations, windows or menu styles. Changes take effect on
the next click, without observing settings separately in every pane.

| Value | Existing action | Destination |
| --- | --- | --- |
| `terminal` | `newSurface` | Clicked pane and its machine; existing terminal placement preferences apply |
| `localWorkspace` | `workspace.newOnMachine` | Explicit local machine, even from a remote pane |
| `machineWorkspace` | `workspace.newOnMachine` | Its own machine picker (New Workspace on Machine…) |
| `host` | `remote.connect` | Existing destination picker (add a remote host) |

The chevron, context click, Option-click, screen bar and keyboard shortcuts keep
their current behavior. `contextMenus.layouts.newTab` still controls the separate
chooser/context menu. `tabs.plusButton` still controls visibility. An empty or
invalid runtime value uses direct creation. Existing action availability and
permission checks remain in force; unavailable entries may be omitted.

This is macOS native tab-strip chrome. The iPhone has no corresponding native
pane + control, so there is no iPhone interaction to change.

Acceptance states: default direct creation; all three ordered rows; a reordered
subset. `ConfiguredPlusMenuTests`, `PaneTabBarControlsTests` and Rust
`tabs::plus_menu` tests cover routing and preserved entrypoints.
