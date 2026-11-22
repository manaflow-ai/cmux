# cmux next: one Ghostty (ghostty-next) and pluggable terminal backends

Status: proposal (ghostty-next lead, 2026-10-04). Inputs: Lawrence
2026-10-04 ("switch ghostty of cmux-next completely to manaflow-ai/ghostty-next",
"make ghostty manual IO backend generalizable", "allow cmux apps to bring
over custom backends"), coordinator R71, ghostty-next.md (lane 13),
cloud-ios.md, cloud-parity.md, app-platform.md section 12, the 2026-10-02
inventories in `.cmux-scratch/nx-worker/ghostty-next/`
(`fork-patch-inventory.md`, `vt-port-list.md`).

## 0. Summary

1. Where things are today on feat-cmux-next (`c4b5e50213`):
   - cmux-tui already builds libghostty-vt from the `ghostty-next` gitlink
     (`31627e4b9`, `crates/ghostty-vt-sys/build.rs`); there is no fallback
     to `ghostty`.
   - iOS already links GhosttyNextKit release `ios-v5` (`74e97632d4`)
     through SwiftPM `binaryTarget(url:checksum:)`.
   - Only the Mac app still uses `manaflow-ai/ghostty`: `CmuxNextTerminal`
     (29 files `import GhosttyKit`) links `GhosttyKit.xcframework`, which
     `scripts/download-prebuilt-ghosttykit.sh` / `ensure-ghosttykit.sh`
     produce from the `ghostty` gitlink (`b1a49b6015`).
   So the switch is the Mac app only, plus removing the `ghostty` gitlink
   from feat-cmux-next. `main` (the shipping app) keeps `manaflow-ai/ghostty`.
2. First principle: the cmux-tui session host owns the PTY, the parser state
   that answers queries, scrollback, the canonical grid and snapshots. The
   app's Ghostty surface only renders and encodes input
   (`GHOSTTY_SURFACE_IO_MANUAL_MIRROR`). So the app needs a renderer plus an
   input encoder, and almost none of the desktop fork's PTY, process,
   replay, embedding and theme-picker work.
3. The Mac app needs 7 small fork C APIs that ghostty-next lacks (section
   1.3), one ABI adaptation (clipboard callbacks), and the switch from
   `set_grid_size` + `restore_kitty_replay` + "new surface on resize" to
   ghostty-next's `set_grid` + `restore_snapshot` over the existing cmux-tui
   capability `terminal-snapshot-v1`.
4. Upstream sync is a merge, not a rebase, because cmux pins ghostty-next
   `main` commits. First sync done: ghostty-next PR
   https://github.com/manaflow-ai/ghostty-next/pull/13 (clean merge of
   upstream `f96c9711b`, 10 commits).
5. Terminal backends (R71): the backend layer is a Rust trait in cmux-tui.
   The surface talks one viewer protocol to a session host, whatever the
   backend. Two interfaces: `cmux.terminal.backend/1` (a process byte pipe;
   the local host parses) and `cmux.terminal.connector/1` (the far end runs
   its own session host, for example a Cloud VM; the local host relays it).
   Both declare `options.kinds`, default deny. Proven by the Cloud app and a
   sample SSH app.

## 1. Patch inventory

### 1.1 manaflow-ai/ghostty (desktop fork) versus upstream

Fork `origin/main` `9e0f0bb674` (2026-10-03): 539 non-merge commits ahead of
upstream, 1,398 behind, merge base `ab0b9da9e8` (2026-07-22). The cmux-next
pin `b1a49b6015` is 510 ahead. Group counts are from the 2026-10-02
inventory (530 commits) plus a re-check of the 29 commits since then.
Verdicts are for cmux-next (Mac and iOS mirror surfaces, cmux-tui host).

