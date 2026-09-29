# Ghostty keybindings in cmux

cmux reads terminal keybindings from your Ghostty configuration, including
`~/.config/ghostty/config` and `config.ghostty`. Ghostty evaluates sequences,
key tables, and the `performable:` and `unconsumed:` binding flags itself.

A Ghostty **tab** maps to a cmux **workspace** in the sidebar: both own a split
tree. A Ghostty **surface** maps to one terminal pane, so `close_surface` and
`close_tab` close different things.

```ini
keybind = ctrl+b>c=new_tab
keybind = ctrl+b>q=close_surface
keybind = ctrl+b>1=goto_tab:1
keybind = ctrl+b>2=goto_tab:2
keybind = ctrl+b>3=goto_tab:3
keybind = ctrl+b>4=goto_tab:4
keybind = ctrl+b>5=goto_tab:5
keybind = ctrl+b>6=goto_tab:6
```

Press and release Ctrl+B, then press the second key. These bindings supplement
your cmux shortcuts; they do not replace Cmd+N or Cmd+W.

## Precedence and focus

cmux routes its configurable shortcuts before passing input to the terminal.
A key or sequence leader claimed by a cmux shortcut never reaches Ghostty.
Rebind or clear that cmux shortcut in **Settings > Keyboard Shortcuts** or
`shortcuts.bindings` in `~/.config/cmux/cmux.json` to make it available.

Ghostty bindings run only while a terminal surface has keyboard focus. They do
not apply to browser panes, Markdown panes, the TextBox, or the command palette.
Use cmux shortcuts for actions that should work across those surfaces.

cmux suppresses Ghostty's built-in workspace/window shortcuts before loading
your bindings. The existing cmux-owned split, close, workspace-number, and
workspace-font-size unbinds still apply after loading your config. In particular,
Cmd+1–9 remains owned by `KeyboardShortcutSettings`, including when remapped or
cleared. Write a different Ghostty binding, such as Ctrl+B followed by a digit.

## Workspace and window actions

| Ghostty action | cmux behavior |
| --- | --- |
| `new_tab` | New Workspace, using the same placement and configured creation action as Cmd+N. |
| `goto_tab:N` | Select workspace N in the owning window's complete workspace order (including grouped workspaces), starting at 1; an invalid index does nothing and never creates a window. `goto_tab:9` means the ninth workspace. |
| `last_tab` | Select the last workspace. |
| `next_tab`, `previous_tab` | Use cmux's next/previous workspace navigation. |
| `close_tab` | Close the source workspace through the existing confirmation flow. |
| `move_tab:N` | Reorder the source workspace by N, wrapping at the window's ends, then applying cmux's pinned and grouped workspace constraints. |
| `new_window` | New cmux window. |
| `close_window` | Close the source window through the existing confirmation flow. |
| `toggle_fullscreen` | Toggle native macOS full screen on the source window. |
| `toggle_command_palette` | Open cmux's command palette in the source window. |
| `open_config` | Open the Ghostty configuration through cmux's existing config editor command. |
| `quit` | Request normal cmux quit, including its configured confirmation and cleanup. |

Terminal actions already handled by Ghostty, such as text input, copying,
scrolling, and font changes, continue to work. Existing split actions continue
to use cmux's split commands.

## Unsupported host actions

Ghostty UI features without a cmux mapping return `false` and emit a warning
in the macOS unified log under the `ghostty.actions` category. This includes
`toggle_tab_overview`, `prompt_surface_title`, `prompt_tab_title`, `set_tab_title`,
`close_all_windows`, `goto_window`, `toggle_maximize`, `toggle_visibility`,
`toggle_quick_terminal`, `reset_window_size`, `toggle_window_decorations`,
`toggle_background_opacity`, `inspector`, `show_gtk_inspector`, `check_for_updates`,
`undo`, `redo`, `copy_title_to_clipboard`, `present_terminal`, `toggle_window_float_on_top`,
`toggle_secure_input`, and `show_on_screen_keyboard`. `close_tab:other`, `close_tab:right`, and non-native
fullscreen modes are also unsupported.

Use cmux's existing commands for workspace/pane renaming, window management,
updates, and reopening closed items. Leader syntax and key tables already belong
in Ghostty config; no additional cmux leader setting is needed.

To inspect unsupported-action warnings in Console, filter by category
`ghostty.actions`, or run:

```sh
log show --last 5m --predicate 'category == "ghostty.actions"'
```
