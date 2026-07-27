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

`cmux-tree` scans local Codex processes every 10 seconds. It discovers TCP WebSocket listeners, verifies them through `/healthz`, and discovers running Codex daemon Unix sockets. Press `r` to scan immediately.

Each machine loads its 200 most recent conversations. The selected conversation loads a summary of its 25 most recent turns. These bounds avoid walking a large Codex archive or retaining thousands of thread and item records in either process.

App-server notifications update live messages, thinking, and tool calls in memory without another request. A lightweight summary refresh runs every 30 seconds as a recovery path. Stored tool details are fetched only after the user opens that turn's work accordion, and that request is limited to the 25 most recent items. Older items are marked as omitted. Each retained text field is capped at 20,000 characters, matching the trajectory renderer's detail limit.

For a local TCP listener:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

It appears as `Local Codex :4500` without configuration. A managed local daemon also appears automatically after `codex app-server daemon start`.

Codex app-servers launched with the default `stdio://` transport cannot be attached because their input and output pipes belong to the parent client. Start a WebSocket listener or the managed daemon when cmux tree needs to observe it.

When the managed daemon is listening at Codex's default Unix socket, cmux sends ordinary interactive and `resume` launches through Codex's native daemon-reuse path. The original terminal remains a full Codex chat client while `cmux-tree` observes the same server through a separate connection. This path performs one socket metadata check and starts no cmux CLI, probe, or hook processes. `exec`, explicit remote connections, profiles, and command-line config overrides keep the existing embedded-server hook path because Codex cannot replay their full launch configuration through a reused daemon.

Persistent Codex event hooks are not required for `cmux-tree`. Its trajectory is built directly from app-server events. Watching a conversation does not run a hook command, probe cmux, or hydrate stored tool output in the background.

Authenticated listeners are not auto-added because discovery never reads credentials from another process's arguments. Add them manually with a protected bearer-token file.

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
| `r` | Refresh and scan for local app-servers |
| `q`, `Ctrl-C` | Quit |

The mouse can select rows, expand trajectory items, activate the add-machine button, and scroll each column independently.
