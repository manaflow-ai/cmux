# Configuration

`cmux-tui` reads `~/.config/cmux/cmux-tui.json`, or `$XDG_CONFIG_HOME/cmux/cmux-tui.json` when `XDG_CONFIG_HOME` is set. Existing `mux.json` files are still used when `cmux-tui.json` is absent, and `cmux-tui.json` wins when both exist. Set `CMUX_TUI_CONFIG` to use another file; legacy `CMUX_MUX_CONFIG` is still accepted as a fallback. Every documented key is optional. Unknown top-level keys are rejected, logged, and cause the whole file to use defaults. Known sections are validated independently, so an invalid section is logged and replaced with that section's defaults while valid sections remain active. Section objects reject unknown keys. Action names are strict: an unknown action does not run and is ignored.

## Executable fields and transport rules

These fields are argv arrays. They are executed directly, without shell parsing or interpolation; include the shell explicitly when a shell is needed.

| Field | Shape | Notes |
| --- | --- | --- |
| `commands[].run` | non-empty string array | User command program and arguments; empty arguments are preserved |
| `status_bar.left[].run`, `status_bar.right[].run` | non-empty string array | Periodic status command; the last non-empty stdout line is displayed |
| `sidebar.plugin.command` | non-empty string array | Sidebar plugin program and arguments, hosted in a PTY |
| `machine_provider.command` | non-empty string array | Dynamic provider program and arguments; no shell |

Transport choices are mutually exclusive. A machine uses either `transport: "unix"` with `socket`, or `transport: "ssh"` with `host` and its SSH options. A dynamic provider uses one of `machine_provider.command` or `machine_provider.cloud.enabled`; do not combine provider transports with each other, static `machines`, `attach`, server listener or socket flags, `--headless`, or `--term`. Invalid combinations disable that provider configuration rather than merging transports.

Colors accept `#rrggbb`, `#rgb`, an xterm-256 number, or a numeric string.

## Theme

Selection colors are resolved in this order: explicit cmux-tui config, Ghostty config keys `selection-background` and `selection-foreground`, then built-in defaults. Ghostty configs are read from `$XDG_CONFIG_HOME/ghostty/config` (when set), `~/.config/ghostty/config`, and on macOS `~/Library/Application Support/com.mitchellh.ghostty/config`; later entries in the file win.

`theme.chrome` controls cmux-owned interface colors. `auto` selects light or dark chrome from this client's host background reported by OSC 11, then the configured Ghostty terminal background when the host does not report one, and uses dark when neither is available. `light` and `dark` select a fixed chrome theme. Host OSC 10/11 replies are local compatibility input for the attaching frontend; they do not replace shared session or application-authored terminal defaults.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `theme.chrome` | `auto`, `light`, or `dark` | `auto` | cmux-owned chrome theme for this client |
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
| `theme.border_style` | `"single"`, `"rounded"`, `"thick"`, `"double"`, or `"none"` | `"single"` | Pane border glyph set; `"none"` leaves the border cells blank so panes separate by empty space |
| `theme.status_bg` | color | chrome default | Status bar background |
| `theme.status_fg` | color | chrome default | Status bar foreground |
| `theme.sidebar_fg` | color | terminal default | Sidebar row foreground |
| `theme.sidebar_selected_fg` | color | chrome default | Selected sidebar row foreground |
| `theme.dim_inactive` | boolean | `false` | Renders unfocused terminal panes with the DIM attribute |

## Tabs

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `tabs.min_width` | integer | `7` | Minimum tab label width, clamped to 3 through 40 |
| `tabs.solid_background` | boolean | `true` | Renders tab chips with solid backgrounds |
| `tabs.show_titles` | boolean | `false` | Shows full process titles after tab numbers |
| `tabs.agents` | string array | `["claude","codex","opencode","pi"]` | Agent names surfaced in tab labels when `show_titles` is false |
| `tabs.style` | `"block"`, `"pill"`, or `"slant"` | `"block"` | Cap glyphs around solid tab chips (Nerd Font powerline glyphs, catppuccin-tmux style) |
| `tabs.plus.label` | string | `" + "` | Text of the tab bar's `+` button |
| `tabs.plus.action` | action name or `command:<id>` | new tab | Left-click override for the `+` button |
| `tabs.plus.menu` | action array | `[]` | Right-click menu on the `+` button; entries use the sidebar action grammar including labels and `command:<id>` |

Tabs are numbered by default. A recognized agent program can appear after the number. A user-assigned tab name replaces the generated label.

## Sidebar

