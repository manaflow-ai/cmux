# Native Desktop Protocol

This document records the desktop cutover contract for the Rust `cmx` native
client protocol. The wire schema remains the `cmux-cli-protocol` v3
MessagePack schema unless this document explicitly calls out a future field.

## Transport

Local desktop clients use AF_UNIX sockets with the existing cmx frame format:

1. 4-byte big-endian unsigned payload length.
2. MessagePack payload encoded with named fields.

Remote desktop clients use the same message schema over WebSocket or iroh.

During migration there are two sockets:

- Native desktop socket: Swift desktop UI to Rust `cmx`.
- Compatibility socket: existing `CMUX_SOCKET_PATH` CLI/API contract.

The final command authority for both sockets is Rust state. Desktop tagged
builds start `cmx server --compat-socket <CMUX_SOCKET_PATH>` so legacy CLI/API
callers and native Swift projection calls mutate the same daemon model. When
the cmx backend feature flag is enabled, Swift does not bind the legacy socket.

The compatibility socket is deliberately dual-protocol:

- New cmx CLI/API clients may use the framed MessagePack cmx protocol.
- Existing cmux callers may keep using newline-delimited text commands such as
  `ping`, `list_workspaces`, `new_workspace`, `new_split`, `list_panes`,
  `new_surface`, `send`, `send_key`, and `read_screen`.
- Shell-integration telemetry commands are accepted on the same path.
  `report_pwd` updates Rust tab cwd state so saved session snapshots restore
  from the latest shell directory; current status/TTY/port/git/PR report
  commands are accepted for compatibility while richer sidebar metadata is
  migrated into the Rust model.
- Existing v2 newline-delimited JSON callers are accepted for the Rust-backed
  system/workspace/surface/pane subset while browser WebView automation remains
  a later Rust/native worker milestone.

## Hello

Desktop clients send `ClientMsg::HelloNative` with:

- `version = PROTOCOL_VERSION`
- `viewport`
- `terminal_renderer = "libghostty"`
- `token` when required by the transport

Swift may also send forward-compatible metadata fields. Current Rust builds
ignore unknown fields until the protocol crate models them directly:

- `client_kind = "desktop"`
- `client_id`
- `window_id`
- `capabilities = ["libghostty_pty_bytes", "webview_worker", ...]`

## Snapshots

`ServerMsg::NativeSnapshot` is the authoritative desktop model projection. It
contains workspaces, spaces, panel tree, focused panel/tab, attached clients,
terminal appearance metadata, and tab kind metadata. `TabInfo.kind` defaults to
`terminal` for older clients; `browser` tabs carry `NativeBrowserInfo` with the
Rust-owned restored URL, title, profile ID, history stacks, render policy,
developer-tools visibility, page zoom, and optional proxy context.

Swift desktop WebView workers send `ClientMsg::NativeBrowserUpdate` after
navigation/title/history/zoom changes. Rust applies that update to the browser
tab model, wakes native snapshots, and includes the updated metadata in durable
`snapshot.json`.

`NativeSnapshot.revision` is the Rust model revision from `Daemon::model_version`.
Swift stores apply snapshots by revision and do not mutate durable desktop
model state locally. Workspace chrome edits that desktop previously held
locally, including descriptions, are sent back as `cmx` commands and reflected
only from the next authoritative snapshot.

Desktop currently maps each workspace to one default space. Rust may keep the
full space model internally for iOS/TUI/future clients.

Terminal appearance metadata includes Ghostty-derived theme, font, and cursor
defaults. Cursor shape and blink behavior come from `cursor-style` and
`cursor-style-blink`; Swift applies those settings to the visible GhosttyKit
manual-IO surface, and Rust applies matching defaults to its authoritative
terminal model and shell spawn environment. The Rust PTY host also derives
`GHOSTTY_SHELL_FEATURES` from `shell-integration-features` so prompt cursor
behavior, including `no-cursor` and steady-vs-blinking cursor integration,
matches Ghostty config. Server-side replay/grid snapshots treat `CSI 0 q` and
`CSI q` as resets to the configured Ghostty cursor default, not libghostty-vt's
standalone fallback, so reconnect replay tails do not override the configured
caret shape or blink behavior.

## Terminal Bytes

For native libghostty clients:

- Rust sends `ServerMsg::PtyBytes { tab_id, data }` for replay and live PTY
  output.
- Swift feeds the bytes directly into a GhosttyKit manual IO surface.
- Swift sends `ClientMsg::NativeInput { tab_id, data }`.
- Swift sends `ClientMsg::NativeLayout { terminals }` for every visible
  terminal. Rust owns resize arbitration.
- Swift sends `ClientMsg::RequestPtyReplay { tab_id }` when a renderer needs
  authoritative replay.

Future `PtyBytes` sequencing should be additive and optional so older native
clients can continue to decode frames.

## State

Desktop launchers should pass `--state-dir` or `CMX_STATE_DIR` for isolated
state. The cmx server stores its structure snapshot at
`<state-dir>/snapshot.json` when a state directory is supplied.

Tagged desktop debug builds should use state such as:

```text
/tmp/cmux-cmx-<tag>/cmx-state/
```

The `/tmp/cmux-<tag>` path is reserved by the desktop reload script as a
DerivedData compatibility symlink.

Release desktop builds should use a platform application-support directory such
as:

```text
~/Library/Application Support/cmux/cmx/
```

The current snapshot carries structure, bounded PTY replay chunks, tab
activity/bell markers, browser panel metadata, and live browser metadata
updates from the Swift WebView worker. Full desktop cutover still requires
disk-spilled terminal scrollback and cmx command authority for all browser
automation operations.

## Desktop Session Import

Before starting the local desktop server, the macOS launcher may run:

```text
cmx --state-dir <state-dir> import-desktop-session --source <swift-session.json>
```

This hidden command is the one-way bridge from the old Swift desktop session
store into Rust-owned cmx state. On a fresh state directory it:

- Parses the Swift `AppSessionSnapshot` JSON.
- Flattens imported windows into the cmx workspace list.
- Creates exactly one default cmx space per imported desktop workspace.
- Imports terminal panels, cwd/title metadata, browser URL/profile/history
  metadata, split layout, active workspace,
  active terminal, pinned workspace state, workspace description, workspace
  color, and manually-unread panel state.
- Writes `<state-dir>/snapshot.json`.
- Copies the old Swift source file to
  `<state-dir>/desktop-session-import-source.json`.
- Writes `<state-dir>/desktop-session-import.json` with a deterministic source
  fingerprint and imported workspace/terminal counts.

If the marker already exists, the command exits successfully without re-reading
or overwriting Rust state. If `snapshot.json` already exists but the marker is
missing, the command writes a marker with
`status = "skipped_existing_cmx_snapshot"` and preserves the existing Rust
snapshot. This keeps the import one-way and prevents the old Swift store from
becoming a dual-write source after cmx has taken ownership.
