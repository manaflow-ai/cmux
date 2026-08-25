# Keyboard

[日本語](keyboard.ja.md)

## Prefix Model

`cmux-tui` uses a tmux-style prefix. The default prefix is `Ctrl-b`. After the prefix, the next key is interpreted as a mux command. Pressing the prefix twice sends a literal `Ctrl-b` to the active surface.

Unknown prefixed keys are swallowed. Unprefixed keys go to the active surface unless they match a configured modeless Alt or Command/Super chord, or an explicitly configured Control-modified clear-history chord.

Pressing the prefix overlays the panes' bottom border for one keypress, leaving the clickable screen status bar visible. Each resolved suffix uses a distinct accent font color without changing the bar background. `Ctrl-b ?` opens a shortcut modal built from the same action catalog, with shortcut keys in a bright neutral font color. The terminal-style scrollbar appears only when the shortcut rows overflow. Use Up/Down, PageUp/PageDown, Home, End, the mouse wheel, or the scrollbar to scroll. Click its invisible track to jump, drag its thumb, then use Esc, `?`, or the visible `[Esc close]` button to close the modal.

## Default Bindings

These defaults come from `Keys::default`.

| Binding | Action |
| --- | --- |
| `Ctrl-b Ctrl-b` | Send a literal `Ctrl-b` to the active surface |
| `Ctrl-b t` | New PTY tab in the active pane |
| `Alt-t` | New PTY tab in the active pane |
| `Ctrl-b B` | Open the browser-tab URL prompt |
| `Alt-n` | Create a pane with Zellij's default auto-layout in the focused horizontal column |
| `Ctrl-b Tab` | Next tab in the active pane |
| `Ctrl-b BackTab` | Previous tab in the active pane |
| `Ctrl-b 0` through `Ctrl-b 9` | Select visible screen 0 through 9 |
| `Ctrl-b %` | Split the active pane right |
| `Ctrl-b "` | Split the active pane down |
| `Ctrl-b x` | Close the active tab |
| `Ctrl-b X` | Close the active pane |
| `Ctrl-b ,` | Rename the active screen |
| `Ctrl-b $` | Rename the active workspace |
| `Ctrl-b &` | Close the active screen |
| `Ctrl-b p` | Previous screen in the active workspace |
| `Alt-[` | Previous screen in the active workspace |
| `Ctrl-b n` | Next screen in the active workspace |
| `Alt-]` | Next screen in the active workspace |
| `Ctrl-b c` | New screen in the active workspace |
| `Ctrl-b z` | Maximize the active pane or restore the pane layout |
| `Ctrl-b o` | Focus the next pane in the current screen |
| `Ctrl-b {` | Swap the active pane with the previous pane |
| `Ctrl-b }` | Swap the active pane with the next pane |
| `Ctrl-b (` | Previous workspace |
| `Alt-{` | Previous workspace |
| `Ctrl-b w` or `Ctrl-b )` | Next workspace |
| `Alt-}` | Next workspace |
| `Ctrl-b W` | New workspace |
| `Ctrl-b D` | Close the active workspace |
| `Ctrl-b s` | Show or hide the sidebar |
| `Ctrl-b m` | Toggle the sidebar between compact and full width; shows it when hidden |
| `Ctrl-b e` | Toggle the built-in sidebar between files and workspaces |
| `Ctrl-b S` | Focus the built-in sidebar or configured sidebar plugin; a prefixed command returns focus to the pane |
| `m` | Open the machine provider menu when the machine rail is focused |
| `Ctrl-b g` | Append a two-thirds-width terminal to the right |
| `Ctrl-b U` | Undo the latest structural layout action on the focused screen |
| `Ctrl-b ?` | Open the keyboard shortcut modal |
| `Ctrl-b h` or `Ctrl-b Left` | Focus left |
| `Alt-h` or `Alt-Left` | Focus left |
| `Ctrl-b l` or `Ctrl-b Right` | Focus right |
| `Alt-l` or `Alt-Right` | Focus right |
| `Ctrl-b k` or `Ctrl-b Up` | Focus up |
| `Alt-k` or `Alt-Up` | Focus up |
| `Ctrl-b j` or `Ctrl-b Down` | Focus down |
| `Alt-j` or `Alt-Down` | Focus down |
| `Alt-=` | Grow the focused split, or its horizontal viewport column |
| `Alt--` | Shrink the focused split, or its horizontal viewport column |
| `Ctrl-b [` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageUp` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageDown` | Scroll the active PTY viewport down 10 rows |
| `Cmd-k` / `Super-k` | Clear retained PTY history and completed visible rows while preserving active input |
| `Ctrl-b d` | Quit a local TUI or detach an attached TUI |