The built-in sidebar defaults to the workspace list. Set `"sidebar": {"view": "files"}` for the yazi-style file browser. `Tab` toggles the built-in view while the sidebar is focused, and the configurable `toggle-sidebar-view` action toggles it from anywhere. A configured `sidebar.plugin` still replaces either built-in view.

`sidebar.views` is an ordered list of native resource projections, with no fixed column count. Each view has a stable `id`, a `levels` path, and optional native `actions`. A one-level path renders a list. Multi-level paths such as `workspaces → agents` and `workspaces → panes → tabs` render collapsible trees in one column. Nesting is optional. Valid resources are `machines`, `workspaces`, `panes`, `tabs`, and `agents`. Flat pane, tab, and agent views follow the highlighted workspace. Omit a resource to hide it.

`sidebar.profiles` names multiple view lists, and `sidebar.profile` selects the startup layout. Right-click anywhere and open **Sidebar → Layouts** to switch profiles without reconnecting machines. The same menu can hide or restore an individual view for the current session. Runtime visibility changes are keyed by profile and view ID, so switching away and back restores that profile's session-local choices.

Actions use the same stable IDs and execution path as keyboard commands, including `new-workspace`, `new-tab`, and `new-pane-smart`. An entry may also be an object `{"action": "new-workspace", "label": "new"}` to rename its button, and `"command:<id>"` pins a user command from the top-level `commands` section as a button. `actions_position: "top"` mounts the buttons at the view's top instead of the bottom edge. A view rooted at `workspaces` inherits `new-workspace`, including provider-specific isolated and shared choices. Set `"actions": []` to hide every pinned action, or provide an ordered list to replace the preset. Machine creation and connection actions remain capability-driven by the selected provider.

A top-level entry can also be a split group instead of a view: `{"id": "left", "split": "vertical", "panes": [ ... ]}` stacks its panes top to bottom in one column, `"split": "horizontal"` places them side by side, and groups nest up to three levels. Each pane is a view (same schema) or another split, with an optional `weight` (default `1`) setting its share. The divider between stacked panes drags with the mouse; from a rail's first or last row, `Up`/`Down` (or `k`/`j`) moves focus into the stacked neighbor. A split column keeps one width: the group's `width`, `max_width`, and `collapse_priority` default to the largest among its panes, and a width drag on any of its rails resizes the whole column.

Flat one-level `tabs` and `agents` views accept `"scope": "all"`. An `all`-scoped view sweeps every workspace instead of following the highlighted one; agents then order chronologically by their last status change, newest first, keep `done` agents visible, and show their workspace name when the agent has no session title. This is how a status board like *workspaces on top, all agents below* is built:

```json
"sidebar": {
  "views": [
    {"id": "left", "split": "vertical", "panes": [
      {"id": "workspaces", "levels": ["workspaces"]},
      {"id": "all-agents", "levels": ["agents"], "scope": "all", "weight": 2}
    ]}
  ]
}
```