| Group (count) | What it is | Example SHAs | cmux-next verdict | Why |
| --- | --- | --- | --- | --- |
| A1 manual IO (7) | `Manual.zig` backend, `process_output`, `io_write_cb`, MANUAL_MIRROR reply suppression, `text_input` | `d631f36cea`, `22fa801f88`, `581dbf264f` | already redone in ghostty-next | ghostty-next re-ported them on upstream with tests and a stricter reply list (5522, clipboard_read). |
| PTY tee (4) | Mac producer tees PTY bytes to the phone | `8bfc3b0263`, `365fe1d2cc`, `14ce6dbd30` | drop | The app has no PTY. cmux-tui is the only producer. |
| A2 render-now, render queue bounds, redraw tickets, tokened presentation (~74) | iOS render workarounds and frame-exact presentation | `66c3bc6f14`, `2b74a38fe8`, `d303f9c89e` | drop; presentation callback deferred | Root cause was the libxev iOS machport bug; upstream's libxev pin fixes it. ghostty-next has the non-blocking mailbox (D4). Presentation callbacks return only if verified replay needs frame-exact acks. |
| A4 config/theme (12) | `config_load_string`, padding `c_get`, `update_theme_config` | `f7880c4731`, PR 251, `c052c1450d` | port `config_load_string` and padding `c_get`; drop `update_theme_config` | The Mac app uses both (section 1.3). The Mac uses `update_config`. |
| A5 render-grid JSON (13) | test-only grid export | `4cc0933cfa` | drop | Verification only. GHOSTSNP READY digests replace it. |
| A6 Kitty replay restore (17) | `ghostty_surface_restore_kitty_replay` | `543a284553` | redo as GHOSTSNP restore + on-screen Kitty image replay (D3) | ghostty-next has `restore_snapshot`; cmux-tui has `terminal-snapshot-v1`. |
| B1 terminal semantics (9 + 4 since) | OSC 133 prompt on its own line, padding before a prompt, clear_screen order, stale prompt marks | `e1b8bf5f47`, `1975783f42`, `33620abfb1`, `431f5fea06` | port to ghostty-next (both lib-vt and app) with the fork tests red first | Parser behavior. cmux-tui moved to ghostty-next without it, so the host already lost these fixes. One port fixes host and viewers at once and keeps snapshots byte-equal. |
| B2 fonts (20) | NFD Hangul, CJK fallback width (PR 233), null CoreText names, RTL (itijah) | `3fbdd078df`, `3a7fc92309`, `0068ece733`, `ff362c99c0`, `e099e32efe` | port Hangul, CJK width, CoreText names; defer RTL | Viewer-only drawing, visible to Japanese and Korean users. RTL adds a dependency (`manaflow-ai/itijah`). |
| C VT replay formatter, lib-vt producer API (28) | formatter fixes, Kitty limits and cursors, cursor activity | `533c27ae1c`, `b7feeea5c0`, `71ed4f8f6f` | already redone in ghostty-next (round 1 and 2) | cmux-tui uses them through ghostty-next today. |
| D1 Electron, Windows, offscreen, EGL (21 + 13 since) | other embedders | `2b42e89227`, `f6b196135a`, `b1c147b47d` | drop | Not cmux-next. |
| D2 theme picker CLI (30) | `src/cli/list_themes.zig` | `66ff6ec4d0` | drop | cmux-next Settings owns themes. |
| D3 tmux control mode, write_active_file (14) | | `ed123a8c09` | drop; remove the app's tmux callback | cmux-tui owns multiplexing. |
| D4 link detection (39) | wrapped links, file paths, cmd-click | `eb9004aa8e`, `46428d790c` | drop; port single fixes only on a dogfood repro | Upstream has link detection and OSC 8. |
| D5 desktop renderer lifecycle (83) + D7 display link and resize (6) | hidden-tab GPU release, Metal sharing, frame lease, live resize | `517a4c75ad`, `a3588ac53d` | drop; dogfood gate (section 5, S2) | Upstream `c4e16970a8` releases GPU for hidden surfaces. A mirror's grid comes from the host, so view resize no longer reflows locally. Risk: live-resize and many-tab regressions show only in dogfood. |
| Unfocused 30 FPS pacing (PR 234) | `edefce7785` | | port if S2 profiling shows idle GPU cost with many tabs | Measured need, not default. |
| D6 PTY teardown, shell integration env, crash subdir, argv surfaces (46 + 2) | | `5b20c62297`, `aef980e27b`, `1f68f61057` | drop | No process in the app. `-Dcrash-report-subdir` is fork-only. |
| D8 input, selection, clipboard (63) | keyboard copy API, bounded copy, clear selection, grid metrics, font size callback, font query, OSC 99, prompt input (PRs 235/237/238) | | port the 5 APIs the Mac uses (section 1.3); drop the rest | Copy mode, find and font zoom are cmux-next features. OSC 99 belongs to the host (it parses notifications). Prompt input is not used by cmux-next. |
| E1 already upstream (19), E2 superseded (9), F reverts and syncs (20) | | | drop | |

