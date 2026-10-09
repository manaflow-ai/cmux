# C1 `terminal-rpc`: the terminal experience over `cmux.mobile/1`

Status: landed on its branch (section 13). Lane C1 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c1-terminal-rpc` off
`feat-cmux-next-ios`, with `feat-cmux-next-ios-c5-workspaces` merged in (C1 implements C5's
`WorkspaceTerminalSourceFactory`; C5 was not on the base yet). Binding: OWNERSHIP-PRINCIPLES.md,
ghostty-next.md sections 2 and 6, zero-latency.md, [a0-rpc.md](a0-rpc.md) 3.4 and 5.3,
[a2-ghostty.md](a2-ghostty.md) 2.1, [a3-link.md](a3-link.md) 4 and 5, [b5-mac-host.md](b5-mac-host.md)
2, 4 and 6, `schemas/terminal-sizing/fixtures.json`.

## 1. Ownership

| Fact | Owner (single writer) | Phone |
| --- | --- | --- |
| PTY bytes, offsets, grid and generation, scrollback, title, exit | cmux-tui session host | mirror in a `.host` Ghostty surface, repaired by READY snapshots |
| Canonical grid (smallest counting viewer) | session host sizing reducer (`CmuxTerminalSizing`, `sizing_policy.rs`) | one vote: its viewport while visible |
| Input order | the phone's input queue until the link accepts it, then the session host | ordered queue, never queued offline |
| Predicted echo | this phone only (view state) | speculative bytes over the mirror, never sent |
| Link path, RTT, channels | `CmuxLink` (`LinkSession`) | badge, telemetry |

The phone never writes terminal state. A prediction is a local overlay that the next host byte range
confirms or a READY replaces (section 8).

## 2. Modules

| Module | What | Builds on |
| --- | --- | --- |
| `Packages/Shared/CmuxMobileLink` (new) | the A0-over-CmuxLink binding both ends share: `MobileChannel`, `MobileInbound`, `DeviceProof` (moved out of `CmuxMobileHost` unchanged except the gap rule in 9), plus the client half: `MobileLinkClient` (hello with device proof, odd channel ids, channel open, session resets) | CmuxLink, CmuxMobileWire |
| `Packages/Shared/CmuxTerminalLink` (new) | `LinkTerminalByteSource` (`TerminalByteSource`, `.host`), `TerminalEchoPredictor`, `TerminalLatencyMonitor`, the client delivery queue | CmuxMobileLink, CmuxTerminalRenderCore, CmuxTerminalStream |
| `ios/CmuxiOS` target `CmuxiOSTerminalLink` (new) | `LinkWorkspaceTerminalSourceFactory` (C5 seam), `MobileLinkDirectory` seam per host, localized failure text | CmuxTerminalLink, CmuxiOSWorkspacesCore |
| `Packages/macOS/CmuxNext` target `CmuxNextMobileLink` (new) | the app adapter B5 left: `DaemonMobileDaemon` (`MobileDaemon` over `DaemonConnection`), `DaemonMobileTerminalAttachment` (`MobileTerminalAttachment` over `TerminalAttachment`), `MobileTreeProjection` | CmuxMobileHost, CmuxNextDaemon |
| `CmuxLink` | `LinkChannel.setSendPriority(_:)`: priority is per sending direction (section 5) | |
| `CmuxMobileHost` | terminal bridge sends output at render priority; binding files moved to `CmuxMobileLink` | |

## 3. Attach: keyframe, then live bytes

1. `MobileLinkClient` holds one `LinkSession` per Mac. Its first link channel is
   `cmux.mobile/session` (A0 channel 0): `hello {caps: [device-proof, read, resume], auth}` with a P-256
   proof over the link session id (b5 section 3), answered `hello.ok`. Every terminal attach waits for
   that answer; a refused hello fails every open with the host's code.
2. `LinkTerminalByteSource.open(viewport)` opens link channel `terminal/<term_id>` (reliable, priority
   `input`, budget 64 KiB for input) and sends `channel.open {kind: terminal, class: interactive,
   window: 262144, params: {terminal, viewport {cols, rows}, visible, counts: visible, snapshot
   {format: ghostsnp, versions: [1]}}}`.
3. The host answers `channel.opened {generation, cols, rows, snapshot_version, title}`; the source emits
   `.grid(cols, rows, generation)` and `.title`. A host without snapshot support (`snapshot_version: null`,
   byte replay) is not served on the phone yet: `TerminalViewer` waits for a READY before applying
   bytes, and the bundled same-tree daemon always has `terminal-snapshot-history-v1`.
4. The first output record is a READY (`snapshot_ready`, record flag `keyframe`), then `bytes` frames in
   offset order, `snapshot_history` pages and `digest` frames. Every record becomes `.frame`; the
   renderer's `TerminalStreamPipeline` restores, feeds and resyncs (ghostty-next 2).
5. `channel.refused` or a failed hello ends the stream with `.closed(reason:)` in the user's language
   (`TerminalLinkFailure`, localized by the iOS target), never a silent blank screen.

## 4. Resize and smallest-viewer sizing

The renderer already computes the viewport from the view's full height (the keyboard never changes it)
and reports it once per rotation, split change or pinch end, plus `visible` at once on background, lock,
tab switch or leaving the screen (a2 2.2). The source maps `viewportChanged` to two messages, each sent
only when its value changed:

- `terminal.presence {visible, counts: visible}`: the phone counts only while foreground and on screen.
  A hidden phone is `clear_viewport` in the sizing corpus: it stops counting until its next report.
- `terminal.viewport {viewport: {cols, rows}}` when cols or rows changed. A keyboard show/hide reports
  the same grid, so nothing is sent.

The session host is the only reducer (`smallest` policy, component-wise over counting viewers, 250 ms
grow hysteresis). A grid change arrives as `terminal.size {generation, cols, rows}` (`.grid`) followed
by a READY of the new generation; bytes of an older generation are dropped by the viewer. The Mac adapter
maps presence to `releaseGeometry` (hidden) or a size report (visible), and viewport to
`resize-attached-view` with the attach lease.

## 5. Input path

Ghostty's encoder produces bytes (keys with HID usages, mouse, committed IME text, focus) and bracketed
pastes; `TerminalSession` forwards them through one ordered queue (A2 used one `Task` per write, which
does not preserve order; fixed here). The source sends each write as one `TerminalInput {kind: bytes}`
record; Ghostty already applies bracketed paste, so `kind: paste` is reserved for a future composer
path. `MobileChannel` sends in call order under a FIFO gate, so A0 seqs and input order match.

Priority: the phone opens the terminal channel at `input`, the highest link priority, so a keystroke
leaves before queued rpc, files or browser traffic. Link priority is a property of a sending direction:
`LinkChannel.setSendPriority(.render)` on the host keeps a flooding terminal's output below the rpc
channel's `control` frames on the Mac's pump, while the phone's keystrokes stay at `input`. Nothing
queues offline: while the link reconnects, reliable sends are retained up to the channel budget and
replayed in order on resume (A3); once closed, `send` throws.

## 6. Flood catch-up

Two drop queues, one rule: a backlog is replaced by one keyframe, never a disconnect.

- Host (B5, unchanged): frames queue against the viewer's window (256 KiB). An overflow drops every
  queued frame, asks the daemon for one snapshot (`reason: gap`) and skips bytes until its READY, which
  leaves with the keyframe flag.
- Phone (new): link messages are drained at once into the source's delivery queue so link acks keep
  flowing; the renderer pulls from that queue (`AsyncStream(unfolding:)`). A READY drops every older
  queued `bytes`/`history`/`digest` frame (grid, title and path events stay). Queued frame bytes above
  the window (256 KiB) mean the renderer is behind: the queue drops its frames, sends one
  `terminal.snapshot_request {reason: gap}` and skips bytes until the next READY, so the viewer never sees
  the hole.

## 7. History on demand

The READY carries the screen; scrollback follows as `snapshot_history` frames of the same cut, which the
pipeline prepends. Older pages are fetched with `terminal.history {before, max_bytes}` (answered with
`snapshot_history` frames, which the pipeline prepends like the first pages). The source exposes
`requestHistory(before:maxBytes:)`; `terminal.read_range` (search, copy of off-screen text) is D1's,
with the same host seam. The host serves
them through `MobileTerminalAttachment.handle(_:)`, which the app adapter answers `proto.unsupported`
until cmux-tui exposes paged history on an attach (D1 shows "older history unavailable" then). Local
scrollback within `scrollback-limit-bytes` needs no request.

## 8. Latency telemetry and local echo prediction

Telemetry (`LinkTerminalByteSource.telemetry()`, newest-only stream of `TerminalLatencyReport`):

- Input to echo RTT: each `bytes` input records `(sentAt, hostOffset)`; the first `bytes` frame whose
  offset passes that host offset closes the sample. p50, p95 and last over a 64-sample ring.
- Frame age: half the link's smoothed RTT plus the phone's delivery-queue wait, measured when the
  renderer pulls the frame. The host's own queue wait is visible as overflow keyframes; a host-stamped
  age needs a catalog message (`terminal.age`, A0 additive, later).
- Link RTT and path from `PathBadge`, also emitted as `.path(_, rttMilliseconds:)` for the badge.
- Counters: keyframes, phone overflows, gaps, reattaches, predictions shown, confirmed, rolled back.

Prediction (`TerminalLinkOptions.prediction`, default off; DEV switch in D1), after mosh:

- Speculation reuses the viewer's offset rule instead of an overlay: when the user types printable ASCII
  and the predictor is confident, the source emits a synthesized `bytes` frame at the viewer's current
  generation with offset `+n`. The mirror draws it like an echo. The host's real echo covers the same
  offset range and `TerminalViewer` drops it as already applied, so a correct prediction costs nothing.
- Every real `bytes` frame is checked against the outstanding predicted bytes over the overlapping
  offset range before it is forwarded. Match: those predictions are confirmed. Mismatch (the program
  did not echo, or echoed something else): rollback. The source drops bytes until a READY, sends
  `terminal.snapshot_request {reason: gap}`, and the READY restores the host's exact screen. No byte
  of a wrong prediction survives a READY.
- Confidence: predict only when the link RTT is at least `predictionMinRTT` (30 ms; below it the echo
  is already within two frames), in live mode, after `confirmationsToPredict` (2) echoes matched
  verbatim since the last rollback or non-printable input. Enter, control keys, escape sequences,
  pastes and a grid change end the epoch: nothing more is predicted until every outstanding prediction
  is confirmed. A password prompt that echoes nothing: the first expiry rolls back.
- Expiry: an unconfirmed prediction older than `max(250 ms, 3 x RTT)` rolls back (one-shot sleep on the
  injected clock, cancelled on confirmation or close).
- Zero-latency mapping: the keystroke paints in its own frame (a), input order is preserved (c), the
  base is the host's bytes and the intents are the predictions (d), and a refusal reverts exactly (e).

## 9. Reconnect and resume

- Same link epoch (transport dropped, CmuxLink resumed within its window): channels resume, retained
  input replays in order, output continues. If the host overflowed meanwhile, its READY arrives as
  usual.
- Gap or new epoch (the Mac's link host restarted, or retention was exceeded): the link reports
  `ChannelEvent.gap`, or `MobileLinkClient` sees a new epoch on `connected`. The client starts a new A0
  session (new hello) and every terminal source reattaches on a fresh channel; the first frame is a
  READY, so the screen is exact again. `MobileChannel` now accepts the next seq after a link gap
  instead of closing (`proto.bad_record` was wrong there: the gap is the link's loss report).
- Kick (`terminal.kicked`), exit (`terminal.exited`), revoke (`auth.revoked`) end the stream with
  `.kicked` or `.closed(reason:)`; no reattach.

## 10. Multi-viewer

Each viewer is its own attach with its own window, presence and vote. The Mac's own views and every
phone see the same bytes and the same READY at a grid change. A slow phone costs itself one snapshot
and never slows the Mac or another phone (per-viewer windows). Previews attach `counts: false`.
`terminal.kick` from another viewer closes this one with `terminal.kicked {by, by_name}`.

## 11. Tests

Swift Testing in `CmuxTerminalLinkTests` over `CmuxLinkTesting` loopback and the lossy simulator: a real
`MobileHost` with a scripted daemon against `LinkTerminalByteSource`: attach (READY first, grid, title),
flood (host overflow costs one keyframe; phone queue drops on READY), resize and presence (sizing
reducer from `CmuxTerminalSizing`: hidden phone stops counting, unchanged viewport sends nothing),
input ordering under concurrency, reconnect within the epoch and gap -> reattach -> keyframe, prediction
confirm and rollback (mismatch and expiry), telemetry samples. Pure tests for the predictor, the
monitor and the tree projection.

## 12. Not here

Key bar, gestures, selection UI and the prediction DEV switch (D1); a carrier per Mac on the phone
(B2/B4 fill `MobileLinkDirectory`; until then the real path says "No connection to this Mac");
paged history in cmux-tui (`terminal.history` answered `proto.unsupported`); the Rust side.

## 13. Status (2026-10-06)

Compiled and tested on this Mac:

- `CmuxTerminalLink`: 29 Swift Testing tests green (`swift test`, run 3 times): attach, unknown terminal,
  input order on loopback and on a lossy jittery link, no offline queueing, phone flood -> one snapshot,
  hidden phone and keyboard sizing through `CmuxTerminalSizing`, same-epoch resume, new epoch -> reattach
  -> READY, kick, exit, prediction confirm / mismatch rollback / expiry rollback / off by default, predictor
  and monitor units, unpaired hello refused, shared hello with odd ids.
- `CmuxMobileLink`: builds, 1 test; `CmuxMobileHost`: 45 tests still green after the move; `CmuxLink`: 35.
- `CmuxiOSApp` (with `CmuxiOSTerminalLink`) compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.
- `CmuxNextMobileLink`: typechecked and 5 tests green through a scratch package that links the real
  `CmuxNextDaemon` and `CmuxNextWakeups` sources (the local 6.2.4 toolchain needed Swift 5 mode for those
  two modules only, for one region-isolation diagnostic in `DaemonStore+Driver.swift`). The full CmuxNext
  package and the Mac app were not built (disk); `check-concurrency`, `check-l10n`, `check-crash-safety`
  pass.

Not done: no carrier fills `MobileLinkDirectory` yet (B2/B4), so real-Mac terminals show "No connection to
this Mac"; `MobileHost` is not started by the app (`MobileHostService` still runs the irx host);
host-stamped frame age (`terminal.age`); `terminal.read_range` in the source; prediction DEV switch (D1).
No tagged build (blocked: no fleet manifest here, GitHub push auth broken).