Every view has an independent width and drag handle. Lower `collapse_priority` values hide first when the terminal must preserve 40 pane columns. A hidden view needs four additional columns before it returns, which prevents resize-boundary flicker. Panes of a split behave the same way vertically: when a column gets too short, its lowest-priority panes hide until space returns. `sidebar.columns` remains a compatibility alias for one-level machine, workspace, and tab views; `sidebar.views` wins when both are present.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `sidebar.view` | `"files"` or `"workspaces"` | `"workspaces"` | Built-in sidebar view when `sidebar.plugin` is unset |
| `sidebar.width` | integer | `22` | Sidebar width, clamped to 10 through 60 on load |
| `sidebar.compact_width` | integer | `10` | Width used by compact mode, clamped to 10 through 60 and capped at `sidebar.width` |
| `sidebar.max_width` | integer | `0` | Maximum live drag width; `0` means no configured maximum |
| `sidebar.profile` | string | first configured profile | Startup profile ID; ignored without `sidebar.profiles` |
| `sidebar.profiles` | array of profile objects | unset | Named layouts available from every context menu; overrides top-level `sidebar.views` and `sidebar.columns` |
| `sidebar.profiles[].id` | string | required | Stable unique profile identity |
| `sidebar.profiles[].name` | string | profile ID | Display name in the layout picker |
| `sidebar.profiles[].views` | array of view objects | required | Ordered projections using the same schema as `sidebar.views` |
| `sidebar.views` | array of view objects | unset | Ordered native lists and trees; omission preserves the machine-plus-workspace default |
| `sidebar.views[].id` | string | required | Stable unique identity for focus, collapse, scroll, and width state |
| `sidebar.views[].levels` | array of strings | required | Resource path, such as `["agents"]`, `["workspaces", "agents"]`, or `["workspaces", "panes", "tabs"]` |
| `sidebar.views[].actions` | array of action IDs | resource preset | Ordered native actions pinned below the resource rows; `[]` hides them |
| `sidebar.views[].width` | integer | resource default | Initial width, clamped to 10 through 60 |
| `sidebar.views[].max_width` | integer | `0` | Maximum live drag width; `0` means no configured maximum |
| `sidebar.views[].collapse_priority` | integer | resource default | Lower priorities hide first on narrow terminals |
| `sidebar.views[].actions_position` | `"top"` or `"bottom"` | `"bottom"` | Where the view's pinned action buttons render |
| `sidebar.views[].scope` | `"workspace"` or `"all"` | `"workspace"` | For flat `tabs`/`agents` views: follow the highlighted workspace, or sweep all workspaces (agents order newest status change first) |
| `sidebar.views[].split` | `"vertical"` or `"horizontal"` | unset | Turns the entry into a split group of `panes` instead of a leaf view |
| `sidebar.views[].panes` | array of entries | required with `split` | Child views or nested splits of a split group |
| `sidebar.views[].panes[].weight` | integer | `1` | Relative share of the parent split |
| `sidebar.row_height` | `1` or `2` | `2` | Rows per rail entry; `1` drops the subtitle line |
| `sidebar.row_gap` | integer | `1` | Blank rows between rail entries, `0` through `2` |
| `sidebar.rail_glyph` | string | `"▎"` | Accent glyph on active rail rows; `"none"` removes it |
| `sidebar.workspace_label` | string | `"{name}"` | Workspace row template with `{index}` and `{name}` |
| `sidebar.columns` | array of column objects | unset | Compatibility form for one-level `machines`, `workspaces`, and `tabs` views |
| `sidebar.plugin.command` | array of strings | unset | External sidebar plugin argv; when set, the sidebar hosts this program in a PTY instead of the built-in list |
| `sidebar.plugin.cwd` | string | unset | Working directory for the sidebar plugin process |

Live sidebar dragging also leaves at least 40 columns for pane content.

### Sidebar plugins

Sidebar plugins can be installed from git repositories:

```bash
cmux sidebar plugin install https://github.com/manaflow-ai/cmux-sidebar-fzf
cmux sidebar plugin use fzf
```

`sidebar plugin install` clones into `~/.local/share/cmux/mux-plugins/<name>` (or
`$XDG_DATA_HOME/cmux/mux-plugins/<name>`), validates `cmux-plugin.toml`, runs
the optional build command, and verifies the resolved run command is
executable. `sidebar plugin use <name>` writes `sidebar.plugin.command` as an absolute
argv and `sidebar.plugin.cwd` as the plugin directory, preserving unrelated
cmux-tui config keys. A running TUI applies it after config reload; `sidebar plugin use`
sends that reload automatically when the resolved session socket is reachable.

Return to the built-in sidebar with:

```bash
cmux sidebar plugin use --builtin
```

## Machines

The machine rail is optional. Its position comes from a `sidebar.views` entry whose level is `machines`, or it stays first under the default layout. It activates when `machine_sidebar.enabled` is true, `machines` has a valid entry, or `machine_sidebar.create_sources` is nonempty.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `machine_sidebar.enabled` | boolean | `false` | Enables the machine rail without requiring a configured target |
| `machine_sidebar.width` | integer | `22` | Initial machine-rail width, clamped to 10 through 60 on load |
| `machine_sidebar.max_width` | integer | `0` | Maximum live drag width for the machine rail; `0` means no configured maximum |
| `machine_sidebar.create_sources` | array | `[]` | Prototype-only native creation choices; no provider command is executed |
| `machines` | array | `[]` | Static Unix-socket and SSH connection targets |

Each prototype creation source has a unique `id`, a `name`, and an optional `subtitle`. Selecting `+ new vm` opens the native source picker. The current prototype adds a session-local catalog entry backed by the current mux socket, so Docker, E2B, Firecracker, and other labels exercise the full UI without provisioning or billing. Production providers remain responsible for real lifecycle and transport operations.

Try the tracked prototype configuration with:

```bash
cd cmux-tui
CMUX_TUI_CONFIG=examples/resource-columns.prototype.json cargo run -p cmux-tui -- --session columns
```

