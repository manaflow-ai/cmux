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
| `Ctrl-b 1` through `Ctrl-b 9` | Select tab 1 through 9 in the active pane |
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
| `Ctrl-b PageUp` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageDown` | Scroll the active PTY viewport down 10 rows |
| `Ctrl-b d` | Quit a local TUI or detach an attached TUI |

The screen bindings intentionally use tmux verbs: `c` creates a screen, `n` and `p` switch screens, `&` closes a screen, and `,` renames a screen. Tabs use `t`, `Tab`, `BackTab`, fixed number selectors, and tab-bar mouse actions.

## Modeless Alt Layer

Any configured Alt chord is active without the prefix. Default modeless commands are `Alt-t`, `Alt-n`, `Alt-[`, `Alt-]`, `Alt-h/j/k/l`, Alt arrows, `Alt-=`, and `Alt--`. `Alt-n` is the default zellij-style smart split binding.

Set `keys.alt_shortcuts` to `false` to remove the default Alt bindings. This kill switch only removes defaults; Alt chords explicitly configured in `mux.json` still work.

## Fixed Number Selection

`1` through `9` select tabs by visible tab number after the prefix. These number bindings are fixed and are not configured through `mux.json`.

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
    "next-screen": ["n", "alt+]"],
    "prev-screen": ["p", "alt+["],
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "rename-tab": "r",
    "rename-screen": ",",
    "close-pane": "none"
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
new-screen
next-workspace
new-workspace
toggle-sidebar
focus-left
focus-right
focus-up
focus-down
resize-grow
resize-shrink
scroll-up
scroll-down
detach
```

`rename-pane` is still accepted as an alias for `rename-tab`.

## Chord Format

Chord strings are case-sensitive for single characters. Uppercase letters and symbols represent the shifted character.

Supported examples include `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.
