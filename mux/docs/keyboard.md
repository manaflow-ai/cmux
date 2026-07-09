# Keyboard

## Prefix Model

`cmux-mux` uses a tmux-style prefix. The default prefix is `Ctrl-b`. After the prefix, the next key is interpreted as a mux command. Pressing the prefix twice sends a literal `Ctrl-b` to the active surface.

Unknown prefixed keys are swallowed. Unprefixed non-Alt keys go to the active surface. Alt chords that are bound in the key table are modeless commands by default.

## Default Bindings

These defaults come from `Keys::default`.

| Binding | Action |
| --- | --- |
| `Ctrl-b t` | New PTY tab in the active pane |
| `Alt-t` | New PTY tab in the active pane |
| `Ctrl-b B` | Open the browser-tab URL prompt |
| `Alt-n` | Smart split into a new pane |
| `Ctrl-b Tab` | Next tab in the active pane |
| `Ctrl-b BackTab` | Previous tab in the active pane |
| `Ctrl-b 1` through `Ctrl-b 9` | Select visible screen 1 through 9 |
| `Ctrl-b 0` | Select visible screen 10 |
| `Ctrl-b %` | Split the active pane right |
| `Ctrl-b "` | Split the active pane down |
| `Ctrl-b x` | Close the active pane |
| `Ctrl-b X` | Close the active tab |
| `Ctrl-b ,` | Rename the active screen |
| `Ctrl-b $` | Rename the active workspace |
| `Ctrl-b &` | Close the active screen |
| `Ctrl-b p` | Previous screen in the active workspace |
| `Alt-[` | Previous screen in the active workspace |
| `Ctrl-b n` | Next screen in the active workspace |
| `Alt-]` | Next screen in the active workspace |
| `Ctrl-b c` | New screen in the active workspace |
| `Ctrl-b z` | Toggle zoom for the active pane |
| `Ctrl-b o` | Focus the next pane in the current screen |
| `Ctrl-b {` | Swap the active pane with the previous pane |
| `Ctrl-b }` | Swap the active pane with the next pane |
| `Ctrl-b w` | Next workspace |
| `Ctrl-b W` | New workspace |
| `Ctrl-b s` | Toggle the workspace sidebar |
| `Ctrl-b h` or `Ctrl-b Left` | Focus left |
| `Alt-h` or `Alt-Left` | Focus left |
| `Ctrl-b l` or `Ctrl-b Right` | Focus right |
| `Alt-l` or `Alt-Right` | Focus right |
| `Ctrl-b k` or `Ctrl-b Up` | Focus up |
| `Alt-k` or `Alt-Up` | Focus up |
| `Ctrl-b j` or `Ctrl-b Down` | Focus down |
| `Alt-j` or `Alt-Down` | Focus down |
| `Alt-=` | Grow the focused split |
| `Alt--` | Shrink the focused split |
| `Ctrl-b [` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageUp` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageDown` | Scroll the active PTY viewport down 10 rows |
| `Ctrl-b d` | Quit a local TUI or detach an attached TUI |

The screen bindings intentionally use tmux verbs: `c` creates a screen, `n` and `p` switch screens, `&` closes a screen, `,` renames a screen, `z` zooms a pane, `o` cycles panes, `{` and `}` swap panes, and number keys select visible screens. Screens are visibly numbered from 1, so `Ctrl-b 1` selects the first visible screen and `Ctrl-b 0` selects the tenth visible screen.

`Ctrl-b x` now follows tmux and closes the active pane. `Ctrl-b X` closes the active tab. Restore the old cmux behavior with `"close-tab": "x"` and `"close-pane": "X"` in `mux.json`.

`Ctrl-b ]` is unbound because cmux has no paste-buffer concept. `Ctrl-b q` is unbound because there is no pane-number quick-jump overlay yet.

## Modeless Alt Layer

Any configured Alt chord is active without the prefix. Default modeless commands are `Alt-t`, `Alt-n`, `Alt-[`, `Alt-]`, `Alt-h/j/k/l`, Alt arrows, `Alt-=`, and `Alt--`. `Alt-n` is the default zellij-style smart split binding.

Set `keys.alt_shortcuts` to `false` to remove the default Alt bindings. This kill switch only removes defaults; Alt chords explicitly configured in `mux.json` still work.

Zellij's modal `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are a deliberate non-goal because they conflict with common shell and editor control keys such as history, transpose, flow control, and editor navigation.

## Number Selection

`0` through `9` are regular configurable screen-selection bindings. The old `Ctrl-b 1` through `Ctrl-b 9` tab selectors can be restored with `select-tab-1` through `select-tab-9`.

## Remapping

Keys are read from `~/.config/cmux/mux.json`, or from the file named by `CMUX_MUX_CONFIG`.

Each action accepts a string, an array of strings, or `"none"`. Setting an action replaces all default chords for that action before adding the configured chords. `"none"` leaves the action unbound.

```json
{
  "keys": {
    "prefix": "ctrl+a",
    "alt_shortcuts": false,
    "new-tab": ["t", "alt+t"],
    "new-pane-smart": "alt+n",
    "select-screen-1": "1",
    "select-screen-2": "2",
    "next-screen": ["n", "alt+]"],
    "prev-screen": ["p", "alt+["],
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "rename-tab": "r",
    "rename-screen": ",",
    "close-pane": "x",
    "close-tab": "X",
    "select-tab-1": "none"
  }
}
```

Supported action keys are:

```text
new-tab
new_browser_tab
new-pane-smart
next-tab
prev-tab
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
next-workspace
new-workspace
toggle-sidebar
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
browser-back
browser-forward
browser-reload
browser-edit-url
detach
```

`rename-pane` is still accepted as an alias for `rename-tab`.

## Chord Format

Chord strings are case-sensitive for single characters. Uppercase letters and symbols represent the shifted character.

Supported examples include `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.
