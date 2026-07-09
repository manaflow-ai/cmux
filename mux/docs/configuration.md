# Configuration

`cmux-mux` reads `~/.config/cmux/mux.json`, or `$XDG_CONFIG_HOME/cmux/mux.json` when `XDG_CONFIG_HOME` is set. Set `CMUX_MUX_CONFIG` to use another file; it takes precedence over both. Every documented key is optional. Unknown keys in the typed sections make the raw config invalid, so the TUI logs an error and falls back to defaults.

Colors accept `#rrggbb`, `#rgb`, an xterm-256 number, or a numeric string.

## Theme

Selection colors are resolved in this order: explicit `mux.json`, Ghostty config keys `selection-background` and `selection-foreground`, then built-in defaults. Ghostty configs are read from `$XDG_CONFIG_HOME/ghostty/config` (when set), `~/.config/ghostty/config`, and on macOS `~/Library/Application Support/com.mitchellh.ghostty/config`; later entries in the file win.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `theme.selection_background` | color | `#3a3a3a`, seeded from Ghostty when present | Selection background in PTY panes |
| `theme.selection_foreground` | color or null | `null`, seeded from Ghostty when present | Selection foreground; `null` keeps each cell's foreground |
| `theme.sidebar_rail` | color | `110` | Rail color for the active workspace rows |
| `theme.sidebar_active_bg` | color | `236` | Background for the active workspace rows |
| `theme.tab_rail` | color | `110` | Rail color inside the active tab chip |
| `theme.tab_bg` | color | `236` | Background for inactive solid tab chips |
| `theme.tab_active_bg` | color or null | `null` | Overrides the focused and unfocused active-tab chip backgrounds |
| `theme.border_active` | color | `110` | Focused pane border |
| `theme.border_inactive` | color | `238` | Unfocused pane border |
| `theme.notification_info` | color | `110` | Info notification attention dot and border |
| `theme.notification_warning` | color | `179` | Warning notification attention dot and border |
| `theme.notification_error` | color | `167` | Error notification attention dot and border |

## Tabs

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `tabs.min_width` | integer | `7` | Minimum tab label width, clamped to 3 through 40 |
| `tabs.solid_background` | boolean | `true` | Renders tab chips with solid backgrounds |
| `tabs.show_titles` | boolean | `false` | Shows full process titles after tab numbers |
| `tabs.agents` | string array | `["claude","codex","opencode","pi"]` | Agent names surfaced in tab labels when `show_titles` is false |

Tabs are numbered by default. A recognized agent program can appear after the number. A user-assigned tab name replaces the generated label.

## Sidebar

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `sidebar.width` | integer | `22` | Sidebar width, clamped to 10 through 60 on load |
| `sidebar.max_width` | integer | `0` | Maximum live drag width; `0` means no configured maximum |

Live sidebar dragging also leaves at least 40 columns for pane content.

## Browser

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `browser.chrome_binary` | string | `null` | Chrome/Chromium binary to launch when no external CDP endpoint is used |
| `browser.cdp_url` | string | `null` | External CDP endpoint, accepted as `http://host:port` or `ws://...` |
| `browser.discover` | boolean | `true` | Probe discovery ports before launching Chrome |
| `browser.discover_ports` | integer array | `[9222]` | Local ports to probe for `/json/version` |
| `browser.user_data_dir` | string | `null` | Persistent profile directory for launched Chrome |
| `browser.ephemeral` | boolean | `false` | Use a temporary launched Chrome profile and delete it on shutdown |

When `browser.ephemeral` is true, it takes precedence over `browser.user_data_dir`: launched Chrome uses a fresh temporary profile, and the configured directory is not deleted.

The default launched profile is `~/Library/Application Support/cmux-mux/chrome-profile` on macOS. On non-macOS targets it is `$XDG_DATA_HOME/cmux-mux/chrome-profile` when `XDG_DATA_HOME` is set, then `~/.local/share/cmux-mux/chrome-profile`.