### 1.2 ghostty-next versus upstream

`main` `31627e4b9` = upstream `83edd491e3` + 53 commits, all listed with
reasons in ghostty-next `NEXT.md`. All keep:

- Build: iOS slices revert (`7a171895dd`), `ios` xcframework target,
  `-fblocks`, GhosttyNextKit module name, CI pipeline, release plan.
- Remote IO: manual backend, mirror reply suppression, C API, text input,
  threading contract, Kitty in-band only, clear/reset left to the owner.
- Host-owned grid and snapshots: `set_grid`, `restore_snapshot`,
  `encode_snapshot`, hardened history, scrollback limits across restores.
- Renderer: non-blocking surface calls (D4), GPU completions never wait for
  the app mailbox, iOS 72 DPI, IOSurfaceLayer detach, bounded hide wait.
- lib-vt producer ports for cmux-tui (round 1 and 2).
- Behavior differences (OSC 7 raw URL, `shell_redraws_prompt = false`,
  live scrollback limits) apply to MANUAL modes only.

Only the build revert, 72 DPI and the IOSurfaceLayer sublayer fixes are
iOS-only; the rest applies to the Mac surface unchanged.

### 1.3 C API the Mac app uses that ghostty-next lacks

Token scan of `CmuxNextTerminal` (334 identifiers) against ghostty-next
`include/ghostty.h`:

| API | Mac use | Verdict |
| --- | --- | --- |
| `ghostty_config_load_string` | theme, keybind, padding config lines | port (26 lines, fork `f7880c4731`) |
| `ghostty_config_get` for `window-padding-x/-y` as `ghostty_config_window_padding_s` | `GhosttyRuntime+Padding.swift` | port (fork PR 251) |
| `ghostty_surface_grid_metrics` | copy-mode cursor box | port |
| `ghostty_surface_clear_selection` | copy mode, find | port |
| `ghostty_surface_copy_selection_to_clipboard_bounded` | copy mode | port |
| `ghostty_surface_set_font_size_action_callback` | per-tab font zoom record | port |
| `ghostty_surface_keyboard_copy_*`, `ghostty_surface_keyboard_selection_move` | copy mode (vim keys) | port (largest, about 400 lines with tests); upstream `adjust_selection` moves a selection only and has no copy cursor |
| `ghostty_surface_set_grid_size` | daemon grid | replace with `ghostty_surface_set_grid(cols, rows, generation)` |
| `ghostty_surface_restore_kitty_replay`, `kitty_graphics_limits`, `kitty_image_alias`, `kitty_image_id_cursor_state` | reattach and resize replay | replace with `restore_snapshot` over `terminal-snapshot-v1` |
| `ghostty_tmux_event_e` callback | ignored | delete the callback |
| clipboard callbacks (`read_clipboard_cb` result enum and MIME list, `confirm_read_clipboard_cb` struct, `complete_clipboard_request` struct) | `TerminalClipboardRequests.swift` | adapt Swift to upstream ABI |

## 2. Upstream sync

- Method: merge upstream `main` into `sync/upstream-<date>` in
  manaflow-ai/ghostty-next, update `next/UPSTREAM_BASE`, land by PR. Never
  rebase `main`. Reason: the cmux gitlink and every GhosttyNextKit release
  commit must stay ancestors of `main` (submodule pointer safety). A rebase
  would orphan `31627e4b9` (pinned by feat-cmux-next) and `74e97632d4`
  (iOS release commit). The old NEXT.md said "rebase"; PR 13 changes it.
  When the stack needs a clean replay, rebase on a side branch, then
  `git merge -s ours <old main>` so the old tip stays an ancestor.
- Done: PR 13 merges upstream `f96c9711b` (2026-10-04). Clean. The upstream
  delta touches only `src/cli/ssh*`, macOS `TerminalController.swift` and
  VOUCHED, so the ABI is unchanged. CI (`next-xcframework.yml`, Blacksmith
  macOS runner) builds it; the upstream remote push URL is disabled.