`resource-columns.prototype.json` starts with a two-column focused layout that omits tabs, then exposes three-column and tree profiles from the right-click Sidebar menu. `resource-tree.prototype.json` combines machines with a workspace/agent tree. `resource-tree-no-agents.prototype.json` combines machines with a workspace/pane/tab tree and contains no agent representation.

Every machine has a unique nonempty `id`, a nonempty display `name`, an optional `subtitle`, and one transport. The id `current` is reserved for the automatically inserted local session.

SSH machine targets currently require macOS or Linux because the remote daemon uses Unix PTYs and sockets. A native Windows OpenSSH target reports the WSL 2 prerequisite instead of attempting a Unix command in `cmd.exe`. Install a Linux distribution under WSL 2 and expose that Linux environment through its own SSH alias before attaching it as a machine.

| Machine key | Applies to | Type | Default | Effect |
| --- | --- | --- | --- | --- |
| `id` | all | string | required | Stable config identity; duplicate and empty ids are ignored |
| `name` | all | string | required | Primary rail label |
| `subtitle` | all | string | `""` | Secondary rail label |
| `transport` | all | `"unix"` or `"ssh"` | required | Connector type |
| `socket` | Unix | string | required | Absolute path to an existing cmux session socket |
| `host` | SSH | string | required | SSH host name or address |
| `user` | SSH | string | unset | SSH user, passed as `user@host` |
| `port` | SSH | integer | unset | SSH port, passed with `-p` |
| `identity_file` | SSH | string | unset | Local SSH identity path, passed with `-i` |
| `session` | SSH | string | `"main"` | Remote cmux session started or reused by the managed connection |
| `binary` | SSH | string | `"~/.local/bin/cmux-tui"` | Shell-safe remote executable path used for compatibility checks and the managed daemon |

```json
{
  "machine_sidebar": {
    "enabled": true,
    "width": 20,
    "max_width": 36
  },
  "machines": [
    {
      "id": "local-agents",
      "name": "Local agents",
      "subtitle": "second session",
      "transport": "unix",
      "socket": "/tmp/cmux-tui-501/agents.sock"
    },
    {
      "id": "buildbox",
      "name": "Build box",
      "subtitle": "us-central1",
      "transport": "ssh",
      "host": "buildbox.example.com",
      "user": "dev",
      "port": 22,
      "identity_file": "/Users/me/.ssh/id_ed25519",
      "session": "agents",
      "binary": "/home/dev/.local/bin/cmux"
    }
  ]
}
```

The SSH target uses the same managed connection as `cmux-tui ssh`. It probes `binary`, starts or reuses the named remote mux and sidecar, and retains a reconnecting local bridge while that machine is selected. Packaged releases can install their pinned binary when the probe reports it missing or incompatible. Source builds require the exact matching binary to be preinstalled. SSH is noninteractive with strict host-key checking, disabled agent and X11 forwarding, and disabled port forwarding. See [Machines](machines.md) for rail behavior and setup details.

### Dynamic machine provider

Dynamic provider startup is disabled by default. Persistent configuration currently covers the built-in cloud SSH transport:

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `machine_provider.command` | array of strings or null | `null` | Argv of a provider process to spawn, like `--machine-provider-command program arg --` (no shell). Explicit CLI provider modes override it |
| `machine_provider.cloud.enabled` | boolean | `false` | Starts the dynamic provider through SSH |
| `machine_provider.cloud.host` | string | `"cmux.cloud"` | SSH host |
| `machine_provider.cloud.user` | string or null | `null` | Optional SSH user |
| `machine_provider.cloud.port` | integer or null | `null` | Optional nonzero SSH port |
| `machine_provider.cloud.identity_file` | string or null | `null` | Optional local SSH identity path |

```json
{
  "machine_provider": {
    "cloud": {
      "enabled": true,
      "host": "cmux.cloud",
      "user": "lawrence",
      "port": 22,
      "identity_file": "/Users/me/.ssh/id_ed25519"
    }
  }
}
```

`--cloud-host`, `--cloud-user`, `--cloud-port`, and `--cloud-identity` override their matching config values and imply `--cloud`. A local Cloud client composes the static `machines` array with the provider catalog. Static entries stay client-local. `+ ssh host` is provider-owned when `connect-external-machine-v1` and the current snapshot bit are both enabled; otherwise its temporary `host` or `user@host` targets stay client-local and use local SSH credentials. Explicit `--machine-provider <socket>` or `--machine-provider-command <argv...> --` overrides an enabled cloud config; those provider-only modes reject a nonempty `machines` array. Every dynamic provider rejects another provider transport, `attach`, server socket/listener flags, `--headless`, and `--term`.