## Scrollbar

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `scrollbar.position` | `"column"` or `"border"` | `"column"` | Dedicated scrollbar column or right-border overlay |

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `keys.prefix` | chord string | `"ctrl+b"` | Prefix chord |
| `keys.alt_shortcuts` | boolean | `true` | Enables default modeless Alt bindings when true |
| `keys.new-tab` | chord string or array or `"none"` | `["t","alt+t"]` | New PTY tab |
| `keys.new_browser_tab` | chord string or array or `"none"` | `"B"` | Browser URL prompt |
| `keys.new-pane-smart` | chord string or array or `"none"` | `"alt+n"` | New pane using smart split direction |
| `keys.next-tab` | chord string or array or `"none"` | `"tab"` | Next tab |
| `keys.prev-tab` | chord string or array or `"none"` | `"backtab"` | Previous tab |
| `keys.select-tab-1` through `keys.select-tab-9` | chord string or array or `"none"` | unbound | Select tab by visible tab number; use these to restore the old `Ctrl-b 1` through `Ctrl-b 9` tab selectors |
| `keys.split-right` | chord string or array or `"none"` | `"%"` | Split right |
| `keys.split-down` | chord string or array or `"none"` | `"\""` | Split down |
| `keys.close-pane` | chord string or array or `"none"` | `"x"` | Close active pane |
| `keys.close-tab` | chord string or array or `"none"` | `"X"` | Close active tab |
| `keys.rename-tab` | chord string or array or `"none"` | unbound | Rename active tab |
| `keys.rename-pane` | chord string or array or `"none"` | alias | Alias for `rename-tab` |
| `keys.rename-screen` | chord string or array or `"none"` | `","` | Rename active screen |
| `keys.rename-workspace` | chord string or array or `"none"` | `"$"` | Rename active workspace |
| `keys.close-screen` | chord string or array or `"none"` | `"&"` | Close active screen |
| `keys.prev-screen` | chord string or array or `"none"` | `["p","alt+["]` | Previous screen |
| `keys.next-screen` | chord string or array or `"none"` | `["n","alt+]"]` | Next screen |
| `keys.select-screen-1` through `keys.select-screen-9` | chord string or array or `"none"` | `"1"` through `"9"` | Select visible screen 1 through 9 |
| `keys.select-screen-0` | chord string or array or `"none"` | `"0"` | Select visible screen 10 |
| `keys.new-screen` | chord string or array or `"none"` | `"c"` | New screen |
| `keys.next-workspace` | chord string or array or `"none"` | `"w"` | Next workspace |
| `keys.new-workspace` | chord string or array or `"none"` | `"W"` | New workspace |
| `keys.toggle-sidebar` | chord string or array or `"none"` | `"s"` | Toggle sidebar |
| `keys.focus-next-pane` | chord string or array or `"none"` | `"o"` | Cycle to the next pane in the current screen |
| `keys.focus-left` | chord string or array or `"none"` | `["h","left","alt+h","alt+left"]` | Focus left |
| `keys.focus-right` | chord string or array or `"none"` | `["l","right","alt+l","alt+right"]` | Focus right |
| `keys.focus-up` | chord string or array or `"none"` | `["k","up","alt+k","alt+up"]` | Focus up |
| `keys.focus-down` | chord string or array or `"none"` | `["j","down","alt+j","alt+down"]` | Focus down |
| `keys.swap-pane-prev` | chord string or array or `"none"` | `"{"` | Swap active pane with the previous pane in split-tree order |
| `keys.swap-pane-next` | chord string or array or `"none"` | `"}"` | Swap active pane with the next pane in split-tree order |
| `keys.zoom-pane` | chord string or array or `"none"` | `"z"` | Toggle zoom for the active pane |
| `keys.resize-grow` | chord string or array or `"none"` | `"alt+="` | Grow the focused split |
| `keys.resize-shrink` | chord string or array or `"none"` | `"alt+-"` | Shrink the focused split |
| `keys.scroll-up` | chord string or array or `"none"` | `["[","pageup"]` | Scroll active PTY up 10 rows |
| `keys.scroll-down` | chord string or array or `"none"` | `"pagedown"` | Scroll active PTY down 10 rows |
| `keys.browser-back` | chord string or array or `"none"` | `"<"` | Browser back |
| `keys.browser-forward` | chord string or array or `"none"` | `">"` | Browser forward |
| `keys.browser-reload` | chord string or array or `"none"` | `"r"` | Browser reload |
| `keys.browser-edit-url` | chord string or array or `"none"` | `"u"` | Browser URL prompt |
| `keys.detach` | chord string or array or `"none"` | `"d"` | Quit local TUI or detach attached TUI |

Each action override replaces all default chords for that action. Values may be a string, an array of strings, or `"none"`. Non-string array entries are ignored. Set `keys.alt_shortcuts` to `false` to remove default Alt chords before applying user overrides; explicitly configured Alt chords still work.

`Ctrl-b x` now follows tmux and closes the active pane. `Ctrl-b X` closes the active tab. Existing users can restore the old cmux behavior with `"close-tab": "x"` and `"close-pane": "X"`.

Screens are visibly numbered from 1, so `select-screen-1` selects the first visible screen and `select-screen-0` selects the tenth visible screen. The snake_case spellings `select_screen_N` and `select_tab_N` are accepted as aliases. `Ctrl-b ]` and `Ctrl-b q` are intentionally unbound: cmux has no paste-buffer command and no pane-number quick-jump overlay yet. Zellij's modal `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are not defaults because they conflict with common shell and editor control keys.

Chord strings can be single characters or a key name with optional `ctrl`, `control`, `alt`, `option`, or `shift` modifiers. Examples: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.

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
    "border_inactive": "#444444",
    "notification_info": "#87afd7",
    "notification_warning": "#d7af5f",
    "notification_error": "#d75f5f"
  },
  "tabs": {
    "min_width": 9,
    "solid_background": true,
    "show_titles": false,
    "agents": ["claude", "codex", "opencode", "pi"]
  },
  "sidebar": {
    "width": 24,
    "max_width": 40
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
    "alt_shortcuts": false,
    "new-tab": ["t", "alt+t"],
    "new_browser_tab": "B",
    "new-pane-smart": "alt+n",
    "next-tab": "tab",
    "prev-tab": "backtab",
    "select-screen-1": "1",
    "select-screen-2": "2",
    "next-screen": ["n", "alt+]"],
    "prev-screen": ["p", "alt+["],
    "rename-tab": "r",
    "rename-screen": ",",
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "focus-right": ["l", "right", "alt+l", "alt+right"],
    "close-pane": "x",
    "close-tab": "X",
    "zoom-pane": "z",
    "swap-pane-prev": "{",
    "swap-pane-next": "}",
    "detach": "d"
  }
}
```