- Cadence: one sync PR per week, or when an upstream change touches
  `src/terminal`, `src/termio`, `src/renderer`, `src/apprt/embedded.zig` or
  `include/`. Each sync runs the patch tests and the iOS render smoke.
- A gitlink bump in feat-cmux-next lands only after the target commit is on
  ghostty-next `main` (`git merge-base --is-ancestor <sha> origin/main`).

## 3. Terminal backends (R71)

### 3.1 Layers

```
Ghostty surface (Mac, iOS)  MANUAL_MIRROR: render + encode input only
        |  viewer protocol: snapshot (GHOSTSNP) + bytes out; input, viewport, presence, focus in
cmux-tui session host       parser, grid, scrollback, snapshots, journal, hooks, attribution
        |  TerminalBackend / TerminalConnector traits (Rust)
backends (bytes): local-pty | app:<app>/<id>     connectors (host): cmux-tui link | app:<app>/<id>
```

Rules:

1. The surface has one production input: the viewer protocol of a session
   host. Today that is raw v12 `attach-surface` with
   `terminal-snapshot-v1` (local socket, or the link socket for a remote
   host). Lane 12's `terminal_bytes` channel carries the same frames. Swift
   `TerminalIO` stays as the in-process seam; its production
   implementation is the session-host viewer client. `LocalPTYTerminalIO`
   and `ScriptedTerminalIO` stay debug and test only.
2. No backend code runs in the app process or touches Ghostty. App code runs
   in the app host (its server), behind the session host.
3. A backend never sees other terminals and never decides the grid. The
   session host computes the grid (smallest policy) and tells the backend.

### 3.2 Two interfaces (decided 2026-10-04 with the Cloud app lead)

The two modes have different message sets and different trust, so they are
two interfaces, not one schema with a mode field:

| Interface | Mode | Far end | Local session host | Users |
| --- | --- | --- | --- | --- |
| `cmux.terminal.connector/1` | host | runs its own session host (parser, grid, snapshots) | relays the viewer protocol; does not parse | Cloud machines, cmux-tui over the link |
| `cmux.terminal.backend/1` | bytes | a process byte pipe | parses, owns snapshots, journal, grid | `local-pty`, sample SSH app, Cloud rescue shell |

Both declare `options.kinds`: an array of localId strings, 1 to 16, unique
(for example `cloud-vm`, `ssh`). The daemon refuses `connect` or `open` for
a kind that the manifest does not declare (default deny).

### 3.3 Rust traits (crate `cmux-terminal-iface`; daemon side in cmux-tui-core `terminal_backend`)

Decided 2026-10-04 (terminal interfaces daemon lead, coordinator approved).
The types and traits live in the small crate
`cmux-tui/crates/cmux-terminal-iface` (dependency: serde only), so app
servers outside the cmux-tui workspace (`first-party-apps/cloud/server`,
`samples/apps/ssh-terminal`) take it by path and delete their mirrors.
cmux-tui-core re-exports it as `terminal_backend` and adds the host-only
parts: the manifest declaration, the link registry, the open-token check
and the JSON-lines wire form.

Rules:

1. Synchronous and non-blocking. No method waits; outbound items are pulled
   with `take_frames()`. The daemon has no async runtime (std threads, JSON
   lines per app server). The caller drains when its transport has data, so
   nothing polls.
2. Bytes move only as frames: `data {channel, offset, bytes}`,
   `credit {channel, direction: in|out, bytes}`, one `end {channel, exit|lost}`.
   `SendWindow` and `ReceiveWindow` are the one credit and continuity rule
   (gap, overlap or data past the credit ends the channel with `lost`).
   There is no `write` method and no output event, and no filesystem socket
   path crosses an app boundary.
3. The session host assigns every channel id: terminal ids (`open
   {terminal, ...}`, `resume {terminal, ...}`), host channel ids
   (`connection.channel.open`) and connector link ids
   (`cmux.terminal.connector.open`).
4. Default deny: a kind outside `options.kinds` is `denied`; an open token
   minted for an op outside `options.openOps` is `denied`.