Directional focus follows Zellij's pane memory: when several panes share the requested edge, cmux-tui returns to the pane focused most recently.

When a screen is wider than the viewport, `h`/`l`, Left/Right, and their modeless Alt bindings reveal the focused pane. The viewport movement is animated unless `viewport.animation` is false.

On a screen created with `Ctrl-b g`, `Alt-=` and `Alt--` resize the complete horizontal column containing the focused pane in five-percent steps. On an ordinary screen they retain their existing split-resize behavior.

`Ctrl-b U` undoes the latest pane creation, split resize, column resize, swap, zoom, or automatic-layout change on the focused screen. Repeated resize updates to one divider form one undo entry. An undo that removes a created pane opens a confirmation prompt; type `CONFIRM` to remove its tab placements and commit the undo. Session-owned PTY terminals remain alive, while single-view browser tabs close. Closing a pane directly clears that screen's undo history because the journal cannot reconstruct its exact tab membership or a closed browser target.

On a primary screen, `Cmd-k` clears retained scrollback and completed visible rows inside the terminal emulator. OSC 133 prompt metadata preserves the complete active prompt. Without metadata, cmux-tui preserves visible rows because it cannot identify the active input boundary. The edit buffer and cursor stay in place, and cmux-tui sends no input to the shell. In alternate-screen applications, `Cmd-k` is forwarded to the application. `Ctrl-l` remains child-owned on every screen, so shells, REPLs, and other terminal applications keep their standard clear/redraw behavior and custom bindings.

The screen bindings intentionally match tmux: `c` creates a screen, `n` and `p` switch screens, `&` closes a screen, `,` renames a screen, `z` zooms a pane, `o` cycles panes, `{` and `}` swap panes, and number keys select visible screens. Screens are numbered from 0, so `Ctrl-b 0` selects screen 0 and `Ctrl-b 1` selects screen 1.

Workspace navigation follows tmux's outer session lane: `(` and `)` move backward and forward. `w` remains a next-workspace alias for compatibility, while the sidebar provides the visible mouse and keyboard picker. `Alt-{` and `Alt-}` mirror the modeless screen lane on `Alt-[` and `Alt-]`. `W` creates a workspace and `D` closes it.

`Ctrl-b x` closes the active tab because tab lifecycle is the more frequent cmux action. `Ctrl-b X` closes its containing pane. Rebind either action independently with `keys.close-tab` and `keys.close-pane`.

`Ctrl-b ]` is unbound because cmux has no paste-buffer concept. `Ctrl-b q` is unbound because there is no pane-number quick-jump overlay yet.

## Focused Sidebar

When the built-in sidebar is focused, its divider becomes a bold accent rail. `Tab` toggles files/workspaces without leaving sidebar focus. In the files view, Up/Down and Ctrl-J/Ctrl-K move the selection, Right descends into a directory, Enter descends or opens a file in a new `$EDITOR` tab, and Left or `h` goes to the parent when the machine rail is absent. `c` sends a safely quoted `cd` to the focused pane, `o` opens `.html` and `.md` files in a browser tab, `.` toggles dotfiles, `/` enters filter mode, and `~` follows the focused pane cwd again. Esc clears a nonempty filter before leaving filter mode.

In the workspaces view, Up/Down or `j`/`k` move the selection and preview that workspace in the pane area without changing the client focus. Enter commits the preview and focuses the pane. Esc cancels the preview and restores both the workspace and pane focus that were active before navigation. A one-level `tabs` view follows the highlighted workspace. Multi-level views such as `workspaces → agents` are collapsible trees: Left collapses, Right expands, Space toggles, and Enter activates the exact workspace, pane, tab, or agent surface. Alt/Option with arrows or `hjkl` always navigates, so Alt-Left and Alt-Right traverse views instead of changing tree expansion. Right from the final view or Esc returns to the pane. Any normal prefixed command leaves sidebar focus and runs through the usual action table. A configured sidebar plugin keeps its existing PTY forwarding behavior.

When the optional machine rail is visible, `Ctrl-b S` enters through the first view containing workspaces. Alt/Option-Left or Alt/Option-`h` at the left pane boundary enters the rightmost visible view. Left or `h` and Right or `l` traverse the ordered native views. Up/Down or `k`/`j` changes the selected machine, Enter connects to it, `m` opens the provider scope/actions menu when the provider offers one, and Esc returns to the active pane. Clicking a view's one-row top pad focuses it without activating a row. Clicking a machine, workspace, pane, tab, or agent activates it and returns keyboard input to the latest terminal. Sidebar views swallow other unprefixed keys instead of forwarding them to a remote terminal.

## Modeless Alt Layer

