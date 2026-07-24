# cmux tree

`cmux-tree` is a read-only TUI for watching Codex work across machines. Its three columns show machines, Codex conversations with nested subagents, and the selected conversation trajectory.

The binary is named `cmux-tree`. The existing `cmux tree` command already prints the Swift app's pane hierarchy, so this first version does not replace that command.

## Run

Build and launch from the repository:

```bash
cd cmux-tui
cargo build -p cmux-tree
target/debug/cmux-tree
```

The default config is `~/.config/cmux-tree/config.json`. Set `CMUX_TREE_CONFIG` or pass `--config PATH` to use another file.

## Start Codex app-server

For Codex on the same machine:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

Press `a` in `cmux-tree`, then enter a name and `ws://127.0.0.1:4500`.

For another machine, bind app-server to that machine's Tailscale, LAN, or VPN address. Codex requires authentication on non-loopback listeners:

```bash
umask 077
openssl rand -hex 32 > ~/.codex/cmux-tree.token
codex app-server --listen ws://100.64.0.8:4500 \
  --ws-auth capability-token \
  --ws-token-file "$HOME/.codex/cmux-tree.token"
```

Copy the token into a protected file on the machine running `cmux-tree`. Add the remote WebSocket URL and the local token-file path in the add-machine dialog. The config stores the file path, not the token.

`cmux-tree` does not create or manage the network. The address can use any route supplied by Tailscale, a local network, or another VPN. Use `wss://` when a TLS reverse proxy protects the app-server endpoint.

Codex currently marks the WebSocket app-server transport as experimental. Keep it on a trusted network and use a capability token for every non-loopback endpoint.

## Layout and controls

The machine column contains one row per Codex app-server. The conversation column orders root conversations by their latest user or stop activity and nests subagent threads under their parent. The trajectory column updates while Codex works.

Completed work is collapsed at the turn level. Expand a turn to reveal its tool calls and thinking, then expand an individual item to reveal command output, arguments, results, or diffs. Running work is expanded as it arrives.

| Input | Action |
| --- | --- |
| `Tab`, `Shift-Tab`, `h`, `l` | Change columns |
| `j`, `k`, arrow keys | Move selection |
| `Enter`, `Space` | Expand or collapse |
| `PageUp`, `PageDown`, mouse wheel | Scroll |
| `g`, `G` | Jump to top or bottom |
| `a` | Add a machine |
| `r` | Refresh |
| `q`, `Ctrl-C` | Quit |

The mouse can select rows, expand trajectory items, activate the add-machine button, and scroll each column independently.