```rust
pub enum FrameBody { Data { offset: u64, bytes: Vec<u8> }, Credit { direction: Direction, bytes: u32 }, End(End) }
pub struct Frame { pub channel: String, pub body: FrameBody }  // the stream bridge adds the host id
pub enum End { Exit(ExitStatus), Lost(Lost) }

pub trait TerminalBackend: Send {                 // cmux.terminal.backend/1
    fn id(&self) -> &BackendId;                   // local-pty | app:<app>/<kind>
    fn kinds(&self) -> &[LocalId];
    fn capabilities(&self) -> BackendCapabilities;
    fn open(&mut self, req: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError>;
    fn resume(&mut self, req: ResumeRequest) -> Result<Resumed, BackendError>;
}
pub trait ByteTerminal: Send {                    // one terminal = one channel
    fn window_bytes(&self) -> u32;
    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError>; // input data, out credit
    fn take_frames(&mut self) -> Vec<FrameBody>;                      // output data, in credit, end
    fn resize(&mut self, grid: Grid) -> Result<(), BackendError>;
    fn signal(&mut self, signal: Signal) -> Result<(), BackendError>;
    fn close(&mut self, how: Close) -> Result<(), BackendError>;
    fn resume_token(&self) -> Option<ResumeToken>;
}
pub trait TerminalConnector: Send {               // cmux.terminal.connector/1
    fn id(&self) -> &BackendId;
    fn kinds(&self) -> &[LocalId];
    fn connect(&mut self, req: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError>;
}
pub trait HostLink: Send {                        // viewer protocol, relayed, not parsed
    fn window_bytes(&self) -> u32;
    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError>;
    fn take_frames(&mut self) -> Vec<FrameBody>;
    fn close(&mut self) -> Result<(), BackendError>;
}
pub trait HostChannels: Send {                    // host side of connection.channel.* (ssh)
    fn open(&mut self, req: ChannelOpenRequest) -> Result<ChannelOpen, BackendError>;
    fn resize(&mut self, channel: &str, cols: u16, rows: u16) -> Result<(), BackendError>;
    fn signal(&mut self, channel: &str, signal: Signal) -> Result<(), BackendError>;
    fn close(&mut self, channel: &str) -> Result<(), BackendError>;
    fn push(&mut self, channel: &str, frame: FrameBody) -> Result<(), BackendError>;
    fn take_frames(&mut self) -> Vec<Frame>;
}
```

`OpenRequest`: terminal (host id), kind, target, open_token, command, cwd,
env (allowlist), grid, actor. `ResumeRequest`: terminal, resume_token,
open_token. `ConnectRequest`: kind, target, open_token. `BackendError`:
`Unsupported`, `Unavailable {reason, retryable}`, `HostKey {decision,
fingerprint}`, `Denied {reason}`, `Invalid {reason}`. `BackendCapabilities`:
`resize`, `signals`, `exit_status`, `resume`, `cwd_reports`,
`max_write_bytes`, `answers_queries` (true only when the far end answers DA,
DSR and OSC color queries itself; then the session host parses but does not
reply).

Open token flow (one check path; the app passes the token on, the host
consumes it):

1. A user gesture in a client sends `apps-run` of one of the app's catalog
   ops with origin `user`. The supervisor stamps a fresh `open_token`
   (bound to the app, single use, 60 s) into the op line to the server. The
   client never holds it; runs from cli, mcp, script or remote get none.
2. The server opens its carrier, then sends host op
   `cmux.terminal.connector.open {kind, target, open_token}`.
3. The host consumes the token (`Supervisor::consume_open_token`; any
   attempt burns it), checks that the minted op is in `options.openOps`,
   that the app implements the interface with its server and holds the
   `terminal:backend` grant, and that the kind is declared. It assigns the
   channel id, records `app:<app>/<kind>` plus target (one link per kind and
   target), and answers `{channel, window_bytes}`.
