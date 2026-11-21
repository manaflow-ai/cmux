# Keyboard

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
| `Ctrl-b N` or `Alt-n` | Create a pane with Zellij's default auto-layout in the focused horizontal column |
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
| `Ctrl-b a` | Go to the next tab that needs you: a blocked agent, then an unread error or warning, then another unread tab |
| `Ctrl-b A` | Open a searchable list of the tabs that need you; Enter goes to the selected tab |
| `Ctrl-b h` or `Ctrl-b Left` | Focus left |
| `Alt-h` or `Alt-Left` | Focus left |
| `Ctrl-b l` or `Ctrl-b Right` | Focus right |
| `Alt-l` or `Alt-Right` | Focus right |
| `Ctrl-b k` or `Ctrl-b Up` | Focus up |
| `Alt-k` or `Alt-Up` | Focus up |
| `Ctrl-b j` or `Ctrl-b Down` | Focus down |
| `Alt-j` or `Alt-Down` | Focus down |
| `Ctrl-b +` or `Alt-=` | Grow the focused split, or its horizontal viewport column |
| `Ctrl-b -` or `Alt--` | Shrink the focused split, or its horizontal viewport column |
| `Ctrl-b [` | Enter copy mode on the active terminal |
| `Ctrl-b /` | Enter copy mode and search the scrollback backward |
| `Ctrl-b PageUp` | Scroll the active PTY viewport up one page |
| `Ctrl-b PageDown` | Scroll the active PTY viewport down one page |
| `Cmd-k` / `Super-k` | Clear retained PTY history and completed visible rows while preserving active input |
| `Ctrl-b d` | Quit a local TUI or detach an attached TUI |

Press `Ctrl-b`, release it, then press the suffix. `N` is uppercase and `+` is the plus character (Shift-Equal on a US keyboard). Lowercase `Ctrl-b n` still selects the next screen. Every default Alt action also has a prefix binding, including when `keys.alt_shortcuts` is `false`.

