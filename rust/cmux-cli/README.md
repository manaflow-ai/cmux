# cmux-cli

A tmux-style terminal multiplexer in Rust, built on
[manaflow-ai/libghostty-rs](https://github.com/manaflow-ai/libghostty-rs/tree/ccb738317b14fa1a07f93584746be582be4226d5)
for VT parsing.

cmux-cli is the CLI-native sibling to the macOS
[cmux](https://github.com/manaflow-ai/cmux) app. Same concept model,
different runtime: a long-lived server you
detach from and reattach to, over a Unix socket or WebSocket.

## Status

Milestone-by-milestone from [`plans/task-cmx-bootstrap/architecture-overview.md`](plans/task-cmx-bootstrap/architecture-overview.md):

| Milestone | Scope | Status |
|---|---|---|
| M1 | libghostty-vt smoke test | ✅ shipped |
| M2 | cmx binary wraps a shell in-process | ✅ shipped (superseded by M3) |
| M3 | Unix socket server + Grid attach + MessagePack protocol | ✅ shipped |
| M4 | Pane splits: recursive pane tree + rect geometry | ✅ shipped |
| M5 | Terminal stack per pane | ✅ shipped |
| M6 | Multi-workspace, multi-space, snapshot persistence | ✅ shipped |
| M7 | Paste-buffer stack + OSC 52 clipboard mirror | ✅ shipped |
| M8 | Config file + keybind dispatch + notify hot reload | ✅ shipped |
| M9 | WebSocket transport + bearer-token auth | ✅ shipped (TS UI: follow-up) |
| M10 | Swift client for macOS cmux | scaffolded — wire contract documented |
| M11 | Top-level README, CI, polish | in progress |

## Installing (dev)

Requires:

- Rust 1.94+ (edition 2024)
- Zig 0.15.2 (libghostty-vt's `build.rs` shells out to it)

```sh
git clone https://github.com/manaflow-ai/cmux
cd cmux/rust/cmux-cli
cargo build --release
cargo install --path crates/cmx
```

## Using

```sh
# Start the server if needed, then attach.
cmx

# Explicit spelling. `reattach` is an alias for `attach`.
cmx attach
```

Default keybinds (`preset = "both"`, tmux prefix is `C-b`):

### Name table

These are the public nouns cmux-cli uses now:

| Name | Meaning |
|---|---|
| `window` | One attached client window. Selection state is client-local. |
| `workspace` | Sidebar-level shared container. Holds spaces, metadata, and lifecycle. |
| `space` | Full-layout switcher inside a workspace. Equivalent to a tmux window. |
| `pane` | One split leaf inside a space. |
| `terminal` | One PTY inside a pane. Panes can hold a terminal stack. |
| `split` | The action that divides a space into more panes. |
| `panel` | Internal implementation term. Not user-facing. |

`tab` remains a compatibility alias for `terminal` in the protocol and CLI.

### Shortcuts

Default `preset = "both"` combines the tmux prefix family with the
non-conflicting Zellij bindings:

| Binding | Action |
|---|---|
| `C-b c` | new space |
| `C-b n` / `C-b p` | next / previous space |
| `C-b 0`–`C-b 9` | select space by number |
| `C-b &` | close active space |
| `C-b s` | focus the space strip |
| `C-b W` | new workspace |
| `C-b (` / `C-b )` | previous / next workspace |
| `C-b w`, `C-b b`, or `C-s w` | focus the workspace sidebar |
| `C-b X` | close workspace |
| `C-b T` | new terminal in the focused pane |
| `C-b [` / `C-b ]` | previous / next terminal in the focused pane |
| `C-t 0`–`C-t 9` or `C-b t 0`–`C-b t 9` | select terminal by number in the focused pane |
| `C-b x` | close active terminal |
| `C-b d` | detach |
| `C-b %` / `C-b "` | split left-right / top-bottom |
| `C-b Left/Right/Up/Down` | focus pane |
| `Alt-h/j/k/l` or `Alt-Left/Right/Up/Down` | focus pane |
| `Cmd-k` | clear the focused terminal |

While the workspace sidebar is focused, `j` / `k` and `Ctrl-n` /
`Ctrl-p` move between workspaces, and `c` creates a new workspace.
While the space strip is focused,
`h` / `l` and `Ctrl-p` / `Ctrl-n` move between spaces. `Enter`,
`Space`, `Esc`, and `q` leave either mode.

All of these are remappable via `~/.config/cmux-cli/settings.json`; saves
hot-reload via notify.

`preset = "both"` also includes Zellij's `C-t n/j/k/x` space family and
`C-s n/j/k/w/x` workspace family. Set `"shortcuts": { "preset": "zellij" }`
to add Zellij's pane split chords too: `C-p r` for split right and
`C-p d` for split down.

## Command surface

`cmx` mirrors the macOS cmux CLI's vocabulary where it makes sense.
See [`plans/task-cmx-bootstrap/architecture-overview.md`](plans/task-cmx-bootstrap/architecture-overview.md) §
"CLI surface" for the full list. Every command has a `ClientMsg::Command`
equivalent over the wire, which is how both the Rust attach client and
the planned Swift/web clients will drive the server.

Preferred CLI nouns follow the name table above:

- `workspace` is the sidebar-level container
- `space` is the full-layout switcher inside a workspace
- `terminal` is the pane-local PTY

For compatibility, `tab` still works as an alias for `terminal` in
commands like `new-terminal` / `new-tab`, `rename terminal` / `rename tab`,
and `list-terminals` / `list-tabs`.

Space rename commands are `cmx rename-space <name>` and
`cmx rename space <name>`.

## Architecture

Single Daemon → N Workspaces → N Spaces per workspace → recursive pane tree
→ N Terminals per pane.

Each terminal owns a PTY + a libghostty-vt `Terminal`. Workspaces, spaces,
pane layout, terminals, buffers, scrollback, and shared viewport state are
server-owned. Each attached client window owns its selected workspace, space,
pane, terminal, and viewport mode. When multiple visible clients have
different sizes, the smallest visible pane size wins for the backing PTY,
while larger clients redraw chrome around a top-left terminal surface.

All client ↔ server traffic is MessagePack; Unix socket uses a 4-byte
big-endian length prefix, WebSocket uses one binary frame per message.
Attached clients receive rendered `PtyBytes`, maintain their own libghostty-vt
grid, and render the full cmx UI locally. Host-side effects such as OSC 52
clipboard writes travel as `HostControl` so they do not pollute the grid.
This rendered-grid path is the intended base for web, macOS Swift, and iOS Swift
clients.

Five Rust crates:

- `cmux-cli-protocol` — wire types (`ClientMsg`, `ServerMsg`, `Command`, …)
- `cmux-cli-core` — terminal helpers, settings loader, keybind dispatch
- `cmux-cli-server` — the Daemon + session loop
- `cmux-cli-client` — the Rust CLI attach client
- `cmx` — the `cmx` binary

Plus non-Rust clients:

- `clients/web/` — TypeScript frontend (Vite + xterm.js) — contract
  documented, UI follow-up.
- `clients/swift/` — Swift Package — contract documented, integration
  with the macOS cmux app follow-up.

## Testing

`cargo test` runs every crate's tests. Notable coverage:

- `cmux-cli-protocol` — Hello + `PtyBytes` roundtrip over MessagePack.
- `cmux-cli-core` — settings load/save, keybind parse (C-x forms + raw
  characters), `InputHandler` state-machine across byte batches.
- `cmux-cli-server` — raw-socket e2e (echo → exit), terminal stack switching,
  multi-workspace + multi-space snapshot roundtrip, paste buffer stack + OSC 52,
  keybind dispatch + hot reload, WebSocket attach + token rejection.
- `cmx` binary — server + attach nested-PTY e2e.

## Non-goals

- GUI rendering in this tree. That's the macOS cmux app's job.
- Reimplementing the VT parser — libghostty-vt already does it.
- Windows support in the first pass. Unix PTY + Unix socket only.

## License

MIT (same as macOS cmux).
