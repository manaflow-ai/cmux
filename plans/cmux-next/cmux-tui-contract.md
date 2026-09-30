# cmux next: cmux-tui daemon contract for the Swift frontend

Research note for `REWRITE.md` goal 2 (terminals and layout live in the daemon).
Paths are relative to the `feat-cmux-next` worktree. `T/` = `cmux-tui/`.
`core/` = `T/crates/cmux-tui-core/src/`. `G/` = `ghostty/include/ghostty.h` at the
pinned submodule SHA `9961d09b` (the worktree submodule is not initialized; read
with `git -C repo/ghostty show 9961d09b:include/ghostty.h`). Line numbers are
from 2026-09-28.

## 0. Summary of decisions this note recommends

1. Launch the daemon with the bundled binary: `Contents/Resources/bin/cmux-tui
   --session <S> --json server ensure`. It spawns a `setsid` headless owner that
   survives app quit. Per-tag isolation = unique session name plus
   `CMUX_TUI_STATE_DIR`.
2. Speak raw protocol v12 (JSON Lines on the Unix socket) for the first pass.
   Resource API v2 (`cmux.protocol/2`) is served on the same socket and is the
   long-term public surface, but raw v12 is the documented frontend path and has
   byte attach.
3. Render terminals with GhosttyKit in `GHOSTTY_SURFACE_IO_MANUAL_MIRROR`, fed
   by `attach-surface mode:"bytes"`. Do not use render mode, and do not copy
   TerminalBytesDemo's NSTextView renderer.
4. Hand-write a Swift 6 `Codable` client. Do not write a Swift codegen emitter
   now; `spec/sdk-schema.json` has drifted from the server.
5. Add daemon fields for shared durable state (groups, pin, git branch, cwd in
   raw tree, workspace color/icon, notification ack). Put per-window
   presentation in a `personal` frontend projection. Keep hover, drag, scroll,
   and animation state client-local.

## 1. Daemon lifecycle

### 1.1 Socket discovery

- Resolution order, server side: `$XDG_RUNTIME_DIR`, `$TMPDIR`, `/tmp`, then
  `cmux-tui-<uid>/<session>.sock`. Long paths fall back to `/tmp/...`, then to
  `cmux-tui-hashed-<uid>/<sha256(session)>.sock` (`T/spec/transports.md:27-50`).
  `default_socket_path(session)` is `core/server.rs:589`.
- Client order: explicit path, non-blank `CMUX_TUI_SOCKET`, non-blank
  `CMUX_MUX_SOCKET`, then the derived path (`T/bindings/SOCKET-DISCOVERY-CONTRACT.md:1-5`).
  That file is a target, not normative. SDKs currently disagree on empty values
  and path-length rules (`:8-13`). Swift must implement the full algorithm in
  `transports.md:27-50`, including the `sun_path` byte limit and the hashed
  fallback. Better: do not derive the path at all. Use the `socket` field that
  `server ensure` prints (1.3).