The cloud connector runs `cmux provider control` and `cmux provider stream` remotely. These are provider service commands, not cmux-tui control-socket verbs. See [Machines](machines.md#dynamic-providers).

## Browser

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `browser.cdp_url` | string | `null` | Explicit development-only external CDP endpoint, accepted as `http://host:port` or `ws://...` |
| `browser.max_capture_megapixels` | number | `2.0` | Maximum browser capture size before downscaling, from 0.0 through 2.0 |
| `browser.capture_scale` | number or null | `null` | Maximum capture scale from 0.0 through 1.0, reduced further when needed to stay under the megapixel limit |

The compatibility keys `browser.chrome_binary`, `browser.mode`, `browser.discover`, `browser.discover_ports`, `browser.user_data_dir`, and `browser.ephemeral` are still accepted when reading older config files but no longer select or launch a browser. Production browser tabs wait for cmux-browser's connection-scoped provider lease. `browser.cdp_url` and `CMUX_MUX_CDP_URL` bypass that lease only for explicit development harnesses; neither path performs discovery or process launch.

## Pane

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `pane.padding` | integer | `0` | Blank cells between the pane border and the terminal content, on every side, clamped to 0 through 4 |

Padding shrinks the PTY size accordingly and never pads a pane below one content cell. Border geometry, the tab bar, and the scrollbar keep their positions, so `{"theme":{"border_style":"none"},"pane":{"padding":1}}` renders borderless panes separated by whitespace.

## Status bar

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `status_bar.visible` | boolean | `true` | Shows the bottom screens bar |
| `status_bar.show_screens` | boolean | `true` | Renders the clickable screens strip |
| `status_bar.show_session` | boolean | `true` | Renders the right-aligned `[session]` label |
| `status_bar.left` | array of segments | `[]` | Segments before the screens strip |
| `status_bar.right` | array of segments | `[]` | Segments right-aligned before the session label |
| `status_bar.left[].text` | string | one of text/run | Literal text with `{variable}` interpolation |
| `status_bar.left[].run` | string array | one of text/run | Argv run on an interval; the last nonempty stdout line becomes the segment text, escape sequences stripped, capped at 200 characters |
| `status_bar.left[].interval` | integer seconds | `5` | Refresh interval for `run` segments, clamped to 1 through 3600 |
| `status_bar.left[].fg` / `bg` | color | bar colors | Segment colors |
| `status_bar.left_separator` | string | unset | Powerline separator between left segments; its foreground takes the previous segment's background and its background the next one's (e.g. `"\ue0b0"`) |
| `status_bar.right_separator` | string | unset | Mirrored separator drawn left of each right segment (e.g. `"\ue0b2"`) |
| `status_bar.screens_style` | `"block"`, `"pill"`, or `"slant"` | `"block"` | Cap glyphs around the active screen chip |
| `status_bar.screens_plus.label` / `.action` / `.menu` | as `tabs.plus` | `" + "` / new screen / `[]` | The screens strip's `+` button |

Text segments interpolate `{session}`, `{workspace}`, `{screen}`, `{screens}`, `{title}`, and `{user}`; unknown braces stay literal. `run` segments are the tmux `#()` equivalent: each is executed on its own interval with a five-second runtime bound, so a battery, git, or clock widget is one script. At most 8 segments per side. Transient status messages keep priority over the session label.

```json
{
  "theme": {"status_bg": "#1c1c1c", "status_fg": "#87d787"},
  "status_bar": {
    "left": [{"text": " {session} · {workspace} ", "fg": "#87d787"}],
    "right": [
      {"run": ["sh", "-lc", "git -C \"$HOME/src\" branch --show-current"], "interval": 30},
      {"run": ["date", "+%H:%M"], "interval": 30, "fg": "#d7af5f"}
    ]
  }
}
```

Hiding the bar gives its row back to the panes. Transient status messages still overlay the bottom row until dismissed, single-surface style. The screens strip, the session label, and the horizontal viewport track are not rendered while hidden; screens stay reachable through `prev-screen`, `next-screen`, `select-screen-N`, and the sidebar.

## Scrollbar

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `scrollbar.position` | `"column"` or `"border"` | `"column"` | Dedicated scrollbar column or right-border overlay |

Terminal panes, the workspace sidebar, and the shortcut modal share the same `▕` thumb, which expands to `▐` while hovered or dragged. A scrollbar is drawn only when its content exceeds the visible rows.

## Viewport

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `viewport.animation` | boolean | `true` | Animate horizontal viewport movement |

`Ctrl-b g` inserts a terminal immediately after the focused horizontal column at two-thirds of the current viewport width. Existing panes retain their tiled layout. The status bar gains a continuous horizontal track whenever the resulting screen is wider than the viewport. Focus movement and track clicks reveal offscreen panes. `Alt-n` applies automatic layout inside the focused column. Set `{"viewport":{"animation":false}}` to make viewport moves immediate.

## Server

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `server.ws` | socket address string | unset | Enables the WebSocket control listener, for example `127.0.0.1:7681` |
| `server.ws_token` | string | unset | Adds a static-token bypass for interactive TUI pairing |
| `server.detached_owner` | boolean | `true` | Plain `cmux` starts or reuses a detached headless session owner and attaches as a client, so the session survives every client detaching. `false` hosts the session inside the first TUI process |

WebSocket clients pair through a six-digit browser/TUI comparison by default. WebSocket binds must be loopback unless cmux-tui is started with `--ws-insecure-bind`. The listener has no TLS; use an authenticated TLS reverse proxy for remote access. See the [transport contract](../spec/transports.md#websocket).

## Commands

`commands` is an ordered list of user commands, the cmux-tui equivalent of tmux `bind-key ... command`. Each command names an argv program and optionally binds key chords to it. Pressing a bound chord runs the argv as a new PTY tab in the active pane, exactly like `cmux run`. The child inherits `CMUX_TUI_SOCKET`, so a command script can immediately drive the public CLI against its own session: create workspaces, apply splits, rename tabs, then close its own tab. The working directory defaults to the active pane's current directory; `cwd` values pass through without shell expansion, so use absolute paths or a shell argv for `~`.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `commands[].id` | string | required | Stable unique identity; duplicates and empty ids are ignored |
| `commands[].name` | string | the id | Display name in the shortcut modal |
| `commands[].run` | string array | required | Argv executed directly, without a shell; the program must be nonempty, later arguments pass through verbatim (empty ones included) |
| `commands[].keys` | chord string or array | unset | Chords that run the command; Alt- and Super-modified chords are modeless, other chords run after the prefix |
| `commands[].cwd` | string | active pane cwd | Working directory for the child process |

Try the tracked example with `CMUX_TUI_CONFIG=examples/user-commands.json cargo run -p cmux-tui -- --session commands`. At most 32 commands are honored; extra entries are ignored with a warning. A command chord replaces whatever action previously held that chord, matching the last-write-wins behavior of the `keys` section, and the prefix chord stays reserved. Shell pipelines need an explicit shell argv, for example `["zsh", "-lc", "git diff | delta"]`.

```json
{
  "commands": [
    {"id": "lazygit", "name": "LazyGit", "keys": "g", "run": ["lazygit"]},
    {"id": "scratch", "keys": ["alt+s"], "run": ["sh", "-lc", "cd \"$HOME/notes\" && exec \"${EDITOR:-vi}\" scratch.md"]}
  ]
}
```

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `keys.prefix` | chord string | `"ctrl+b"` | Prefix chord |
| `keys.macos_option_as_alt` | boolean | `true` | Treat an empty-text Alt character event as terminal Alt when true, or macOS Option composition when false |
| `keys.alt_shortcuts` | boolean | `true` | Enables default modeless Alt bindings when true |
| `keys.super_shortcuts` | boolean | `true` | Enables default modeless Command/Super bindings when true |
| `keys.send-prefix` | chord string or array or `"none"` | current prefix chord | Send the configured prefix to the active surface |
| `keys.new-tab` | chord string or array or `"none"` | `["t","alt+t"]` | New PTY tab |
| `keys.new_browser_tab` | chord string or array or `"none"` | `"B"` | Browser URL prompt |
| `keys.new-pane-smart` | chord string or array or `"none"` | `"alt+n"` | New pane using the default automatic layout |
| `keys.next-tab` | chord string or array or `"none"` | `"tab"` | Next tab |
| `keys.prev-tab` | chord string or array or `"none"` | `"backtab"` | Previous tab |
| `keys.select-tab-0` through `keys.select-tab-9` | chord string or array or `"none"` | unbound | Select tab by its zero-based visible index |
| `keys.split-right` | chord string or array or `"none"` | `"%"` | Split right |
| `keys.split-down` | chord string or array or `"none"` | `"\""` | Split down |
| `keys.close-pane` | chord string or array or `"none"` | `"X"` | Close active pane |
| `keys.close-tab` | chord string or array or `"none"` | `"x"` | Close active tab |
| `keys.rename-tab` | chord string or array or `"none"` | unbound | Rename active tab |
| `keys.rename-pane` | chord string or array or `"none"` | alias | Alias for `rename-tab` |
| `keys.rename-screen` | chord string or array or `"none"` | `","` | Rename active screen |
| `keys.rename-workspace` | chord string or array or `"none"` | `"$"` | Rename active workspace |
| `keys.close-screen` | chord string or array or `"none"` | `"&"` | Close active screen |
| `keys.prev-screen` | chord string or array or `"none"` | `["p","alt+["]` | Previous screen |
| `keys.next-screen` | chord string or array or `"none"` | `["n","alt+]"]` | Next screen |
| `keys.select-screen-0` through `keys.select-screen-9` | chord string or array or `"none"` | `"0"` through `"9"` | Select visible screen 0 through 9 |
| `keys.new-screen` | chord string or array or `"none"` | `"c"` | New screen |
| `keys.prev-workspace` | chord string or array or `"none"` | `["(","alt+{"]` | Previous workspace |
| `keys.next-workspace` | chord string or array or `"none"` | `["w",")","alt+}"]` | Next workspace |
| `keys.new-workspace` | chord string or array or `"none"` | `"W"` | New workspace |
| `keys.close-workspace` | chord string or array or `"none"` | `"D"` | Close active workspace |
| `keys.toggle-sidebar` | chord string or array or `"none"` | `"s"` | Toggle sidebar |
| `keys.toggle-sidebar-compact` | chord string or array or `"none"` | `"m"` | Toggle compact/full sidebar width and show the sidebar |
| `keys.toggle-sidebar-view` | chord string or array or `"none"` | `"e"` | Toggle the built-in files/workspaces view; a plugin still takes precedence |
| `keys.focus-sidebar` | chord string or array or `"none"` | `"S"` | Focus the built-in sidebar or sidebar plugin; a prefixed command returns focus to the pane |
| `keys.new-pane-right` | chord string or array or `"none"` | `"g"` | Insert a two-thirds-width terminal after the focused horizontal column |
| `keys.undo-layout` | chord string or array or `"none"` | `"U"` | Undo the latest structural layout action on the focused screen |
| `keys.focus-next-pane` | chord string or array or `"none"` | `"o"` | Cycle to the next pane in the current screen |
| `keys.focus-left` | chord string or array or `"none"` | `["h","left","alt+h","alt+left"]` | Focus left, entering the rightmost sidebar view at the pane boundary |
| `keys.focus-right` | chord string or array or `"none"` | `["l","right","alt+l","alt+right"]` | Focus right, returning to the pane after the final sidebar view |
| `keys.focus-up` | chord string or array or `"none"` | `["k","up","alt+k","alt+up"]` | Focus up |
| `keys.focus-down` | chord string or array or `"none"` | `["j","down","alt+j","alt+down"]` | Focus down |
| `keys.swap-pane-prev` | chord string or array or `"none"` | `"{"` | Swap active pane with the previous pane in split-tree order |
| `keys.swap-pane-next` | chord string or array or `"none"` | `"}"` | Swap active pane with the next pane in split-tree order |
| `keys.zoom-pane` | chord string or array or `"none"` | `"z"` | Toggle zoom for the active pane |
| `keys.resize-grow` | chord string or array or `"none"` | `"alt+="` | Grow the focused split |
| `keys.resize-shrink` | chord string or array or `"none"` | `"alt+-"` | Shrink the focused split |
| `keys.scroll-up` | chord string or array or `"none"` | `["[","pageup"]` | Scroll active PTY up 10 rows |
| `keys.scroll-down` | chord string or array or `"none"` | `"pagedown"` | Scroll active PTY down 10 rows |
| `keys.clear-history` | chord string or array or `"none"` | `"cmd+k"` | Clear retained PTY history and completed visible rows while preserving active input |
| `keys.browser-back` | chord string or array or `"none"` | `"<"` | Browser back |
| `keys.browser-forward` | chord string or array or `"none"` | `">"` | Browser forward |
| `keys.browser-reload` | chord string or array or `"none"` | `"r"` | Browser reload |
| `keys.browser-edit-url` | chord string or array or `"none"` | `"u"` | Browser URL prompt |
| `keys.show-shortcuts` | chord string or array or `"none"` | `"?"` | Open the resolved keyboard shortcut modal |
| `keys.provider-menu` | chord string or array or `"none"` | `"m"` | Open the machine provider menu when the machine rail is focused |
| `keys.detach` | chord string or array or `"none"` | `"d"` | Quit local TUI or detach attached TUI |

Each action override replaces all default chords for that action. Values may be a string, an array of strings, or `"none"`. Non-string array entries are ignored. Changing `keys.prefix` also moves the default `send-prefix` chord so pressing the configured prefix twice continues to pass it through. An explicit `keys.send-prefix` override takes precedence. Set `keys.alt_shortcuts` or `keys.super_shortcuts` to `false` to remove that modeless default layer before applying user overrides; explicitly configured chords still work.

Kitty keyboard reports the same empty-text character sequence for a real terminal Alt chord and a macOS Option dead-key prefix. Set `keys.macos_option_as_alt` to match the host terminal's `macos-option-as-alt` behavior. The default `true` keeps real Alt chords active. Set it to `false` when Option starts composition; cmux-tui then discards the prefix event and accepts the later composed text without invoking an Alt binding.

`Ctrl-b x` closes the active tab because tab lifecycle is the more frequent cmux action. `Ctrl-b X` closes its containing pane. Both bindings accept independent overrides.

Screen and tab positions are zero-based, so each `select-screen-N` or `select-tab-N` action selects index `N`. Generated workspace names also start at `0`. The snake_case spellings `select_screen_N` and `select_tab_N` are accepted as aliases. `Ctrl-b ]` and `Ctrl-b q` are intentionally unbound: cmux has no paste-buffer command and no pane-number quick-jump overlay yet. Zellij's modal `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are not defaults because they conflict with common shell and editor control keys.

Chord strings can be single characters or a key name with optional `ctrl`, `control`, `alt`, `option`, `cmd`, `command`, `super`, or `shift` modifiers. Examples: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"cmd+k"`, `"tab"`, `"backtab"`, `"shift+tab"`, `"pageup"`, `"pagedown"`, `"esc"`, `"space"`, `"left"`, `"right"`, `"up"`, `"down"`, `"home"`, and `"end"`.

## Example

```json
{
  "theme": {
    "chrome": "dark",
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
    "view": "files",
    "width": 24,
    "compact_width": 10,
    "max_width": 40
  },
  "machine_sidebar": {
    "enabled": true,
    "width": 20,
    "max_width": 36
  },
  "machines": [
    {
      "id": "buildbox",
      "name": "Build box",
      "subtitle": "remote agents",
      "transport": "ssh",
      "host": "buildbox.example.com",
      "user": "dev",
      "session": "agents",
      "binary": "/home/dev/.local/bin/cmux"
    }
  ],
  "browser": {
    "cdp_url": null,
    "max_capture_megapixels": 2.0,
    "capture_scale": null
  },
  "scrollbar": {
    "position": "column"
  },
  "viewport": {
    "animation": true
  },
  "server": {
    "ws": "127.0.0.1:7681",
    "ws_token": "replace-with-a-secret"
  },
  "keys": {
    "prefix": "ctrl+a",
    "macos_option_as_alt": true,
    "alt_shortcuts": false,
    "super_shortcuts": false,
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
    "toggle-sidebar-compact": "m",
    "toggle-sidebar-view": "e",
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "focus-right": ["l", "right", "alt+l", "alt+right"],
    "close-tab": "x",
    "close-pane": "X",
    "zoom-pane": "z",
    "swap-pane-prev": "{",
    "swap-pane-next": "}",
    "show-shortcuts": "?",
    "detach": "d"
  }
}
```

## Client log

The client appends every user-visible warning (bottom-bar status messages, provider notices, toasts) and its own stderr diagnostics to a rolling log so problems seen in the TUI can be diagnosed after the session. While the TUI owns the terminal, process stderr (including panics) is routed into the same file instead of corrupting the raw-mode screen, and is restored on exit. Each launch writes one startup line with the build commit so log stretches are attributable.

The file lives at the cmux-tui state root: `~/Library/Application Support/cmux-tui/client.log` on macOS, `$XDG_STATE_HOME/cmux-tui/client.log` (or `~/.local/state/cmux-tui/client.log`) on Linux, `%LOCALAPPDATA%\cmux-tui\client.log` on Windows. `CMUX_TUI_LOG_FILE` overrides the path. The active file rolls to `client.log.1` at 2 MiB and one rollover is kept, so the log never grows past roughly 4 MiB. Several cmux-tui processes may share the file: writes and rotation take an exclusive advisory lock, rotation by one process is followed by the others, and the size cap counts every writer.
