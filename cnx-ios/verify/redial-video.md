# Redial: the shown browser tab keeps its video; terminals follow a Mac restart

Branch `feat-cnx-ios-redial-video`, 2026-10-20 (base
`origin/feat-cnx-ios-hybrid-link` `bb0dd17a1de`). Fixes defects 7, 2 and 4 of
verify/transport-verify-20261019.md (on `origin/feat-cnx-ios-transportverify`).

## Defect 7 (high): the visible tab lost its video after a redial

### Cause

Three things together:

1. On every new link `StreamedBrowserDirectory.linkChanged()` reopened a
   `browser` channel for every model the phone held: every tab it had ever
   shown in this launch, including tabs of workspaces already closed on the
   Mac (nothing dropped a model unless the phone itself closed the tab).
2. Each open with `video: "track"` claims the link's one media lane, and the
   last claim wins (`VideoOut::claim`). The opens raced, so the lane ended on
   whichever channel opened last, often a hidden tab. Nothing ever gave the
   lane back to the tab on screen: its video stayed on the channel.
3. cnx-hostd's host limit (4) stopped the least recently used host with a
   viewer. With five reopened tabs that could be the shown tab's host; its
   channel closed `replaced` and the phone only reopened on the next link,
   so the page froze on its last frame.

### Fix

- Phone (`StreamedBrowserDirectory`, `StreamedBrowserModel`):
  - On a new link only a shown tab (on screen, app active, laid out) opens
    again. A hidden tab opens when it is shown, or when the app comes back.
  - When the Mac's workspace tree arrives, models of tabs it no longer lists
    are dropped (`retain(tabs:)`; this phone's pending workspaces keep
    theirs).
  - The model tells the Mac which tab is shown: `rb.visibility` on every
    change, and `visible: false` right after `rb.open` for a stream opened
    while hidden.
  - A page the Mac stopped (`evicted`) opens again at once while shown, at its
    current address, at most twice without a frame in between; then, and for
    a page another viewer took (`replaced`), it says so with a Reopen button.
    A hidden page that was stopped opens when it is shown.
- cnx-hostd (`browser.rs`):
  - `rb.visibility {visible: true}` on a channel that asked for the lane and
    lost it takes the lane back: a new claim, a fresh track bridge (so hostd
    is again the main stream's viewer) and a keyframe request to the host.
    The same path serves the WireGuard RTP route, the WebRTC media session's
    track (hybrid) and the WebRTC link's own track: they are routes of one
    `VideoOut`.
  - The host limit stops an idle host first, then a hidden tab's, then the
    least recently used shown one, and closes that viewer's channel
    `evicted` (it said `replaced`).
- cnx-ffi viewer: a frame of the page's stream on the channel clears the lane
  sync, so when the tab takes the lane back its lane frames start at a
  keyframe.

## Defect 2 (medium): a terminal stayed "Reattaching…" after the Mac app restarted

### Cause

The phone's terminal session attached by the daemon's numeric surface id.
Surface ids are runtime slots: they survive an app restart while the daemon
keeps running, but a daemon that starts again (a crash, or a version handoff)
restores every workspace with new numbers (`workspace_registry.rs`,
`restore.rs`). The session asked for surface 15, got `unknown surface 15` six
times over 16 s, printed it, and never tried again; keystrokes waited forever.
Worse, an old number can name another terminal after the renumbering.

### Fix

`DaemonTerminalSession` keeps the tab's durable `terminal_id` (from
`list-workspaces`). A reattach first asks `resolve-terminal {terminal_id}`
(allowed by cnx-hostd's policy) and attaches to the surface it names; a
terminal the Mac no longer has ends with "[This terminal is no longer open on
the Mac]"; a reattach that runs out of retries says so and the next keystroke
tries again. On a new link a session reattaches when its surface or its
terminal is listed. A daemon without `resolve-terminal` is attached by number,
as before.

## Defect 4 (low): "WebRTC, UDP blocked"

`TransportKind.settingsValue(blockUDP:relayOnly:)`: Block UDP shows only for
WireGuard ("WireGuard, UDP blocked"); WebRTC shows "WebRTC only" or "WebRTC
only, relay only". The Developer footer says WebRTC ignores Block UDP.

## Tests

Failing first (commit `5105b31031f`, `7c…` for the terminal), then green.

Swift (`verify/termqa/cnxkit-test.sh` on mini-cmux11s):

- `RedialTests`: only the shown tab opens on a new link, a hidden one when
  shown; tabs the Mac no longer lists are dropped and never reopen; the shown
  state reaches the Mac (`rb.visibility`), also for a stream opened hidden; a
  shown page the Mac stopped reopens at its current address; a hidden one when
  shown; two stops in a row, then Reopen; `replaced` offers Reopen and never
  fights back by itself; a shown tab opens when the app comes back.
- `TerminalRenumberTests`: a reattach follows the terminal to its new surface
  (attach and `send` use it, no `[unknown surface]` line); a terminal the Mac
  no longer has ends with a clear line and is never attached by its old
  number; a daemon without `resolve-terminal` reattaches by number.
- `TransportDefaultTests.theSettingsValueNamesOnlyTheDebugPoliciesThatApply`.
- Red: the new API did not exist (build errors in the new tests only).
- Green: `CnxLiveTests|CnxBrowserStreamTests|CnxModelTests|CnxTransportTests|CnxShellTests|CnxWorkspacesTests`,
  423 tests in 111 suites.

Rust (rbx, `cargo test --workspace`, `cargo clippy --workspace --all-targets -D warnings`):

- `cnx-ffi/tests/browser.rs` `the_shown_tab_takes_the_lane_back_over_{wireguard_rtp,the_media_session,webrtc}`:
  tab A on the lane, tab B opens after it and takes it (A on its channel),
  A says `rb.visibility` true and is back on the lane (WireGuard RTP,
  the hybrid media session's track, the WebRTC track), B on its channel.
  Red before the fix: all three timed out at "the shown tab back on the lane".
- `cnx-hostd` `browser::tests`: the host limit stops a hidden tab's host
  before the shown one's and says `evicted`; a second viewer of a tab
  `replaced`; `rb.visibility` parsing.
