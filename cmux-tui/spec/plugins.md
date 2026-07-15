# Plugin Contract

This document specifies the mux-side sidebar plugin contract.

## Sidebar Plugins

A sidebar plugin is an executable terminal program. The mux server starts it inside a PTY and the TUI renders that PTY in the sidebar using the same Ghostty VT surface pipeline used by pane PTYs.

### Configuration

`~/.config/cmux/cmux-tui.json` (or legacy `mux.json` when the new file is absent):

```json
{
  "sidebar": {
    "plugin": {
      "command": ["/path/to/plugin-binary"],
      "cwd": "/optional"
    }
  }
}
```

When `sidebar.plugin` is absent, the built-in view selected by `sidebar.view` is used (`files` by default, or `workspaces`). When present, the plugin replaces either built-in view. In a local TUI session, `reload-config` applies this key through the existing config reload path. A headless server or attached-client setup may require restarting the server process so the server, not the attach client, picks up the plugin command.

The sidebar content PTY is sized to the sidebar content cells. The host TUI keeps one separator/focus-border column at the right edge. Resizes use normal PTY resizing (`TIOCSWINSZ` on Unix), so plugins observe the standard terminal resize behavior and `SIGWINCH`; there is no plugin-specific resize protocol.

### Environment

The child process receives:

| Variable | Value |
| --- | --- |
| `CMUX_TUI_SOCKET` | The server process control socket path for this cmux-tui session. |
| `CMUX_MUX_SOCKET` | Legacy alias for `CMUX_TUI_SOCKET`. |
| `CMUX_SIDEBAR` | `1`. |
| `TERM` | The same TERM configured for ordinary PTY surfaces. |

The plugin runs in the server process context. Attached TUI clients request and render the server-owned plugin surface; they do not spawn their own plugin process.

### Lifecycle

The mux starts the plugin when the plugin sidebar first becomes visible. Hiding the sidebar stops rendering but does not kill the plugin. The plugin is killed when the mux server exits or when config changes remove or replace the plugin command.

If the plugin exits or fails to start, the TUI renders a visible error message in the sidebar. The server records a bounded restart backoff and will not hot crash-loop. Focusing the sidebar requests a relaunch after the backoff has elapsed.

### Focus And Input

When a plugin is configured, `focus-sidebar` focuses its PTY. The default binding is `prefix S`.

While the sidebar is focused, key and paste input are forwarded as PTY bytes using the same key encoder and terminal-mode state as pane PTYs. The global prefix chord is the escape hatch back to cmux:

- `prefix prefix` sends a literal prefix key to the plugin and keeps sidebar focus.
- `prefix <command>` leaves sidebar focus and runs the normal cmux prefixed command.
- `prefix S` leaves sidebar focus when already focused.

Mouse input is not forwarded to sidebar plugins in this round because ordinary PTY pane mouse forwarding is not implemented in this TUI path. Clicking inside the plugin sidebar focuses it.

### Manifest

Plugin directories use `cmux-plugin.toml` at the directory root:

```toml
[plugin]
name = "fzf"
kind = "sidebar"
version = "0.1.0"
description = "Fuzzy-find workspaces, screens, and panes"

[run]
command = ["target/release/cmux-sidebar-fzf"]

[build]
command = ["cargo", "build", "--release"]
```

The host reads the already-installed command from the cmux-tui config. The plugin
manager installs sidebar plugins from git repositories and writes the resolved
command into that config file.

## Install Layout

Installed plugins live under:

```text
~/.local/share/cmux/mux-plugins/<name>
```

When `$XDG_DATA_HOME` is set, the equivalent directory is:

```text
$XDG_DATA_HOME/cmux/mux-plugins/<name>
```

`<name>` is either `[plugin].name` from `cmux-plugin.toml` or the
`cmux-tui plugin install --name <override>` value. Names must match
`[a-z0-9-_]+`; path traversal and mixed-case names are rejected. Install clones
to a temporary directory first, validates the manifest, runs `[build].command`
when present, verifies the resolved `[run].command[0]` exists and is
executable, then moves the directory into place. Existing installs are refused
unless `--force` is supplied.

Relative manifest run commands are resolved to absolute paths under the plugin
directory before `plugin use` writes the runnable command into the cmux-tui config.
