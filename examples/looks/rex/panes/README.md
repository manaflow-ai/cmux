# Rex pane controls

A standalone, opt-in shortcut layer for terminal panes. It adds bindings to
existing cmux NEXT actions; it does not change layout settings or app defaults.
Every binding has `when: "terminalFocused"`. Browser, chat, and text-field focus
keep their existing keys. Focus navigation may land on another kind of pane;
these shortcuts then stop matching until a terminal has focus again.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/panes@feat-cmux-next
```

To remove the installed layer, run `cmux setup remove manaflow-ai/rex-panes`.
To preview from the repository root, run the following commands, then choose
`cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/panes/profile.json
cmux customize check
```

## Mapping

Source: [Mac Actions, Pane](https://www.superlogical.com/rex/docs/reference/mac-actions#pane). Key names below use cmux's
`opt` for the source's `alt`.

| Source action | cmux action | Installed key |
| --- | --- | --- |
| `pane.split.right` | `splitRight` | Cmd+D; Cmd+Shift+Right |
| `pane.split.down` | `splitDown` | Cmd+Shift+D; Cmd+Shift+Down |
| `pane.split.left` | `splitLeft` | Cmd+Shift+Left |
| `pane.split.up` | `splitUp` | Cmd+Shift+Up |
| `pane.focus.left/right/up/down` | `focusLeft` / `focusRight` / `focusUp` / `focusDown` | Cmd+Opt+direction |
| `pane.focus_next` | `focusNextPane` | Cmd+] |
| `pane.focus_previous` | `focusPreviousPane` | Cmd+[ |
| `pane.move.left/right/up/down` | `swapPaneLeft` / `swapPaneRight` / `swapPaneUp` / `swapPaneDown` | Cmd+Opt+Shift+direction |
| `pane.zoom` | `toggleSplitZoom` | Cmd+Shift+Enter |
| `pane.float` | `toggleFloatingPane` | Cmd+Opt+Enter |
| `pane.balance` | `equalizeSplits` | Ctrl+Cmd+= (cmux's key; source has none) |

These are terminal-scoped overrides of the listed keys. The original actions
remain available in the palette. No default binding is removed globally.
In particular, bracket navigation does not take browser Back/Forward.

## Boundaries

- Directional movement uses cmux's **swap with the neighbor** operation. Focus
  next/previous follows cmux's pane order, not focus history across sessions.
- Splitting, zoom, floating, and equalization operate on cmux's layout model;
  this pack does not emulate a different tab/session hierarchy.
- `pane.split.auto` has no exact mapping here: `newPaneAutoLayout` is cmux's
  own arranging behavior, not a verified best-fit directional split. Cmd+Enter
  is deliberately not rebound to it.
- Recent-pane history, minimizing floating windows, close-other-panes, and
  moving a pane into another tab are not implemented by this pack. Close keeps
  cmux's existing behavior rather than rebinding Cmd+W to close an entire pane.
- Resize is available through cmux's existing `resizePaneLeft`,
  `resizePaneRight`, `resizePaneUp`, and `resizePaneDown` palette actions. The
  source gives `pane.resize` no default key, so none is invented here.
- [Splits & Focus settings](https://www.superlogical.com/rex/docs/reference/mac-settings)
  map partially to `layout.splitSizing` and `layout.focusFollowsMouse`. The
  schema describes `even` as equalizing panes **in a column after a split**;
  it does not promise the source's open/close balancing with dragged-divider
  preservation. Neither setting is changed.

## Implementation evidence

Paths relative to the cmux repository:

- `cmux-tui/crates/cmux-action-catalog/src/catalog/pane.rs`: split right/down,
  focus/cycle, zoom, floating, balance, and resize identifiers.
- `cmux-tui/crates/cmux-action-catalog/src/catalog/layout.rs`: split left/up
  and directional swap identifiers.
- `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/PaneHandlers.swift`
  and `PaneHandlers+Verbs.swift`: focus cycling and adjacent-pane swaps.
- `schemas/settings/settings-schema.json`: split sizing and pointer focus.
- `cmux-tui/crates/cmux-customize/src/setup.rs`, `setup/reference.rs`, and
  `library/keys.rs`: adjacent-file loading, repository subpaths, and binding
  merging/removal.

![Source window, with three terminal panes below the tab strip](../new-tab/screenshots/source-window.webp)