`Ctrl-b a` visits the tabs in the order `cmux attention next` answers: tabs whose agent waits on you (`blocked`) first, then tabs with an unread `error` or `warning` notification, then other unread tabs, each oldest first. A blocked tab stays in the queue after you look at it, so repeated presses cycle through all of them. An unread tab stays in the queue until its notification is cleared. When nothing needs you, a toast says so. See [Notifications](configuration.md#notifications).

Directional focus follows Zellij's pane memory: when several panes share the requested edge, cmux-tui returns to the pane focused most recently.

When a screen is wider than the viewport, `h`/`l`, Left/Right, and their modeless Alt bindings reveal the focused pane. The viewport movement is animated unless `viewport.animation` is false.

On a screen created with `Ctrl-b g`, `Ctrl-b +` / `Alt-=` and `Ctrl-b -` / `Alt--` resize the complete horizontal column containing the focused pane in five-percent steps. On an ordinary screen they retain their existing split-resize behavior.

`Ctrl-b U` undoes the latest pane creation, split resize, column resize, swap, zoom, or automatic-layout change on the focused screen. Repeated resize updates to one divider form one undo entry. An undo that removes a created pane opens a confirmation prompt; type `CONFIRM` to remove its tab placements and commit the undo. Session-owned PTY terminals remain alive, while single-view browser tabs close. Closing a pane directly clears that screen's undo history because the journal cannot reconstruct its exact tab membership or a closed browser target.

On a primary screen, `Cmd-k` clears retained scrollback and completed visible rows inside the terminal emulator. OSC 133 prompt metadata preserves the complete active prompt. Without metadata, cmux-tui preserves visible rows because it cannot identify the active input boundary. The edit buffer and cursor stay in place, and cmux-tui sends no input to the shell. In alternate-screen applications, `Cmd-k` is forwarded to the application. `Ctrl-l` remains child-owned on every screen, so shells, REPLs, and other terminal applications keep their standard clear/redraw behavior and custom bindings.

The screen bindings intentionally match tmux: `c` creates a screen, `n` and `p` switch screens, `&` closes a screen, `,` renames a screen, `z` zooms a pane, `o` cycles panes, `{` and `}` swap panes, and number keys select visible screens. Screens are numbered from 0, so `Ctrl-b 0` selects screen 0 and `Ctrl-b 1` selects screen 1.

Workspace navigation follows tmux's outer session lane: `(` and `)` move backward and forward. `w` remains a next-workspace alias for compatibility, while the sidebar provides the visible mouse and keyboard picker. `Alt-{` and `Alt-}` mirror the modeless screen lane on `Alt-[` and `Alt-]`. `W` creates a workspace and `D` closes it.

`Ctrl-b x` closes the active tab because tab lifecycle is the more frequent cmux action. `Ctrl-b X` closes its containing pane. Rebind either action independently with `keys.close-tab` and `keys.close-pane`.

`Ctrl-b ]` is unbound because cmux has no paste-buffer concept. `Ctrl-b q` is unbound because there is no pane-number quick-jump overlay yet.

## Copy Mode

`Ctrl-b [` enters copy mode on the active terminal. `Ctrl-b /` enters copy mode with the backward search prompt open. A copy cursor starts at the terminal cursor, and the status row shows the mode, the search count, the cursor row out of all retained rows, and short key hints. Copy mode moves only this client's view of the terminal. Keys that copy mode does not bind are discarded, so nothing reaches the shell until copy mode ends. The prefix still works, so `Ctrl-b ?` and other prefix commands stay available. Mouse wheel scrolling stays passive and does not enter copy mode.

| Key | Command |
|---|---|
| `h` `j` `k` `l` or arrows | Move the cursor one cell or row |
| `w` `b` `e` | Next word start, previous word start, word end |
| `W` `B` `E` | The same motions over whitespace-separated words |
| `0` or `Home`, `^`, `$` or `End` | Line start, first non-blank character, line end |
| `g` `G` | Top of history, bottom of the terminal |
| `H` `M` `L` | Top, middle, bottom row of the view |
| `Ctrl-u` `Ctrl-d` | Half page up, half page down |
| `PageUp`, `PageDown` or `Ctrl-f` | Page up, page down |
| `Ctrl-y` `Ctrl-e` | Scroll the view one row and keep the cursor in view |
| `v` or `Space`, `V`, `Ctrl-v` | Start or stop a character, line, or block selection |
| `o` | Move the cursor to the other end of the selection |
| `y` or `Enter` | Copy the selection and leave copy mode |
| `Y` | Copy the logical line under the cursor and leave copy mode |
| `/` `?` | Search forward, search backward |
| `n` `N` | Next match, previous match in the search direction |
| `Esc` | Clear the selection, then the search, then leave copy mode |
| `q` or `Ctrl-c` | Leave copy mode |

Motions treat a wide character as one cell. A copy joins soft-wrapped rows into one line and keeps hard line breaks. A block selection copies the same columns from each row. The copy goes to the system clipboard through OSC 52, as a mouse selection does. Leaving copy mode returns the view to the live bottom.

Search is smart-case: a needle with no uppercase letter matches any case, and a needle with an uppercase letter matches case exactly. Search covers all retained scrollback, highlights every match in the view, marks the current match, and shows its position as `3/17`. `n` and `N` wrap around at the ends of history. Pressing `Enter` on an empty prompt repeats the previous search in the prompt's direction. A count ends in `+` when more than 10,000 matches exist; only the newest 10,000 are kept.

Search matches the text as it shows on the screen. When a search ignores case, only ASCII letters fold; other characters match exactly. A match can continue across a soft-wrapped row, but never across a hard line break. Each search reads the retained screen once when you press `Enter`, `n`, or `N`; it does not run while you type in the prompt or while the terminal draws. This build reads the screen text in Rust because its libghostty-vt has no search API. The `feat-cmux-next` builds use libghostty-vt's own search; the keys, highlights, and counts are the same.

Remap copy-mode commands with the `keys.copy_mode` object. Each command accepts a string, an array of strings, or `"none"`, and replaces that command's default keys. A chord given to one command is removed from every other copy-mode command. A copy-mode chord equal to the prefix is ignored.

```json
{
  "keys": {
    "copy-mode": "[",
    "search-scrollback": "/",
    "copy_mode": {
      "select-char": ["v", "space"],
      "yank": ["y", "enter", "ctrl+w"],
      "exit": ["q", "ctrl+c"]
    }
  }
}
```

Copy-mode command names are:

```text
cursor-left
cursor-right
cursor-up
cursor-down
word-next
word-prev
word-end
bigword-next
bigword-prev
bigword-end
line-start
line-first-non-blank
line-end
history-top
history-bottom
view-top
view-middle
view-bottom
half-page-up
half-page-down
page-up
page-down
scroll-line-up
scroll-line-down
select-char
select-line
select-block
swap-selection-end
yank
yank-line
search-forward
search-backward
search-next
search-prev
cancel
exit
```

`scroll-page-up`, `scroll-page-down`, `scroll-half-page-up`, and `scroll-half-page-down` scroll the active terminal outside copy mode by one or half a visible page. `scroll-up` and `scroll-down` still scroll 10 rows and are unbound by default.

## Focused Sidebar

When the built-in sidebar is focused, its divider becomes a bold accent rail. `Tab` toggles files/workspaces without leaving sidebar focus. In the files view, Up/Down and Ctrl-J/Ctrl-K move the selection, Right descends into a directory, Enter descends or opens a file in a new `$EDITOR` tab, and Left or `h` goes to the parent when the machine rail is absent. `c` sends a safely quoted `cd` to the focused pane, `o` opens `.html` and `.md` files in a browser tab, `.` toggles dotfiles, `/` enters filter mode, and `~` follows the focused pane cwd again. Esc clears a nonempty filter before leaving filter mode.

In the workspaces view, Up/Down move the selection and Enter activates it. A one-level `tabs` view follows the highlighted workspace. Multi-level views such as `workspaces → agents` are collapsible trees: Left collapses, Right expands, Space toggles, and Enter activates the exact workspace, pane, tab, or agent surface. Alt/Option with arrows or `hjkl` always navigates, so Alt-Left and Alt-Right traverse views instead of changing tree expansion. Right from the final view or Esc returns to the pane. Any normal prefixed command leaves sidebar focus and runs through the usual action table. A configured sidebar plugin keeps its existing PTY forwarding behavior.

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
    "new-pane-smart": ["alt+n", "N"],
    "resize-grow": ["alt+=", "shift+="],
    "resize-shrink": ["alt+-", "-"],
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
scroll-page-up
scroll-page-down
scroll-half-page-up
scroll-half-page-down
copy-mode
search-scrollback
clear-history
browser-back
browser-forward
browser-reload
browser-edit-url
show-shortcuts
next-attention
attention-list
detach
```

`rename-pane` is still accepted as an alias for `rename-tab`.

## Chord Format

Chord strings are case-sensitive for single characters. Uppercase letters and symbols represent the shifted character.

Supported examples include `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"cmd+k"`, `"super+shift+d"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.