Any configured Alt chord is active without the prefix. Default modeless commands are `Alt-t`, `Alt-n`, `Alt-[`, `Alt-]`, `Alt-{`, `Alt-}`, `Alt-h/j/k/l`, Alt arrows, `Alt-=`, and `Alt--`. `Alt-n` follows Zellij's default auto-layout sequence inside the focused horizontal column: one full-height left pane and up to four right-side rows, balanced columns of four through twelve panes, then one full-height left pane beside a right-side stack with the focused stack pane expanded. A screen without horizontal columns is one implicit column, preserving the previous whole-screen behavior.

Set `keys.alt_shortcuts` to `false` to remove the default Alt bindings. This kill switch only removes defaults; Alt chords explicitly configured in `cmux-tui.json` still work.

Kitty keyboard cannot distinguish a real Alt character chord from an empty-text macOS Option dead-key prefix. `keys.macos_option_as_alt` selects that input mode explicitly and defaults to `true`. Set it to `false` when the host terminal uses Option for composition. Nonempty Option-generated text remains authoritative in either mode and never triggers an Alt binding.

Zellij's modal `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are a deliberate non-goal because they conflict with common shell and editor control keys such as history, transpose, flow control, and editor navigation.

## Modeless Command/Super Layer

`Cmd-k` / `Super-k` clears prior PTY output inside the terminal emulator while preserving active input. `Ctrl-l` is forwarded to the foreground application. cmux-tui enables the Kitty keyboard protocol so compatible hosts report the Command/Super modifier. Host-owned shortcuts such as `Cmd-t`, `Cmd-w`, and `Cmd-d` remain unbound because terminals consume them before a nested TUI can receive them. Their working cmux-tui equivalents are `Alt-t`, `Ctrl-b X`, and `Ctrl-b %`.

Set `keys.super_shortcuts` to `false` to remove the default Command/Super bindings. Explicit `cmd+...`, `command+...`, and `super+...` bindings still work.

## Number Selection

`0` through `9` are regular configurable screen-selection bindings. Zero-based tab selectors are available as `select-tab-0` through `select-tab-9`; they are unbound by default because the number keys select screens.

## Remapping

Keys are read from `~/.config/cmux/cmux-tui.json`, with legacy `mux.json` used when the new file is absent. `CMUX_TUI_CONFIG` overrides the path; `CMUX_MUX_CONFIG` remains as a legacy fallback.

Each action accepts a string, an array of strings, or `"none"`. Setting an action replaces all default chords for that action before adding the configured chords. `"none"` leaves the action unbound.

User commands from the top-level `commands` config section bind through the same chord grammar and appear in the `Ctrl-b ?` shortcut modal under their configured names. A command chord replaces whatever action previously held that chord. See [Configuration](configuration.md#commands).

```json
{
  "keys": {
    "prefix": "ctrl+a",
    "macos_option_as_alt": true,
    "alt_shortcuts": false,
    "super_shortcuts": false,
    "new-tab": ["t", "alt+t", "cmd+t"],
    "new-pane-smart": "alt+n",
    "select-screen-0": "0",
    "select-screen-1": "1",
    "next-screen": ["n", "alt+]"],
    "prev-screen": ["p", "alt+["],
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "rename-tab": "r",
    "rename-screen": ",",
    "close-tab": "x",
    "close-pane": "X",
    "show-shortcuts": "?",
    "select-tab-0": "none"
  }
}
```

Supported action keys are:

```text
send-prefix
new-tab
new_browser_tab
new-pane-smart
next-tab
prev-tab
select-tab-0
select-tab-1
select-tab-2
select-tab-3
select-tab-4
select-tab-5
select-tab-6
select-tab-7
select-tab-8
select-tab-9
split-right
split-down
close-tab
close-pane
rename-tab
rename-screen
rename-workspace
close-screen
prev-screen
next-screen
select-screen-0
select-screen-1
select-screen-2
select-screen-3
select-screen-4
select-screen-5
select-screen-6
select-screen-7
select-screen-8
select-screen-9
new-screen
prev-workspace
next-workspace
new-workspace
close-workspace
toggle-sidebar
toggle-sidebar-compact
toggle-sidebar-view
focus-sidebar
provider-menu
new-pane-right
undo-layout
focus-left
focus-right
focus-up
focus-down
focus-next-pane
swap-pane-prev
swap-pane-next
zoom-pane
resize-grow
resize-shrink
scroll-up
scroll-down
clear-history
browser-back
browser-forward
browser-reload
browser-edit-url
show-shortcuts
detach
```

`rename-pane` is still accepted as an alias for `rename-tab`.

## Chord Format

Chord strings are case-sensitive for single characters. Uppercase letters and symbols represent the shifted character.

Supported examples include `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"cmd+k"`, `"super+shift+d"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.
