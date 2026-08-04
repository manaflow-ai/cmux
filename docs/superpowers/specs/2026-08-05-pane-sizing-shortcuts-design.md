# Pane sizing shortcuts

## Status

Approved design for issue #8855 and the keyboard-first resize request in #1756.

## Intent

Make the common keyboard pane-sizing operations immediate and predictable:

- Nudge a divider in a spatial direction.
- Set the focused pane to a familiar proportion.
- Temporarily give the focused pane all available height without changing its width or losing the prior layout.

This complements, rather than replaces, cmux's existing full-workspace pane zoom: **Toggle Pane Zoom**, default `Command-Shift-Return`.

## Exact-share presets

Presets always describe the focused branch's share of its nearest enclosing split on the requested axis. They never mean an absolute left/top divider coordinate.

| Action | Default | Result |
| --- | --- | --- |
| Set Pane Width to One Third | `Option-Command-1` | Focused pane receives 1/3 of its nearest width split. |
| Set Pane Width to One Half | `Option-Command-2` | Focused pane receives 1/2 of its nearest width split. |
| Set Pane Width to Two Thirds | `Option-Command-3` | Focused pane receives 2/3 of its nearest width split. |
| Set Pane Height to One Third | `Shift-Option-Command-1` | Focused pane receives 1/3 of its nearest height split. |
| Set Pane Height to One Half | `Shift-Option-Command-2` | Focused pane receives 1/2 of its nearest height split. |
| Set Pane Height to Two Thirds | `Shift-Option-Command-3` | Focused pane receives 2/3 of its nearest height split. |

The presets use the existing `TabManager` to `CmuxPanes` exact-share path. It selects the nearest matching ancestor, inverts the divider coordinate for a second-child focused branch, honors effective minimum sizes, and reports a clamp rather than silently producing the wrong share.

The current numbered `n:1` family (`1...6`) is removed. Although mathematically consistent, it forces users to calculate that `3` means 3/4. One-third, one-half, and two-thirds are recognizable layout intents. Arbitrary percentage and ratio input remains a future Command Palette/CLI feature.

## Incremental directional resizing

Keep four first-class, remappable native actions with the defaults requested in #1756:

| Action | Default | Meaning |
| --- | --- | --- |
| Resize Pane Left | `Control-Shift-H` | Move the controlling vertical divider left. |
| Resize Pane Down | `Control-Shift-J` | Move the controlling horizontal divider down. |
| Resize Pane Up | `Control-Shift-K` | Move the controlling horizontal divider up. |
| Resize Pane Right | `Control-Shift-L` | Move the controlling vertical divider right. |

These actions are named **Resize**, not **Grow**. A key describes spatial divider movement: moving a divider left shrinks a focused left-hand pane and grows a focused right-hand pane. This stays truthful in every layout and aligns with tmux-style resize commands.

The handler resolves the nearest relevant divider and retains the existing useful opposite-edge fallback at an outer boundary. Key repeat preserves focus, and the existing pixel-step and clamping behavior applies.

## Toggle Pane Height Maximize

Add one configurable action:

| Action | Default | Meaning |
| --- | --- | --- |
| Toggle Pane Height Maximize | `Shift-Option-Command-0` | Toggle the focused pane between its saved height layout and maximum available height, preserving all widths. |

This is neither a 90/10 ratio nor an alias for full-pane zoom. It preserves every horizontal divider. It maximizes height by collapsing competing panes on the focused pane's vertical ancestor path and leaves every competing pane header visible.

There is one height-maximized pane per workspace. Invoking the action on the same pane restores the saved layout. Invoking it on another pane restores the previous layout and then height-maximizes the newly focused pane.

## Collapse and restoration model

Height maximize requires a real reversible layout mode; it must not be implemented as a fixed ratio.

1. Resolve the focused pane and walk every ancestor that divides height. Do not modify a width divider.
2. Capture current vertical divider positions and split identities in a workspace-scoped height-maximize snapshot.
3. Collapse every visible leaf in competing branches to its pane-header height. The focused path gets the remaining vertical space.
4. If all required visible headers cannot fit, reject without changing the layout. A header must not disappear merely to claim a maximized result.
5. Toggling the same pane restores the captured divider positions exactly, only when split identities still match the active layout.
6. A manual divider mutation, split/close, restoration, or workspace destruction invalidates the snapshot so stale geometry is never restored.

The capability belongs in `CmuxPanes` as a pure plan plus apply result. The workspace owns only reversible snapshot lifetime. `TabManager`, shortcuts, the Command Palette, and future CLI use one shared action. Full-pane zoom retains its independent behavior and state.

## Configuration, errors, and discoverability

Every action is represented in both `CmuxSettings.ShortcutAction` and the app shortcut model, is editable in Settings, serializable in `cmux.json`, included in the schema and web shortcut reference, and localized across all supported app/web locales.

The shared shortcut system must detect conflicts for default and custom bindings. Before shipping, verify that the six Option-Command number bindings and four Control-Shift vi-key bindings do not collide with cmux-owned defaults or macOS-reserved shortcuts.

- Exact presets report the actual applied share when clamped and reject Canvas and unsupported remote-managed layouts without a local geometry mutation.
- Directional resize rejects only when no compatible divider exists or the layout cannot accept the move; it never loses focus.
- Height maximize rejects when no height ancestor exists, required headers cannot all remain visible, or a snapshot is stale.
- While full-pane zoom is active, sizing actions remain unavailable rather than mutating a hidden layout.

## Architecture

```text
Settings / shortcut / palette / future CLI
                  |
             TabManager
                  |
           CmuxPanes service
                  |
       Bonsplit tree and geometry
```

`AppDelegate` only matches and dispatches shortcuts. `TabManager` resolves the selected workspace and focused pane, owns height-maximize snapshot lifetime, and forwards to `CmuxPanes`. `CmuxPanes` owns ancestor selection, focused-branch conversion, collapse planning, header validation, and structured results. Bonsplit remains the sole geometry authority.

## Testing

1. Width and height presets select the nearest matching ancestor and yield exactly 1/3, 1/2, or 2/3 for both first and second focused branches.
2. Presets clamp predictably and return the actual applied share.
3. The six preset defaults and four directional defaults are configurable, serializable, and conflict-checked.
4. Each directional key moves the divider in its named spatial direction; focused panes on opposite sides grow or shrink accordingly.
5. Outer-boundary fallback stays useful and key repeat preserves focus.
6. Height maximize preserves all width dividers, collapses only vertical competitors, and leaves each competing pane header visible.
7. A same-pane toggle restores exact pre-maximize divider positions; a different-pane toggle restores and then maximizes the new focused pane.
8. Manual layout changes, split/close, restoration, and workspace teardown invalidate the height-maximize snapshot safely.
9. Full-pane zoom, Canvas, and remote-managed layouts have explicit, non-mutating unsupported behavior.
10. Shortcuts, Command Palette, and exposed automation share one `TabManager` command path.
11. App labels, configuration schema, web shortcut data, documentation, and every supported locale cover the changed actions.

## Delivery order

1. Replace the numbered `n:1` family with the six fixed presets and make the #1756 directional bindings defaults.
2. Deliver the `CmuxPanes` collapse-plan capability and workspace snapshot lifecycle.
3. Add the height-maximize shortcut and Settings/configuration/docs surfaces after the reversible behavior is tested.
4. Follow with arbitrary ratio input in the Command Palette and CLI only after the fixed shortcut vocabulary is stable.