- Session names must be one non-empty path component. Reject `.`, `..`, `/`,
  `\`, NUL, controls, and Unicode line separators (`transports.md:52-58`).
- Security is filesystem mode only: dir `0700`, socket `0600`
  (`transports.md:122-147`). Anyone who can connect has full session authority.
  `CMUX_TUI_SOCKET`, inherited by every child shell, is an ambient full
  capability (`transports.md:146-147`).
- The same socket serves raw v12 and resource API v2. `handle_connection_message`
  routes any line where `is_resource_protocol_message` is true to v2
  (`core/server.rs:9233`, `:9247-9249`). Other lines go to raw v12.

### 1.2 Session identity and durable state

- `--session <name>` (default `main`) selects the socket. `--socket` overrides
  the path only. `--state <root>` or `CMUX_TUI_STATE_DIR` selects durable state
  (`T/crates/cmux-tui/src/main.rs:435-439`, `core/platform.rs:323-331`).
- macOS default state: `~/Library/Application Support/cmux-tui/sessions/<session
  component>/`. SQLite in WAL mode with `synchronous=FULL` and `fullfsync`. One
  exclusive writer lease per session DB, so a second daemon fails startup
  (`transports.md:77-84`, `core/workspace_registry.rs:700-702`).
- Workspace identity is the lowercase UUID `key`. Numeric `id`s are daemon-local
  and change on restart (`commands.md:204-208`, `frontends.md:73-83`). Tabs carry
  `terminal_id`, `terminal_resource_id` (`term_…`), `tab_resource_id`, and
  `terminal_incarnation` (`core/server.rs:9831-9878`). Swift model identity must
  use these durable ids and treat numeric `surface`/`pane`/`screen` ids as
  handles that are valid for one generation only.
- `frontends.md:73-77`: use a stable profile identity as the session. Do not
  create a new session per launch.

### 1.3 Starting or finding the daemon

`server ensure` is the single entry point that both the TUI and the CLI use
(`T/crates/cmux-tui/src/local_owner.rs:1-16`, `:95-137`):

1. Probe the socket and `identify`. If the owner is starting, poll every 25 ms
   (`local_owner.rs:139-178`).
2. If absent, take `SocketStartLock`, probe again, and spawn
   `self_exe --headless --session S --socket P [--state] [--term]`. The child
   gets null stdio and `setsid()` (`local_owner.rs:319-360`).
3. Wait until ready, with a 10 s deadline (`local_owner.rs:29`).

CLI: `cmux-tui --session S --json server ensure` prints
`{status:"running"|"started", session, socket, pid, generation, message}`
(`T/crates/cmux-tui/src/cli/lifecycle.rs:330-366`, `--json` parsed at
`T/crates/cmux-tui/src/cli.rs:362-365`). Errors map to `EnsureError`
(`local_owner.rs:67-81`): `WrongOwner`, `DifferentSession`,
`UnsupportedProtocol`, `NotReady`, `Spawn`.

Recommended Swift launch path:

- Bundle the binary at `Contents/Resources/bin/cmux-tui`. The install path
  already exists: `scripts/install-cmux-tui-client.sh:1-10` (manifest download
  with Sigstore attestation, or `CMUX_TUI_CLIENT_LOCAL`), called from
  `scripts/reload.sh:2089`. The owner is spawned from `self_exe`
  (`local_owner.rs:320`), so the daemon runs from the app bundle path.
- Run `server ensure` in a `Process` off the main actor. Then connect to the
  printed `socket`, `identify`, and check `app=="cmux-tui"`, `protocol==12`, and
  the required capabilities (`frontends.md:25-41`).
- Environment: the owner inherits the launching env minus 5 identity variables
  (`local_owner.rs:293-302`). A Finder-launched app has the minimal launchd
  `PATH`, so every shell the daemon spawns inherits it. The app must build a
  login-shell environment before `server ensure`. `TECH-DEBT-BOARD.md:374` lists
  cwd/env as a known cut of the quit/reopen work.
- Upgrade: when the bundled binary's `identify.version` or `build_commit`
  differs from the running daemon, call `shutdown-daemon {pid, generation}`
  (`commands.md:257-287`), wait for `daemon-shutdown` (`events.md:805-829`),
  then run `server ensure` again. PTY hosts are separate durable processes that
  the new owner adopts (`spec/terminal-host.md:1-3`, `:414-425`,
  `spec/session-journal.md:575-577`). Bytes emitted while no daemon tap exists
  are recovered visually from a snapshot, not byte-exactly
  (`terminal-host.md:416-425`).

### 1.4 Per-tag isolation (dev builds)

- Session name `cmux-dev-<tag>` (release: `main` or a stable profile name).
  The socket and the state component both derive from it.
- Also set `CMUX_TUI_STATE_DIR=~/Library/Application Support/cmux/tags/<tag>/tui`
  in the `server ensure` env so tag state never shares a root with release
  state. `run_ensure` hardcodes `state: None` (`lifecycle.rs:341-348`), so only
  the env var reaches the owner. The owner inherits the env.
- Config: `CMUX_TUI_CONFIG` selects the daemon config file
  (`spec/native-frontend.md:101-104`). Point dev tags at a tag-local file.
- A normal launch attaches to a live socket before `--state` or `--ephemeral`
  apply (`transports.md:70-75`). Isolation therefore depends on the session
  name. Never reuse `main` in a dev build.

### 1.5 What happens when the frontend quits

- The owner is detached (`setsid`, null stdio). It keeps running after every
  client disconnects (`docs/configuration.md:361`, `server.detached_owner`
  defaults to `true`).
- Closing a connection removes only that client's views, leases, size claims,
  and browser-provider lease. Terminals keep running with zero attachments
  (`docs/protocol.md:150-158`, `frontends.md:47-55`). Canonical PTY geometry
  freezes when its geometry owner disconnects (`commands.md:127-150`).
- Optional bound: `set-terminal-idle-policy` closes a terminal after N seconds
  with no attach (`protocol.md:150-158`, capability `terminal-idle-close-v1`).
- Known cuts (`T/docs/TECH-DEBT-BOARD.md:374`): no launchd supervision, so the
  daemon does not restart after a crash until the next `ensure`. No orphan
  cleanup. Startup mutation trap: the native TUI calls `new-workspace` on every
  local start (`native-frontend.md:80-97`). Swift must not copy this. Create a
  workspace only when the tree is empty.

## 2. Protocol (raw v12)

### 2.1 Framing and connection rules

- One UTF-8 JSON object per line on the Unix socket. The request envelope is
  `{id?, cmd, ...}`. The response is `{id?, ok:true, data}` or `{id?, ok:false,
  error, error_code?, error_delivery?}`. Events are `{event, ...}` with no id
  (`transports.md:81-120`). Route by `id` vs `event`. Events can arrive before
  the response to the request that caused them (`frontends.md:123`,
  `events.md:90-92`).
- Limits: inbound 16 MiB per line. Server-to-client up to 32 MiB (VT replay)
  (`transports.md:149-157`).
- Commands start serially per connection (`transports.md:294`). A slow reader
  loses streams: a 4,096-event subscriber mailbox, then `overflow`. A 2 s
  write deadline on the control reserve closes the connection
  (`transports.md:302`). The socket reader must never block on the main actor.
- One shared connection allows at most one subscription and one attach per
  surface. There is no stream id or cancel in v12 (`transports.md:300`,
  `events.md:28`). Use a dedicated connection per attach when independent
  teardown matters, or use `detach-attached-view` (lease capability).
- Reconnect = new generation. Drop pending ids and buffered events. Then
  `identify`, `subscribe` first, then snapshot, then reattach
  (`transports.md:304`).

### 2.2 Version and capabilities

`identify` returns `{app, version, build_commit?, ghostty_commit?, protocol:12,
capabilities[], session, pid, registry_id, generation, workspace_revision}`
(`commands.md:210-254`). Echo the used capabilities through `set-client-info
{kind:"frontend", capabilities}` (`frontends.md:27-41`, `core/server.rs:733-740`).
Required for this app: `view-attachment-lease-v1`, `view-attachment-detach-v1`,
`attach-initial-size`, `workspace-registry-v1`, `viewport-splits-v1`,
`viewport-column-resize-v1`, `layout-undo-v1`, `creation-receipts-v1`,
`creation-attempt-keys-v1`. Add `browser-pointer-frame-guard-v1` only if the
app renders daemon browser frames, which it should not (section 5).

### 2.3 Tree snapshot and subscription

1. `{"cmd":"subscribe","tree_events":"deltas"}`. Buffer events immediately.
2. `{"cmd":"list-workspaces"}` returns `Tree`. Apply it, then drain the buffer
   (`frontends.md:45`, `events.md:88`).
3. Apply `workspace-*` / `screen-*` / `pane-*` / `tab-*` deltas. Each carries
   the full `entity` plus parent ids and `index` (`events.md:241-262`).
   Workspace deltas carry `workspace_revision`: apply only revision+1, and
   refetch on a gap or generation change (`events.md:247-252`).
4. `tree-changed` = full resync barrier (`events.md:472-494`). `layout-changed
   {screen}` = refetch the layout (`events.md:496-516`). Selection, reorder,
   split ratio, and zoom have no delta (`events.md:260-261`). Plan for frequent
   refetches during a drag.

Wire shape (from the serializer, which is richer than `commands.md:38-125`):
`workspace_json` (`core/server.rs:9977-10000`): `id, resource_id, key, short_id,
name, active, screens`. `screen_json` (`:9888-9946`): `id, resource_id,
short_id, name, active, active_pane, zoomed_pane, layout, panes`, plus
`viewport_splits`, `viewport_base_width`, and `columns[{id, width, layout}]`
when horizontal columns are active. `pane_json` (`:9828-9886`): `id,
resource_id, short_id, name, active_tab, focused_at, tabs[]`. Tab: `surface,
tab_resource_id, content_resource_id, terminal_id, terminal_resource_id,
terminal_incarnation, kind, browser_*, url, notification{notification, unread,
level}, name, title, size, dead`. Layout nodes (`:9485-9506`): `leaf{pane}`,
`split{split, dir:"right"|"down", ratio, a, b}`, and `stack{panes, expanded}`.

`active*` fields are shared compatibility defaults, not user focus. Keep focus
client-local and never send `focus-pane`/`select-*` for ordinary UI focus
(`docs/concepts.md:17-21`, `frontends.md:56-62`).

### 2.4 Mutations a GUI needs (all implemented, `core/server.rs:688-1425`)

| Need | Command | Notes |
| --- | --- | --- |
| New workspace | `create-workspace {name?, key?, origin, mutation_id}` | Durable, exactly-once, no terminal (`server.rs:1098-1108`). `new-workspace` also spawns a PTY. |
| New terminal in workspace | `create-terminal {workspace\|key, argv?, command?, cwd?, name?, cols, rows, terminal_id?, origin, mutation_id}` | Frontend may reserve `terminal_id` (`server.rs:1110-1133`). |
| New tab | `new-tab {pane?, cwd?, cols?, rows?}` | No argv (`server.rs:968-975`). |
| New screen | `new-screen {workspace?}` | |
| Split | `split {pane, dir, cols?, rows?}`, `new-pane {pane}` | |
| Scrolling column | `new-pane-right {pane, width=0.667}` | Needs `viewport-splits-v1` (`commands.md:1579-1628`). |
| Column width | `set-viewport-pane-width {pane, width 0.1..1.0, transaction?}` | Needs `viewport-column-resize-v1` (`commands.md:1630-1675`). |
| Divider drag | `set-split-ratio {split, ratio 0.05..0.95, transaction?}` | Key dividers by `SplitId` (`protocol.md:93-99`, `concepts.md:13`). Same `transaction` coalesces into one undo entry. |
| Undo layout | `undo-layout {pane, revision?, confirm_close}` | Two-phase confirm (`protocol.md:77`). |
| Close | `close-surface`, `close-pane`, `close-screen`, `close-workspace`, `close-terminal {terminal_id, terminal_incarnation?}` | Closing a view never kills the PTY. Only `close-terminal` does (`concepts.md:47-53`). |
| Rename | `rename-surface` (tab), `rename-pane`, `rename-screen`, `rename-workspace` | |
| Move | `move-tab {surface, pane, index}`, `move-tab-to-workspace`, `move-workspace {key, index, origin, mutation_id}`, `move-terminal`, `swap-pane`, `zoom-pane` | |
| Colors | `set-default-colors` | Keeps daemon replay colors in step with the Ghostty theme. |

Durable workspace mutations take `origin` + `mutation_id`, with optional
`expected_generation`/`expected_revision` guards. Retries with the same ids
replay the original result (`commands.md:186-208`, `frontends.md:79-83`).
Apply the local response at once, then dedupe the event by mutation identity.

### 2.5 Attach a terminal

`{"cmd":"attach-surface","surface":N,"mode":"bytes","cols":C,"rows":R}`
(`commands.md:3241-3330`). With `attach-identity-v1`, send
`expected_generation` + `expected_terminal_id` and omit `surface`
(`commands.md:3265-3274`, `server.rs:1400-1416`).

Stream: `vt-state{cols, rows, data(b64), colors{fg, bg, cursor, selection_*,
cursor_style, cursor_blink}}`, then `(output{data} | resized{cols, rows,
data/replay, kitty state} | colors-changed | scroll-changed)*`, then `detached`
(`events.md:885-1091`, `frontends.md:131-137`). The replay is capped at about
10 MiB (`core/surface.rs:596-598`). It starts with RIS on the minimal path
(`T/crates/ghostty-vt/src/terminal.rs:3953-3956`) and appends mouse-format and
title suffixes (`terminal.rs:3326-3331`). The replay omits DECSCUSR, so apply
`cursor_style`/`cursor_blink` after the replay (`commands.md:3252`). On
`resized`, discard the mirror and rebuild it from the fresh replay before later
output (`events.md:94`). The Rust reference client is
`T/crates/cmux-tui/src/session/remote.rs:2285-2345`.

The response carries `lease`. Use `resize-attached-view`,
`release-attached-view-size` (while hidden but cached), and
`detach-attached-view` (`protocol.md:144-148`).

Sizing (`commands.md:127-169`): every visible view sends `resize-surface
{surface, cols, rows}` as a passive hint. The focused or visible owner claims
geometry with `set-client-sizing {surface, enabled:true, exclusive:true}`. Only
the owner resizes the PTY. Other views crop, pan, or scale. Release when
hidden. Do not re-report because another client resized the terminal.

Input: `send {surface, text?|bytes(b64)?, paste?}` (`commands.md:937-992`) and
`send-key {surface, keys[]}` (`server.rs:889-892`). Render mode has no
mouse/focus input (`frontends.md:145`). Byte mode + Ghostty manual-mirror
avoids that gap (section 3).

Alternative data plane: `mint-terminal-renderer{,-by-terminal}` returns a
one-use credential for the binary CMTH terminal-host protocol
(`server.rs:928-941`, `terminal-host.md:372-376`). Renderer v4 interop is
"partial" (`terminal-host.md:427-446`). Do not use it in the first pass. It is
the later path to remove base64 JSON overhead.

### 2.6 Frontend projections

`get-frontend-projection` / `put-frontend-projection {frontend, scope:
"personal"|"shared"|custom, subject_key, schema_version, projection(JSON ≤1
MiB), expected_projection_revision?, origin, mutation_id}`. The projection has
its own CAS and exactly-once ledger, and it does not bump `workspace_revision`
(`commands.md:815-847`). The change event `frontend-projection-changed`
carries no body, so refetch it (`events.md:320-332`). Target identity is
`(frontend_id, window_id)` with a fenced generation per relaunch
(`native-frontend.md:30-53`). `journal-frontend-event` records settled focus,
resize, and viewport observations (`commands.md:849-878`).

Window records and the no-empty-window rule (decision 2026-09-30): the macOS
app's `personal` window document (`WindowStateDocument`, subject `windows`)
lists each window's workspaces, and a window exists only while it holds at
least one. The daemon stores the projection as opaque JSON with CAS, so it can
hold a record with no workspaces (written by an older build's empty state, by
another client, or left when every workspace of a window closed while the app
was not running). The daemon does not enforce the rule: it would have to parse
one frontend's schema and mutate a projection on a workspace close, which
couples the daemon to a client format and races the app's CAS writes, for no
gain, since the app is the only reader. The app enforces it in one place:
`WindowStateDocument.prune` drops every record without a live workspace on
each save, and `WindowRegistry(records:)` skips such records on load, so none
is ever shown. Revisit if another frontend (iOS, TUI) starts reading window
records.

### 2.7 Agents and notifications

- `list-agents {surface?, state?}` and event `agent-changed {surface, state:
  working|blocked|idle|done|unknown, source, session, agent?, updated_at_ms}`
  (`commands.md:3764-3818`, `events.md:1093-1126`).
- `notify {title, body, level, surface?}` and event `notification {notification,
  title, body, level, surface}` (`commands.md:3713-3762`, `events.md:679-701`).
  An inactive target surface gets one retained `tab.notification.unread`
  marker, and a later notification overwrites it. The marker clears when the
  target is "selected" (`events.md:693`). It is held in memory in `Mux`
  (`core/mux.rs:1533-1537`). The same notification can arrive on subscribe and
  attach streams, so dedupe by id (`events.md:701`).

## 3. Terminal rendering with GhosttyKit

### 3.1 What TerminalBytesDemo does (do not copy it)

`T/apps/macos/TerminalBytesDemo` does not use GhosttyKit. It links the Rust
static lib `cmux_terminal_client` (`Package.swift:17-39`), which owns
Iroh/Noise transport, the CMTH `terminal-bytes-v1` stream, and a local
libghostty-vt parser (`README.md:1-7`, `:44-64`). Swift reads frame rows through
`cmux_terminal_client_copy_frame*` (`T/crates/cmux-terminal-client/include/cmux_terminal_client.h:99-114`)
and draws them as plain attributed text in an `NSTextView`
(`Sources/TerminalBytesDemo/TerminalView.swift:51`, `:305-310`). It proves the
data plane and the geometry handshake, not the rendering quality. It connects
through an invitation over Iroh, not the local socket.

### 3.2 GhosttyKit external-byte API (exists in the cmux fork)

`G/` (`ghostty/include/ghostty.h` @ `9961d09b`):

- `ghostty_surface_io_mode_e` (`G:552-559`): `GHOSTTY_SURFACE_IO_EXEC=0`,
  `GHOSTTY_SURFACE_IO_MANUAL=1`, `GHOSTTY_SURFACE_IO_MANUAL_MIRROR=2`.
  MANUAL_MIRROR: "the embedder owns the PTY and terminal protocol while Ghostty
  mirrors output for rendering and encodes user input. Parser-generated
  terminal replies are suppressed so the owning terminal core replies only
  once." The daemon's libghostty-vt answers DA/DSR, so this is the correct mode.
- `ghostty_surface_config_s.io_mode`, `.io_write_cb` (type
  `ghostty_io_write_cb(void*, const char*, uintptr_t)`), `.io_write_userdata`
  (`G:561`, `G:627-629`). Ghostty sends encoded keys, mouse reports (per the
  mouse modes it mirrored from output), focus reports, and bracketed paste to
  this callback on its IO thread. Forward them as `send {bytes}` with
  `paste:false`, because Ghostty already applied its mirrored mode 2004.
- `ghostty_surface_process_output(surface, bytes, len)` (`G:1587-1589`) feeds
  daemon bytes. It takes the renderer-state mutex synchronously. Call it on a
  serial non-main queue.
- `ghostty_surface_update_theme_config` (`G:1373-1380`) must be serialized with
  `process_output` in manual mode.
- `ghostty_surface_restore_kitty_replay(...)` (`G:1614-1628`) restores Kitty
  image aliases, limits, and cursors around a replay. It is valid only on a new
  surface before other output. This matches the `kitty_image_aliases` /
  `kitty_state` fields on `vt-state`/`resized` (`remote.rs:2326-2333`).
- `ghostty_surface_set_size` / `ghostty_surface_size` (`G:1443`, `G:1456`) give
  the pixel-to-cell grid to report through `resize-surface`.
- There is no reset API. On `resized`, create a fresh surface offscreen, apply
  `restore_kitty_replay` or the replay, then swap it in. Feeding `ESC c ESC[3J`
  + replay into the old surface works for text but breaks the Kitty restore
  precondition.

Existing Swift uses to reuse (the old app, a pattern source only; goal 9 says
do not port it):
`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurfaceIOMode.swift:4-29`
(mode enum), `TerminalSurface+RuntimeSurfaceCreation.swift:65-77` (config
wiring), `TerminalManualIOWrite.swift:10-32` (C trampoline),
`TerminalSurfaceRemoteOutputLane.swift:17-60` (serial output lane with a close
fence), and teardown ordering in
`Lifecycle/TerminalSurfaceRuntimeTeardownCoordinator.swift:168-190` (the
io_write userdata must outlive `ghostty_surface_free`).

### 3.3 Why bytes + MANUAL_MIRROR, not render mode

`frontends.md:139` recommends render mode for "future Swift frontends" to
avoid parser drift. For this app the drift risk is low because the daemon's
`ghostty-vt-sys` builds from the same repo `ghostty/` submodule
(`T/crates/ghostty-vt-sys/build.rs:9-13`), so both parsers are at one commit
in a single-repo build. Render mode would discard Ghostty's Metal renderer,
font shaping and ligatures, Kitty graphics, native selection, IME, and search,
and it lacks mouse and focus input (`frontends.md:145`). Residual risk: a
daemon built from a different ghostty commit than the app (the upgrade window
in 1.3). Compare `identify.ghostty_commit` with the app's GhosttyKit commit
and force the daemon handoff on a mismatch.

## 4. Swift bindings

- No Swift SDK exists. `T/bindings/` has cpp, go, java, python, rust,
  typescript, and zig. `spec/bindings.md:236-237`: "The next likely SDKs are C#
  and Swift", after the first seven ship stable.
- Codegen input: `T/spec/sdk-schema.json` (schema_version 2, profile
  `cmux-tui-mux` v12, 120 types, 113 commands, 49 events).
  `bindings/codegen/generate.py` loads it through `ir.py`. Each emitter is one
  Python module, `emit_typescript.py` 475 lines to `emit_go.py` 2432 lines. A
  Swift emitter is about 800-1200 lines plus golden tests and
  `validate.py` hookup.
- The schema is behind the server. `Screen` in the schema has `id, short_id,
  name, active, active_pane, zoomed_pane, layout, panes`
  (`sdk-schema.json:1582`). The server also emits `resource_id`,
  `viewport_splits`, `viewport_base_width`, and `columns`
  (`core/server.rs:9900-9944`). Generated types would silently lose scrolling
  columns.
- Recommendation: hand-write `Codable` structs for the about 35 commands and 20
  events this app uses, decoded leniently (unknown fields ignored, unknown
  events kept as raw JSON). Test against the serializer, not the prose spec.
  Revisit codegen once the schema is fixed. Fixing the schema is a daemon-side
  task.

## 5. Gaps: GUI needs the daemon lacks

Placement key: **D** = daemon field or command (shared durable tree, visible to
TUI, iOS, CLI, agents). **P** = frontend projection document (`personal` per
user and window, or `shared`). **L** = client-local (memory or UserDefaults).

| Need | Today | Recommend |
| --- | --- | --- |
| Workspace groups (sidebar sections) | None. `Workspace` is flat (`server.rs:9983-9999`). | **D**: group entity `{key, name, color?, order}` plus `Workspace.group_key`, durable mutation envelope, `group-*` deltas. Group collapse state is **P**. |
| Sidebar ordering | `move-workspace` exists (root order) | **D** already. Extend it with in-group index when groups land. |
| Tab pinning | None | **D**: `Tab.pinned`. It changes ordering and close semantics (close-others, close-right) for every client. |
| Tab title | `title` + `title-changed`, `name` via `rename-surface` | Exists. |
| Tab cwd | In v2 terminal snapshot `cwd` (`core/resource_api.rs:448-450`, `mux/terminal_directory.rs:7`), not in the raw `Tab` | **D**: add `cwd` to the raw tab or terminal JSON plus a delta, or consume v2 `session.events`. |
| Git branch / dirty | None | **D**: compute on the machine that hosts the PTY, keyed by terminal cwd. It must be correct for remote daemons, so the frontend cannot do it. |
| Per-tab icon | `kind`, agent `agent` name, `process-info` | **L** derive (agent, then process, then kind). A user-chosen icon or color is **D**. |
| Workspace color, icon, description | None | **D** fields on the workspace registry. |
| Notifications / unread | Event only. One unread marker per tab, in memory (`mux.rs:1533`). Clearing is tied to "selecting" the target (`events.md:693`), which conflicts with client-local focus. No list, no ack, no timestamp in raw v12. | **D**: persist notifications, add `created_at_ms` (the proposed extension, `events.md:1130-1158`), and add raw `notification-ack` (v2 already has `notification.list/ack/clear`, `resource-api-v2.md:452-453`). Add workspace unread rollup. Per-user read state could be **P**, but one user per daemon makes **D** simpler. |
| Agent status | `list-agents`, `agent-changed` | Exists. |
| Browser tabs owned by the frontend (WebKit/CEF) | Daemon browser tabs are CDP targets published by a trusted-local provider (`browser-provider-v1`, `commands.md:524-571`, `docs/browser-panes.md:1-39`). The daemon renders PNG frames. | CEF: the app registers as browser provider (CEF exposes CDP), so tabs stay canonical, agent-browser works, and the app draws CEF natively and never attaches frames. WebKit has no CDP: **D** needs a new tab kind (such as `kind:"web", renderer:"frontend"`) that stores `url`, `title`, and favicon and never attaches. Until then keep WebKit tabs in **P** with a placeholder. Note: a provider disconnect keeps the canonical tab (`browser-panes.md:39`), but page state dies with the app process unless CEF or WebKit restores it. |
| Screen visibility (screens UI hidden until opt-in) | Screens always exist; one per workspace by default | **L** preference. The daemon needs nothing. |
| Selected workspace/screen/tab per window, sidebar width, window ↔ workspace assignment, tab strip mode (Chrome vs bonsplit-like) | Compatibility `active*` only | **P** `personal`, subject `(frontend_id, window_id)` (`native-frontend.md:30-53`). Transient hover, drag, and scroll are **L**. |
| Drag a tab to a new split | No single command. `split` spawns a new PTY, then `move-tab` needs a close of the empty tab. | **D**: `split {pane, dir, tab:<surface>}`, which moves an existing tab into the new pane atomically. |
| Reorder columns and panes, move a pane across columns | `swap-pane` (neighbor or target) only. No column move. | **D**: `move-column` / `move-pane {pane, target, position}`. |
| Screen reorder | None | **D** `move-screen` (low priority while screens are hidden). |
| New tab with argv / command | `new-tab` has only `cwd` (`server.rs:968-975`). `create-terminal` has argv but places by workspace only. | **D**: add `argv`/`command`/`name` to `new-tab`, `new-pane`, `split`, and `new-pane-right`. |
| Delta coverage for selection, reorder, layout | `tree-changed` / `layout-changed` refetch (`events.md:260-261`) | **D**: typed `layout-changed{screen, layout}` payload (v2 `session.events` already carries full screen layout per transaction, `resource-api-v2.md:412-416`). |
| Closed-tab history (reopen) | None | **D** later (the journal already records the topology). |
| Shell environment for spawned PTYs | Inherits the owner env | **D/launch**: login-shell env capture at `ensure` time, or a daemon-side `terminal_defaults.env`. |
| Crash supervision | None (`TECH-DEBT-BOARD.md:374`) | Launch: optional `launchd` agent per session. Until then, re-`ensure` on every reconnect failure. |

## 6. Recommended Swift client architecture

```
DaemonLauncher (struct)           -- runs bundled `cmux-tui --json server ensure` with login env,
                                     returns {socket, pid, generation}; handles version handoff.
MuxConnection (actor)             -- owns one Unix-socket FileHandle / NWConnection.
  send<C: MuxCommand>(C) async throws -> C.Response
  events: AsyncStream<MuxEvent>   -- fed by a dedicated reader Task that never awaits the
                                     main actor (the server drops slow readers).
  state: connecting | ready(generation) | closed(reason)
TerminalStream (actor, 1 per attached view, own connection)
  attach(identity, size) -> lease; output: AsyncStream<TerminalFrame>  (.replay/.bytes/.resized/.colors/.detached)
  input(Data), resize(cols, rows), release(), detach()
MuxStore (@MainActor @Observable) -- mirror of Tree keyed by durable ids
  workspaces: IdentifiedArray<WorkspaceKey, WorkspaceModel>; applies snapshot + deltas + revision gate
MuxCommands (@MainActor)          -- one shared action path used by palette, menus, shortcuts, CLI
GhosttyTerminalHost (NSView)      -- one ghostty_surface_t in MANUAL_MIRROR; serial output lane;
                                     io_write_cb -> TerminalStream.input
```

Rules:

- **One control connection** (`MuxConnection`) for `subscribe` + mutations. A
  reader task splits lines, decodes the envelope, resumes the matching
  `CheckedContinuation` by `id`, and yields events into an `AsyncStream`. Ids
  are monotonically increasing `UInt64` per generation. On disconnect, fail
  every pending continuation with `.connectionLost(generation)` and never
  resend non-idempotent legacy mutations blindly (`transports.md:296-298`).
  Durable mutations resend with the same `mutation_id`.
- **One connection per attached terminal view** (`TerminalStream`). The reason:
  v12 has no stream cancel, commands are serial per connection
  (`transports.md:294-300`), and a heavy `output` stream must not delay tree
  mutations or trip the 2 s write deadline on the control connection. Base64
  decode and `process_output` run on the stream's serial queue. Only a
  "presented" signal hops to the main actor.
- **Startup barrier**: `identify` → `set-client-info` → `subscribe{deltas}`
  (events buffered in the store's inbox) → `list-workspaces` →
  `get-frontend-projection{personal, window}` → apply → drain. On
  `tree-changed`, `overflow`, gap, or generation change, refetch the snapshot,
  rebuild numeric-handle maps, and reattach visible terminals by
  `terminal_id`.
- **Observation model**: `@Observable final class WorkspaceModel` / `ScreenModel`
  / `PaneModel` / `TabModel`, identified by `key` / `resource_id` /
  `tab_resource_id` / `terminal_id`. Numeric ids are stored as `handle` fields
  and replaced on resync. Layout is an `indirect enum LayoutNode { leaf(PaneID),
  split(SplitID, Axis, ratio, a, b), stack([PaneID], expanded) }` plus
  `columns: [Column(id: SplitID, width, root)]`. Client-local focus, scroll,
  hover, and drag live in a separate `@Observable WindowState` persisted to the
  `personal` projection on settle only.
- **Optimistic UI** only for durable mutations with `mutation_id`: apply
  locally, reconcile with the response, dedupe the echo delta by `(origin,
  mutation_id)`. Divider and column drags send `set-split-ratio` /
  `set-viewport-pane-width` with one `transaction` id per gesture so undo
  coalesces. Throttle to display refresh.
- **Geometry**: a visible terminal view reports `resize-attached-view` or
  `resize-surface`. The focused view in the key window also sends
  `set-client-sizing exclusive:true`. Hidden or cached views send
  `release-attached-view-size`. Offscreen tab-hover previews attach without
  claiming geometry and crop or scale.
- **Swift 6**: `Sendable` value types for wire models, no `DispatchQueue.asyncAfter`,
  and timeouts through an injected `Clock`. The socket actor is the only owner
  of the file descriptor. `ghostty_surface_t` lifetime is fenced by the output
  lane (pattern in `TerminalSurfaceRemoteOutputLane.swift:17-60`).

## 7. Open questions for the owner

1. Raw v12 vs resource API v2 as the long-term client surface. v2 has typed
   `session.events` with full layout per transaction, `notification.ack`, and
   `terminal.input.mouse`, but its `terminal.attach` is render-only; raw bytes
   stay in raw v12 (`resource-api-v2.md:403-409`). A hybrid is plausible: v2
   for the tree, raw v12 for byte attach. This note picks raw v12 only, to keep
   the first pass to one protocol.
2. WebKit tabs as daemon tabs (needs a new tab kind) vs projection-only tabs.
3. Session name for release builds: `main` (shared with the standalone
   `cmux-tui` CLI, so the TUI and the app see the same terminals) or a
   dedicated `cmux-app` session.

## 8. Upstream features from main (catch-up merge 2026-09-30)

The merge of main `4d9bec3bc1d` brought these daemon features. The app uses
none of them yet. Each row says what the app gets if it adopts the feature.

| Feature | Daemon surface | What the app should do |
| --- | --- | --- |
| Shared terminal sizing (`shared-sizing-v1`, main PR 15203) | `core/sizing_policy.rs` reducer (twin of `Packages/Shared/CmuxTerminalSizing`, fixtures in `schemas/terminal-sizing/`, contract `docs/shared-terminal-sizing.md`). Default policy `latest`: the counting view with the newest activity (attach, `set-client-sizing` claim, `send`/`send-key`) sets the grid. Commands `get-size-state`, `set-size-policy` (`latest`, `smallest`, `largest`, `priority`, `fixed`), `set-size-counts`, `note-size-activity`; event `size-state`; `participant`/`size_state` in terminal `attach-surface` responses; identity fields `user_id`, `display_name`, `device_kind`, `device_name` on `set-client-info` (`commands.md` "Sizing", `set-client-info`). | Send `device_kind:"mac"` and a device name in `set-client-info`, so phones of the same user defer to the Mac. Advertise `shared-sizing-v1` to get `size-state` and show who sets the grid (tab chip, size panel, like the legacy app did). Section 2.5 stays correct: `set-client-sizing` now maps onto the reducer. |
| Pending escape sequence on replay (`terminal-pending-sequence-v1`, main PR 15533) | A byte-attach `vt-state` or `resized` replay can end inside an escape sequence. A capable client receives the unfinished bytes in a separate `pending` field and writes them after its own sequences (`commands.md` capabilities, `events.md`). Without the capability, the initial replay carries the bytes inline, but a later `resized` replay that ends mid-sequence cancels the attach stream, so the viewer must reattach. | Add `terminal-pending-sequence-v1` to `DaemonCapabilities.advertised` and write `pending` into the Ghostty mirror after the replay and the cursor-style restore. Until then, the attach loop must treat a `detached` after `resized` as "reattach now". |
| Targeted detach with reasons | `detach-client` takes a `DetachClientTarget` (client or shared-sizing participant); `detached` carries `reason` and `actor` (`DetachReason`, `SizeDetachActor`). | Show why a view was detached (host shut down, superseded, network, someone else) instead of a generic error. |
| `cmux ssh` hardening (main PRs 15116, 15768) | `cmux-remote`: validated ssh argv (`ssh_args.rs`), hardened bootstrap and artifact upload; the CLI side merged into `CLI/` and `CmuxFoundation` (`posixShellWord`, `isOptionLikeSSHDestination`, `SSHControlSocketDirectory`, `UnixSocketPeerCheck`). | Nothing for the daemon client. Any app `cmux ssh` path must go through `cmux-tui`/the CLI, not a new Swift SSH stack. The relay rule "command-bearing params are denied on every method, no exceptions" now holds (skills/cmux-socket-policy/references/remote-relay-authorization.md). |

CLI compatibility gap from the same merge: the new `cmux surface size`,
`size-policy`, `size-to-me`, `disconnect-others`, `size-counts` and
`disconnect-participant` verbs (`CLI/CMUXCLI+SurfaceSizing.swift`) call the
socket methods `terminal.size_state`, `terminal.size_policy.set`,
`terminal.size_counts.set`, `terminal.size_to_me`,
`terminal.participants.disconnect_others` and
`terminal.participant.disconnect`. The cmux-next control socket does not serve
them yet; map them onto the daemon commands above when the size UI lands (see
cli-compat.md).