4. Frames flow on the server's stream. The host ends a link with
   `host.event cmux.terminal.connector.close {channel}`; the app ends it
   with its `end` frame; a server stop or exit ends every link of the app
   with `lost`. A reconnect needs a new user run (v1: "disconnected, click
   to connect" after a daemon restart; no link grant).

Link relay (decided 2026-10-04): link bytes are the far session host's
v12 protocol, and the local daemon does not parse them. Each open link gets
one owner-only socket `<daemon state dir>/tl/<n>.sock` (directory 0700,
socket 0600; a per-user temporary directory when the path is too long). The
daemon checks the peer uid on accept. Its clients find it with
`apps-terminal-links` and the `apps-terminal-link {channel, id, target,
state, socket?, end?}` event, and open their normal daemon connection on it.
The path never goes to an app. Limit for v1: one client per link (a v12
stream has per-connection state). A second client is refused, and the link
closes when its client leaves; each client (Mac, iOS) needs its own link,
so its own user run. Two relay threads wait on the registry's condition
variable: bytes become credit for the app only after the client has them,
and client bytes go to the app only within its credit.

Backend terminals (decided 2026-10-04, P1 to P3 and placement): the app
calls `cmux.terminal.backend.open {kind, target, open_token}` -> `{terminal,
window_bytes}` after a user run (same checks as the connector). The session
host creates the terminal with no tab: its local runtime is a portable_pty
`MasterPty`/`ChildKiller` over the terminal's channel
(`terminal_backend/pty.rs`, spawned through `surface/spawn.rs`, the spawn
path shared with PTY children), so parsing, journal, snapshots and attach
are unchanged. An exit status ends the process (`TerminalEnd::ProcessEnded`);
a lost channel is a host loss. Resize and close go to the app as host events.
The terminal is a catalog-owned terminal with a public `term_…` id and
zero views (spec/resource-api-v2.md: terminals work with zero views). The
host broadcasts `apps-terminal {terminal, terminal_id, id, app, target,
run_key}`; the client whose user run has that idempotency key gives it its
first view with the existing public op `terminal.project` in its own
focused workspace. That first projection also writes the terminal's durable
record (destination workspace key, in-process identity) in the same commit
(`mux/resource_content.rs`); later projections reuse it. A terminal that
never had a view 60 s after its open is closed; one that had a view stays.
`connection.channel.open` takes the terminal instead of a second token
(P2). `resume` is a host op after a user run (P3); v1 answers unsupported.

Lane note, v1 limits (accepted by the coordinator, 2026-10-04):
1. A first view writes the record as launching in the topology commit and
   as running in a second commit right after; a crash between them restores
   as a failed launch (correct: a backend terminal does not survive a daemon
   restart).
2. "Had a view" means the terminal has a durable identity. The 60 s close is
   tested for a terminal that still has its view; the case where its last
   tab closed first is not tested, because a tab close may retire the
   terminal (`close_content`).
3. Until its first view, a backend terminal is not in `terminal.list` or
   `terminal.get` (it has no durable record).
4. `cmux.terminal.backend.resume` answers unsupported after its token check;
   `cmux.terminal.channel.open` answers unavailable (no SSH transport); the
   host sends no signal events; one client per link.
5. No live end-to-end run yet with the real Cloud server or the Mac and iOS
   clients for the relay, the backend runtime or `terminal.project`.

Host-owned SSH transport (open decision, its own owner): `connection.channel.open`
runs its checks in the daemon behind an `SshTransport` trait; production
answers `unavailable {retryable: false}` until this is decided. Options:
(a) `russh` in the daemon (pure Rust, async on tokio; the daemon core has no
runtime, so it needs a small runtime thread), with host key pins in the
daemon state dir and the user key reached through the credential relay
(the Mac app signs with the Keychain key, so the key never leaves the
Keychain; the signature request is bound to the session id the daemon's
transport computed, so it is not a signing oracle for the app);
(b) the system `ssh` binary as a child with `-o StrictHostKeyChecking=yes`
and a per-handle known_hosts file, the daemon owning the PTY (no new crate;
an agent socket from the Mac app for the key); (c) `libssh2` bindings (C
dependency, sync API). Recommendation to check: (b) first for speed, (a)
when headless servers need it without a Mac.

Snapshots: a backend never needs a VT parser; the local session host owns
snapshots and journal. A connector serves GHOSTSNP from the far host; a
version mismatch falls back to byte replay as `terminal-snapshot-v1` does
today. After a session host restart the journal holds `{id, resume token}`;
`resume` reattaches, or the terminal shows exited with the reason.

Backpressure: the session host grants a backend output credit only while
viewers and the journal keep up, and a backend grants host-channel credit
only from that, so a slow viewer stops the far end instead of growing a
buffer. Relayed link bytes wait in the link registry, at most one window,
because credit is granted only as the consumer takes them.

`local-pty` (today's `cmux-pty` spawn path) becomes the first backend, and
the link to a remote cmux-tui the first in-process connector.

### 3.4 App-provided backends and connectors (manifest v2)

- Ownership: the ghostty-next lead owns both interface schemas
  (`cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.backend/1.json`,
  `.../cmux.terminal.connector/1.json`) and the Rust traits. The app
  platform lead owns the manifest schema and the `terminal:backend` scope.
- Manifest: `implements: [{"interface": "cmux.terminal.backend/1", "id":
  "ssh", "title": <localized>, "options": {"kinds": ["ssh"]}}]`. Ids are
  namespaced `app:<app id>/<id>`.
- Implementation: the app's server (native or JS). The app host bridges
  JSON control messages and binary frames to the traits.
- Scope: restricted scope `terminal:backend` for both interfaces, plus a
  `connection` handle per terminal or link (V6). Secrets stay in a
  `credential` handle.
- Consent: the user creates the terminal or link with a gesture (connect
  sheet or command); the backend gets only that terminal. Revoke closes
  every terminal and link of the app and drops its resume tokens
  (terminals show "disconnected: backend revoked").
- The terminal record carries the backend or connector id and display name
  (tab and Info pane). Hooks, agents and notifications work unchanged.
- Proof, in parallel (R71): the Cloud app (Cloud app lead) implements
  `cmux.terminal.connector/1` with kind `cloud-vm` (Cloud machines keep their
  own session host) and `cmux.terminal.backend/1` for its rescue shell; the
  sample `samples/apps/ssh-terminal` implements `cmux.terminal.backend/1`
  with kind `ssh`.

### 3.5 Handle operations that use secrets (security first)

A backend never receives a secret and no host op signs or decrypts bytes
that the app chose. A generic `sign(bytes)` on a credential handle would be
a signing oracle, and even a narrow SSH user-auth signature op leaves a
login-elsewhere risk (the host cannot prove that the session id belongs to
a key exchange with the handle's host while the app runs the transport).
Decision 8 (coordinator, 2026-10-04): the host owns the SSH transport.

For a `connection` handle of kind `ssh`, the backend calls the host op
`connection.channel.open {connection, open_token, pty: {term, cols, rows},
command?}`. The host resolves the handle, dials, checks the host key that
the user pinned for that handle (an unknown or changed key fails with the
typed `hostKey {decision, fingerprint}` error, before any byte reaches the
shell), authenticates with the user's credential, opens a session channel
with a PTY and returns a byte channel (data, window change, signal, exit
status; `connection.channel.resize|signal|close`). The backend maps its own
`open`, `write`, `resize`, `signal` and `close` onto that channel. The host
issues `open_token` per open or resume after the user's gesture; host ops
refuse a missing, expired or reused token. There is no signing op in the
interface.

What an SSH app still adds: picking and grouping hosts, jump-host and
provisioning flows, per-host defaults; never transport or keys. The cmux
Cloud SSH sample moves to this channel model.

## 4. Mac switch plan

1. Package: `Packages/Shared/CmuxGhosttyKit` declares the single
   `binaryTarget(name: "GhosttyNextKit", url: <ghostty-next release>,
   checksum:)`. iOS (`ios/CmuxiOS/Package.swift`) and the Mac
   (`CmuxNext/Package.swift`) both depend on it, so one pin serves both and
   the workspace has one target of that name. `import GhosttyKit` becomes
   `import GhosttyNextKit` (29 files) and the bridge header `ghostty.h`
   follows.
2. Release flavor: ghostty-next adds flavor `apple-v6`
   (`-Dxcframework-target=universal`: macOS arm64 + x86_64, iOS, iOS
   simulator). Today's `ios` flavor has a host-native macOS arm64 slice
   only. Archives are already `lib`-prefixed, so
   `prefix-ghosttykit-archives.sh` is no longer needed and
   `CmuxNextTerminal` can get a SwiftPM test target that links.
3. Build: GhosttyNextKit is built by ghostty-next CI on a hosted Blacksmith
   macOS runner and downloaded by SwiftPM. The fleet (`cmux-ci build cmux`)
   resolves the package; it no longer runs `ensure-ghosttykit.sh` or Zig for
   cmux-next. `cmux-next.yml` drops the `ghostty` path filters and the
   prebuilt download steps. `cmux-tui` keeps building libghostty-vt from the
   `ghostty-next` gitlink; the gitlink and the release pin move together
   (same ghostty-next commit) so host and viewer parse alike.
4. Remove the `ghostty` gitlink from feat-cmux-next only after S2 dogfood
   passes (a separate commit). `main` is unaffected.
5. Rollback: revert the switch commit (one commit restores `GhosttyKit` and
   the old pin); the `ghostty` gitlink stays until step 4.

## 5. Slices

| Slice | Where | Red test first | Needs |
| --- | --- | --- | --- |
| S0 upstream sync | ghostty-next PR 13 | none (merge) | merged `f24cb8630` |
| S1a-1 small Mac APIs | ghostty-next | Zig tests per API: load_string, padding get, grid_metrics, clear_selection, bounded copy, font size callback | ghostty-next CI |
| S1a-2 keyboard copy API | ghostty-next | fork copy-mode tests (atomic navigation, bounded rich copy, cursor snapshot) in both `test` and `test-lib-vt` | ghostty-next CI |
| S1b B1 parser fixes | ghostty-next | fork tests "a prompt after a padded partial line must stay at column 0 across resize", "133;P primary prompt ... own line", in both `zig build test` and `test-lib-vt` | Testbox; then cmux-tui gitlink bump (cmux-tui window) |
| S1c fonts | ghostty-next | fork Hangul NFC/NFD and CJK fallback tests | Testbox |
| S1d flavor `apple-v6` | ghostty-next | release smoke links the macOS x86_64 slice | hosted CI |
| S2 Mac switch | feat-cmux-next | `CmuxNextTerminal` test target: snapshot attach restores the screen after a canonical resize on the same surface (today: a new surface) | fleet build `cmux-ci`, cmux-mini-6 tests, dogfood on cmux-lawrence-2 (never the laptop): live resize, 30 tabs idle GPU, Kitty image after reattach, copy mode, IME |
| S3k Kitty images after snapshot | cmux-tui | reattach and resize keep an on-screen Kitty image (READY restore, then image replay) | cmux-tui window |
| S3 traits + `local-pty` + link connector | cmux-tui | in-memory fake backend drives a terminal end to end through v12 attach | cmux-tui window |
| S4 app bridge + interface + sample SSH app | cmux-tui, samples | manifest fixture valid/invalid; SSH sample opens, writes, resizes, revoke closes | cmux-tui window, app platform lead |
| S5 Cloud backend | Cloud app lead | their tests on the shared interface | Cloud app lead |
| S6 iOS on the shared pin | ios | existing iOS smoke | iOS lead |

## 6. Decisions (coordinator, 2026-10-04)

1. Merge-based sync: approved. PR 13 merged (`f24cb8630`).
2. cmux-next ships for Intel Macs: `apple-v6` is macOS arm64 + x86_64
   (universal) plus iOS and iOS simulator.
3. Copy mode: port the fork keyboard copy API. Real size is about 2,800
   lines (fork PRs 154, 156, 157, 159 and the selection-tracking commits),
   and it changes `Screen` and `Selection`, which libghostty-vt also builds.
   It lands as its own ghostty-next PR (S1a-2) after the small APIs (S1a-1).
4. cmux-tui re-sends the on-screen Kitty images after a snapshot; no image
   loss on reattach or resize. New slice S3k (cmux-tui window).
5. Port the OSC 133 prompt fixes to ghostty-next (S1b).
6. Two interfaces, `cmux.terminal.backend/1` and
   `cmux.terminal.connector/1`, both with `options.kinds` and default deny.
7. No window-opening tests on the laptop. S2 Mac dogfood runs on
   cmux-lawrence-2.
8. The host owns the SSH transport for `ssh` connection handles; the
   backend gets a channel; the interface has no signing op (section 3.5).

Shortcuts taken in this proposal: no build ran; the Mac API gap is a token
scan, not a link; group counts reuse the 2026-10-02 inventory; D5/D7
desktop renderer fixes are dropped on the claim that upstream and the
mirror model cover them, which only S2 dogfood can prove.
