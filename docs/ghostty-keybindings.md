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

One binding table decides every key. When several bindings claim the same keys,
this order applies (first wins):

1. Your cmux shortcuts: `shortcuts.bindings` in `~/.config/cmux/cmux.json`,
   **Settings > Keyboard Shortcuts**, and keybindings.json.
2. Your Ghostty keybindings, in every pane and surface. A binding counts as
   yours when it differs from Ghostty's default.
3. cmux's default shortcuts.
4. Ghostty's default keybindings.

So a line such as `keybind = super+d=new_split:down` replaces cmux's Cmd+D
(Split Right) everywhere: a terminal runs it itself, and in a browser pane, the
sidebar or terminal copy mode cmux runs the same action (Split Down). To take a
key back from your Ghostty config, bind it in cmux.json.

A Ghostty keybinding that maps a key to a terminal action (`text:`, `csi:`,
`esc:` and the like) or `unbind`s it also takes that key from cmux's defaults.
For example `keybind = ctrl+shift+h=unbind` sends Ctrl+Shift+H to the terminal
program instead of running Resize Pane Left; the action keeps its other default
key (Ctrl+Cmd+Left). The Keyboard Shortcuts page lists such a default with the
source "Ghostty config".

cmux reads your Ghostty config at launch and again whenever it changes, and
applies it as a live layer. It never copies Ghostty keybindings into cmux.json,
so an edit of the Ghostty config takes effect without an import step.

A cmux shortcut that applies only in another place (for example a browser-only
shortcut) does not block the key: the next binding in the order gets it. A cmux
shortcut that applies here but cannot run now still takes the key from the
bindings below it, and the key goes to the focused view. Browser shortcuts in a
browser pane (Cmd+[ Back, Cmd+Y History) stay the browser's even when your
Ghostty config binds the same key.

Ghostty keybindings for window, tab and split actions (the tables below) work
outside a terminal. Other Ghostty bindings run only while a terminal surface has
keyboard focus. The Keyboard Shortcuts page lists your Ghostty keybindings
(source "Ghostty") and Ghostty's defaults (source "Ghostty default"). They are
read-only there: edit your Ghostty config to change them.

Limits: Ghostty reports one key per action. If you bind one of Ghostty's default
keys to a different action, cmux still sees that key as a Ghostty default, so a
cmux default on that key wins. An `unbind` inside a key sequence (`ctrl+b>x`)
does not free a cmux default.

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
| `undo` | Reopen the last closed item (Reopen Last Closed Item). |
| `toggle_visibility` | Show or hide all cmux windows. |
| `toggle_tab_overview` | Open tab search in the command palette. |
| `check_for_updates` | Check for cmux updates. |
| `prompt_surface_title`, `prompt_tab_title` | Rename the tab. |
| `prompt_window_title`, `set_window_title:TITLE` | Rename the active workspace (cmux's window title). |
| `close_all_windows` | Close every cmux window, each through its own confirmation. |
| `toggle_maximize` | Zoom the window (Window > Zoom). |
| `goto_window:next`, `goto_window:previous` | Select the next or previous cmux window. |
| `move_tab_to_new_window` | Move the tab to a new window. |

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
