# Configuration

`cmux-mux` reads `~/.config/cmux/mux.json`. Set `CMUX_MUX_CONFIG` to use another file. Every documented key is optional. Unknown keys at any level make the raw config invalid, so the TUI logs an error and falls back to defaults.

Colors accept `#rrggbb`, `#rgb`, an xterm-256 number, or a numeric string.

## Reference

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `theme.selection_background` | color | `#3a3a3a`, seeded from Ghostty when present | Selection background in PTY panes |
| `theme.selection_foreground` | color or null | `null`, seeded from Ghostty when present | Selection foreground; `null` preserves each cell's foreground |
| `theme.sidebar_rail` | color | `110` | Rail color for the active workspace rows |
| `theme.sidebar_active_bg` | color | `236` | Background for the active workspace rows |
| `theme.tab_rail` | color | `110` | Rail color inside the active tab chip |
| `theme.tab_bg` | color | `236` | Background for inactive solid tab chips |
| `theme.tab_active_bg` | color or null | `null` | Overrides the focused and unfocused active-tab chip backgrounds |
| `theme.border_active` | color | `110` | Focused pane border |
| `theme.border_inactive` | color | `238` | Unfocused pane border |
| `tabs.min_width` | integer | `7` | Minimum tab label width, clamped to 3 through 40 |
| `tabs.solid_background` | boolean | `true` | Renders tab chips with solid backgrounds |
| `tabs.show_titles` | boolean | `false` | Shows full process titles after tab numbers |
| `tabs.agents` | string array | `["claude","codex","opencode","pi"]` | Agent names surfaced in tab labels when `show_titles` is false |
| `sidebar.width` | integer | `22` | Sidebar width, clamped to 10 through 60 |
| `browser.chrome_binary` | string | `null` | Chrome/Chromium binary to launch when no external CDP endpoint is used |
| `browser.cdp_url` | string | `null` | External CDP endpoint, accepted as `http://host:port` or `ws://...` |
| `browser.discover` | boolean | `true` | Probe discovery ports before launching Chrome |
| `browser.discover_ports` | integer array | `[9222]` | Local ports to probe for `/json/version` |
| `browser.user_data_dir` | string | `null` | Persistent profile directory for launched Chrome |
| `browser.ephemeral` | boolean | `false` | Use a temporary launched Chrome profile and delete it on shutdown |
| `scrollbar.position` | `"column"` or `"border"` | `"column"` | Dedicated scrollbar column or right-border overlay |
| `keys.prefix` | chord string | `"ctrl+b"` | Prefix chord |
| `keys.new-tab` | chord string | `"c"` | New PTY tab |
| `keys.new_browser_tab` | chord string | `"B"` | Browser URL prompt |
| `keys.next-tab` | chord string | `"n"` | Next tab |
| `keys.prev-tab` | chord string | `"p"` | Previous tab |
| `keys.split-right` | chord string | `"%"` | Split right |
| `keys.split-down` | chord string | `"\""` | Split down |
| `keys.close-tab` | chord string | `"x"` | Close active tab |
| `keys.rename-tab` | chord string | `","` | Rename active tab |
| `keys.rename-pane` | chord string | alias | Alias for `rename-tab` |
| `keys.rename-workspace` | chord string | `"$"` | Rename active workspace |
| `keys.next-screen` | chord string | `"tab"` | Next screen |
| `keys.new-screen` | chord string | `"S"` | New screen |
| `keys.next-workspace` | chord string | `"w"` | Next workspace |
| `keys.new-workspace` | chord string | `"W"` | New workspace |
| `keys.toggle-sidebar` | chord string | `"s"` | Toggle sidebar |
| `keys.focus-left` | chord string | `"h"` and `Left` by default | Focus left; config can bind only one chord |
| `keys.focus-right` | chord string | `"l"` and `Right` by default | Focus right; config can bind only one chord |
| `keys.focus-up` | chord string | `"k"` and `Up` by default | Focus up; config can bind only one chord |
| `keys.focus-down` | chord string | `"j"` and `Down` by default | Focus down; config can bind only one chord |
| `keys.scroll-up` | chord string | `"pageup"` | Scroll active PTY up 10 rows |
| `keys.scroll-down` | chord string | `"pagedown"` | Scroll active PTY down 10 rows |
| `keys.detach` | chord string | `"d"` | Quit local TUI or detach attached TUI |

Selection colors are resolved in this order: explicit `mux.json`, Ghostty config keys `selection-background` and `selection-foreground`, then built-in defaults. Ghostty configs are read from `~/.config/ghostty/config` and `~/Library/Application Support/com.mitchellh.ghostty/config`; later entries in the file win.

When `browser.ephemeral` is true, it takes precedence over `browser.user_data_dir`: launched Chrome uses a fresh temporary profile, and the configured directory is not deleted.

## Chords

Chord strings can be single characters or a key name with optional `ctrl`, `control`, `alt`, `option`, or `shift` modifiers. Examples: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.

Single-character chords are case-sensitive. Uppercase letters and symbols represent the shifted character.

## Example

```json
{
  "theme": {
    "selection_background": "#355c7d",
    "selection_foreground": null,
    "sidebar_rail": "#87afd7",
    "sidebar_active_bg": 236,
    "tab_rail": "#87afd7",
    "tab_bg": 236,
    "tab_active_bg": null,
    "border_active": "#87afd7",
    "border_inactive": "#444444"
  },
  "tabs": {
    "min_width": 9,
    "solid_background": true,
    "show_titles": false,
    "agents": ["claude", "codex", "opencode", "pi"]
  },
  "sidebar": {
    "width": 24
  },
  "browser": {
    "chrome_binary": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "cdp_url": "http://127.0.0.1:9222",
    "discover": true,
    "discover_ports": [9222, 9223],
    "user_data_dir": "/Users/me/Library/Application Support/cmux-mux/chrome-profile",
    "ephemeral": false
  },
  "scrollbar": {
    "position": "column"
  },
  "keys": {
    "prefix": "ctrl+a",
    "new-tab": "c",
    "new_browser_tab": "B",
    "split-right": "%",
    "split-down": "\"",
    "detach": "d"
  }
}
```
