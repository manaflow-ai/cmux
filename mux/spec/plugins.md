# Plugin Contract

This document specifies the mux-side sidebar plugin contract.

## Sidebar Plugins

A sidebar plugin is an executable terminal program. The mux server starts it inside a PTY and the TUI renders that PTY in the sidebar using the same Ghostty VT surface pipeline used by pane PTYs.

### Configuration

`~/.config/cmux/mux.json`:

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

When `sidebar.plugin` is absent, the built-in workspace sidebar is used. When present, the plugin replaces the built-in sidebar. In a local TUI session, `reload-config` applies this key through the existing config reload path. A headless server or attached-client setup may require restarting the server process so the server, not the attach client, picks up the plugin command.

The sidebar content PTY is sized to the sidebar content cells. The host TUI keeps one separator/focus-border column at the right edge. Resizes use normal PTY resizing (`TIOCSWINSZ` on Unix), so plugins observe the standard terminal resize behavior and `SIGWINCH`; there is no plugin-specific resize protocol.

### Environment

The child process receives:

| Variable | Value |
| --- | --- |
| `CMUX_MUX_SOCKET` | The server process control socket path for this mux session. |
| `CMUX_SIDEBAR` | `1`. |
| `TERM` | The same TERM configured for ordinary PTY surfaces. |

The plugin runs in the server process context. Attached TUI clients request and render the server-owned plugin surface; they do not spawn their own plugin process.

### Lifecycle

The mux starts the plugin when the plugin sidebar first becomes visible. Hiding the sidebar stops rendering but does not kill the plugin. The plugin is killed when the mux server exits or when config changes remove or replace the plugin command.

If the plugin exits or fails to start, the TUI renders a visible error message in the sidebar. The server records a bounded restart backoff and will not hot crash-loop. Focusing the sidebar requests a relaunch after the backoff has elapsed.

### Focus And Input

`focus-sidebar` is the keyboard action for focusing the sidebar plugin. The default binding is `prefix S`.

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

The host reads the already-installed command from `mux.json` in this round. Plugin manager install/build verbs are separate follow-up work. The install-directory convention for that follow-up is:

```text
~/.local/share/cmux/mux-plugins/<name>
```

Relative manifest commands are resolved by the plugin manager before it writes the runnable command into `mux.json`.
