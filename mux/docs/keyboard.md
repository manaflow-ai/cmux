# Keyboard

## Prefix model

`cmux-mux` uses a tmux-style prefix. The default prefix is `Ctrl-b`. After the prefix, the next key is interpreted as a mux command. Pressing the prefix twice sends a literal `Ctrl-b` to the active surface.

Unknown prefixed keys are swallowed. Unprefixed keys go to the active surface.

## Default bindings

These defaults come from `Keys::default`:

| Binding | Action |
| --- | --- |
| `Ctrl-b c` | New PTY tab in the active pane |
| `Ctrl-b B` | Open the browser-tab URL prompt |
| `Ctrl-b n` | Next tab in the active pane |
| `Ctrl-b p` | Previous tab in the active pane |
| `Ctrl-b 1` through `Ctrl-b 9` | Select tab 1 through 9 in the active pane |
| `Ctrl-b %` | Split the active pane right |
| `Ctrl-b "` | Split the active pane down |
| `Ctrl-b x` | Close the active tab |
| `Ctrl-b ,` | Rename the active tab |
| `Ctrl-b $` | Rename the active workspace |
| `Ctrl-b Tab` | Next screen in the active workspace |
| `Ctrl-b S` | New screen in the active workspace |
| `Ctrl-b w` | Next workspace |
| `Ctrl-b W` | New workspace |
| `Ctrl-b s` | Toggle the workspace sidebar |
| `Ctrl-b h` or `Ctrl-b Left` | Focus left |
| `Ctrl-b l` or `Ctrl-b Right` | Focus right |
| `Ctrl-b k` or `Ctrl-b Up` | Focus up |
| `Ctrl-b j` or `Ctrl-b Down` | Focus down |
| `Ctrl-b PageUp` | Scroll the active PTY viewport up 10 rows |
| `Ctrl-b PageDown` | Scroll the active PTY viewport down 10 rows |
| `Ctrl-b d` | Quit a local TUI or detach an attached TUI |

The fixed `1` through `9` tab selectors are not configured through `mux.json`; they mirror tab labels.

## Remapping

All prefix actions except fixed `1` through `9` can be remapped in `~/.config/cmux/mux.json`, or in the file named by `CMUX_MUX_CONFIG`.

```json
{
  "keys": {
    "prefix": "ctrl+a",
    "new-tab": "c",
    "new_browser_tab": "B",
    "next-tab": "n",
    "prev-tab": "p",
    "split-right": "%",
    "split-down": "\"",
    "close-tab": "x",
    "rename-tab": ",",
    "rename-workspace": "$",
    "next-screen": "tab",
    "new-screen": "S",
    "next-workspace": "w",
    "new-workspace": "W",
    "toggle-sidebar": "s",
    "focus-left": "h",
    "focus-right": "l",
    "focus-up": "k",
    "focus-down": "j",
    "scroll-up": "pageup",
    "scroll-down": "pagedown",
    "detach": "d"
  }
}
```

Config overrides replace all default chords for that action. For example, remapping `focus-left` removes both default `h` and `Left`.

Chord strings are case-sensitive for single characters. Supported formats include `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.

`rename-pane` is still accepted as an alias for `rename-tab`.
