# cmux next: ghostty-next, remote terminals on iOS

Status: proposal (lane 13, 2026-10-02). Spec inputs: decisions IOS1, T1, T2
(spec `decisions.md`), spec `spec/sync-and-transport.md` sections 3.4 and 4,
OWNERSHIP-PRINCIPLES.md, ownership.md, cmux-tui-contract.md sections 2.5 and
3, docs/shared-terminal-sizing.md. Consumer: the iOS rewrite (lane 14).
Transport: lane 12. Repository: https://github.com/manaflow-ai/ghostty-next.

## 0. Summary

1. The session host (cmux-tui on a Mac, Mac mini or Cloud VM) is the only
   terminal authority. It owns the PTY, the parser state that answers
   queries, scrollback, and the canonical grid. The iPhone owns only view
   state: what is on screen, scroll position in its local window of
   history, selection, font size.
2. VT is parsed in both places. The host parses to own the state; the phone
   parses the same bytes with libghostty only to draw them. Live output
   travels as bytes. Attach, resize, catch-up after a flood, and drift repair
   travel as a host snapshot (upstream libghostty-vt's versioned binary
   snapshot format). Section 2 explains why this hybrid beats both pure
   options.
3. The phone runs Ghostty in manual-mirror IO mode: no PTY, no subprocess,
   no parser replies, input encoded and handed to the embedder. The grid size
   comes from the host, never from the view's pixel size.
4. Grid rule: one canonical grid per terminal; its columns are the minimum
   columns and its rows the minimum rows over counting viewers. A phone
   counts only while the terminal is on screen in a foreground app. The
   software keyboard never changes the phone's reported rows. Section 6 is
   the exact rule.
5. Rendering: Ghostty's Metal renderer in a UIKit view, drawn on demand (no
   continuous display link), GPU resources released when hidden, nothing
   rendered in the background.
6. ghostty-next = upstream ghostty-org/ghostty main plus a short documented
   patch stack, not a copy of the desktop fork. Release assets are
   deterministic zips with SHA-256, a manifest and a provenance attestation;
   the app pins one release with SwiftPM `binaryTarget(url:checksum:)`.

## 1. Fork base

Created 2026-10-02: `manaflow-ai/ghostty-next`, public (same as
`manaflow-ai/ghostty`), a plain repository rather than a GitHub fork, so
`gh pr create` can never default to the upstream repository and the
organization does not need a second fork in one network. `main` =
`ghostty-org/ghostty` main at `83edd491e3` (2026-10-01) plus:

| Patch | Why |
| --- | --- |
| build: restore iOS slices in the xcframework | Upstream stopped building the full library for iOS on 2026-08-12 (`7a171895dd`); only libghostty-vt still targets iOS. The iOS code paths in `src/apprt/embedded.zig` and `src/renderer/Metal.zig` are still upstream, so the revert is small. |
| build: add the ios xcframework target | `-Dxcframework-target=ios` builds iOS device, iOS simulator and native macOS (for host-side Swift package tests). |
| ci: ghostty-next GhosttyKit pipeline | Section 10. |
| build: name the ios xcframework and module GhosttyNextKit | The iOS app and the desktop app can share one Xcode workspace without a module collision (D9). |
| build: enable blocks when translating Apple SDK headers | The iOS 26.5 SDK CoreGraphics headers use blocks; translate-c needs `-fblocks` (found by the first iOS build). |
| ci: zero archive dates and add a link smoke | Reproducible archives; link-and-run smoke for every slice. |
| (in review, PR 2) remote IO mode | Manual and manual-mirror IO with the desktop fork's C names and values (struct offsets differ: different base), plus `ghostty_surface_text_input`. CI: 88 unit tests green; review asked for fixes (Kitty temp-file media, local clear and reset in mirror mode, exhaustive reply classification, sliced `process_output`, threading contract, byte-level reply corpus test). |

Why upstream main and not `manaflow-ai/ghostty` main:

- The desktop fork is 530 non-merge commits ahead of upstream and 1,388
  behind (merge base 2026-07-22). Most of its delta serves the desktop app
  (renderer link and frame leases, Windows and Electron embedding, theme
  picker, PTY tee, desktop replay paths). Carrying it into the iOS fork
  makes every upstream sync pay for features the phone never runs.
- Upstream added what a remote client needs since the merge base:
  `include/ghostty/vt/snapshot.h` (a versioned, CRC-checked binary snapshot
  whose READY marker makes a terminal renderable before older history
  arrives), `render.h`, `search.h`, `selection.h`, `io.h`.
- A short stack rebases cheaply. Each patch is one commit with a reason in
  NEXT.md; a port from the desktop fork names its source commit.
- Licensing is equal: both are MIT. ghostty-next keeps upstream's LICENSE
  and adds no code under another license.

Cost of this choice: iOS is unsupported upstream, so ghostty-next owns iOS
build breakage after each upstream sync, and the iOS fixes in the desktop
fork (render serial queue bounds, glyph DPI and pinch zoom, IOSurfaceLayer
teardown, libxev machport kevent) must be ported or re-solved. The lane's
inventory (private notes) classifies the desktop fork's 530 commits: about
300 are desktop-only, 28 are already upstream, and the iOS stack needs 6 to
8 patches (about 1.0k to 1.3k lines): the build revert, manual IO,
manual-mirror reply suppression, committed text input, 72 DPI font sizing on
iOS (upstream `src/font/face.zig` still assumes 96), the IOSurfaceLayer
teardown fix (`adee7043fc`, `dd726a9a60`), and snapshot restore. The
desktop fork's iOS render-queue workarounds (about 60 commits) are not
needed: they worked around a libxev iOS bug that upstream's libxev pin
already fixes. Known renderer risk: upstream releases the swap chain on
occlusion and waits for frame completions without a timeout, which can
block the renderer thread when the app goes to the background; ghostty-next
needs a bounded wait there. Upstream also changed the clipboard callback
interface, so no Swift code from today's app links unchanged.

**Decided (D1, 2026-10-02): the next upstream sync of `manaflow-ai/ghostty`
must revert upstream `7a171895dd`.** The shipping iOS app links GhosttyKit
from `manaflow-ai/ghostty`. That sync inherits `7a171895dd` ("build: stop
building Ghostty.xcframework for iOS") and drops the iOS slices unless it
reverts that commit, exactly as ghostty-next's first patch does. Keep the
revert in every sync until the shipping iOS app links GhosttyNextKit from
ghostty-next. The sync owner checks that the published GhosttyKit still has
`ios-arm64` and `ios-arm64-simulator` slices before the cmux pointer bump.

## 2. Who parses VT

Three designs:

| | A. Bytes only (phone parses) | B. Grid only (host renders cells) | C. Hybrid (chosen) |
| --- | --- | --- | --- |
| Live output | raw PTY bytes | cell diffs per frame | raw PTY bytes |
| Attach, resize | replay bytes (today: RIS + up to ~10 MiB VT re-encoding) | full grid | host snapshot (READY first, history on demand) |
| Flood (`cat` of 100 MB) | all 100 MB cross the link and are parsed on the phone | bounded by screen size times frame rate | bytes until the viewer's credit runs out, then the host drops that viewer's backlog and sends one snapshot |
| Keystroke echo latency | one RTT plus one parse | one RTT plus host frame pacing | one RTT plus one parse |
| Fidelity | full Ghostty: shaping, ligatures, Kitty graphics, hyperlinks, selection, search | only what the cell format carries; every new feature needs a wire change | full Ghostty |
| Parser drift between host and phone | divergence persists until the next replay | none | repaired at each snapshot and by digest checks |
| Phone CPU and battery | parse everything | parse nothing, draw cells | parse what the user can see arrive; snapshot when behind |
| Version coupling | same VT semantics on both sides | cell schema version | snapshot format version (u16), not commit equality |

Why C. Interactive use is short bursts of bytes; bytes are the smallest
encoding of them and need no host-side frame clock, so echo latency is the
network RTT plus a parse. Floods are where bytes lose, and they are exactly
where a phone user does not read every intermediate frame: the host replaces
an unbounded backlog with one bounded snapshot. Pure B throws away Ghostty's
renderer advantages (the reason we embed it) and re-implements terminal
semantics in a wire schema.

Mechanics:

- Channel `terminal_bytes` (sync-and-transport.md section 4) carries frames
  of kind `snapshot` (keyframe flag) or `bytes`, each tagged with the grid
  generation (section 6) and the host's byte offset.
- Credit flow control is per viewer. The host keeps at most
  `terminal.viewerBacklogBytes` (default 256 KiB) unacknowledged for a
  viewer. When a write would exceed it, the host discards that viewer's
  pending bytes, marks it `behind`, and at the next credit sends a snapshot
  READY section followed by live bytes from that offset. Other viewers are
  not affected. This replaces today's "terminal bytes disconnect and
  reattach" overflow policy with an in-band resync.
- Snapshot = upstream libghostty-vt snapshot (`GHOSTSNP`, version u16,
  CRC32C per record). Format version 1 has two gaps: it carries no Kitty
  graphics images, and upstream makes no binary-compatibility promise
  across versions. Until upstream closes them, a snapshot is followed by a
  Kitty image replay (the session host re-sends the images that are on
  screen), and host and phone must agree on the exact snapshot version
  (negotiated in `terminal-snapshot-v1`; a mismatch falls back to byte
  replay). The phone restores READY atomically into a fresh
  terminal state, then prepends history pages as they arrive. This replaces
  RIS-plus-replay, the `pending` escape tail and the separate Kitty replay
  restore of today's byte attach.
- Drift repair: after output goes idle for 2 s, the host sends a digest of
  its active screen (hash of its own READY encoding). When the phone's
  snapshot encoder has the same format version, the phone hashes its own
  READY encoding; on mismatch it asks for a snapshot. With different
  versions the check is skipped and only attach/resize snapshots repair.
- The host needs the snapshot encoder in its libghostty-vt. cmux-tui builds
  ghostty-vt from the cmux `ghostty` submodule (`manaflow-ai/ghostty`), which
  predates `snapshot.h`. Until that fork syncs upstream, the host cannot
  emit snapshots; the byte replay path stays as the fallback, negotiated by
  capability `terminal-snapshot-v1`.

Speculative local echo (drawing a typed character before the host echoes
it) is out of scope for v1. It helps only on high-RTT paths, it is wrong in
raw-mode apps, and it needs a reconciliation layer. Revisit with measured
RTT data from lane 12's path badges.

### 2.1 Frame fields (proposal for sync-and-transport.md sections 3 and 4)

Capability `terminal-snapshot-v1`. One `terminal_bytes` channel per attached
viewer. Every binary frame keeps the section 4 header (`u32 channel`,
`u64 seq`, `u8 flags`) and adds a terminal sub-header before the payload:

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | u8 | 0 `bytes` (raw PTY output), 1 `snapshot_ready` (GHOSTSNP up to READY; keyframe flag set), 2 `snapshot_history` (GHOSTSNP HISTORY pages, newest first), 3 `digest` |
| `generation` | u32 | grid generation (size-state `generation`); a viewer drops `bytes` older than its last restored snapshot |
| `offset` | u64 | host byte offset of the PTY output stream after this frame (for `snapshot_ready`: the offset the snapshot reflects) |
| `snapshot_version` | u16 | GHOSTSNP version, present for kinds 1 to 3 |

Rules: the first frame after attach is `snapshot_ready`. A grid change sends
`snapshot_ready` with the new generation to every viewer. Per-viewer credit:
when a viewer's unacknowledged backlog would exceed
`terminal.viewerBacklogBytes` (default 262144), the host drops that
viewer's pending bytes and sends `snapshot_ready` at the next credit. 2 s
after output goes idle the host sends `digest` (sha256 of its READY
encoding). A viewer with a different `snapshot_version` gets the byte
replay instead (capability fallback). `presence.set` carries `visible` and
`counts` (section 6).

The same fields map onto cmux-tui raw v12 events for local clients:
`attach-surface {mode:"bytes", snapshot:"ghostsnp", snapshot_version}`
answers with event `snapshot {phase:"ready"|"history", generation, offset,
version, data(b64)}`; `output` gains `generation` and `offset`; `digest
{generation, offset, version, sha256}`; command `snapshot-request
{surface}`. `terminal.history` and `terminal.read_range` are in the
request file `terminal-snapshot-history.md`.

### 2.2 Mac viewer (S2b, landed 2026-10-04)

- The Mac asks for snapshots only when the host advertises
  `terminal-snapshot-history-v1`: after every READY the host sends the rest
  of the same COMPLETE encode (HISTORY records through FINISH) as
  `snapshot {phase: "history"}` chunks at lower priority than live output,
  and a newer READY cancels the older history. A READY alone would drop the
  scrollback at every attach and grid change; `terminal-history` pages are
  bare PAGE records and cannot be fed to `ghostty_surface_restore_snapshot`.
- Generation order has one owner: `TerminalSnapshotSequencer` on the attach
  reader thread drops `output` older than the last READY and history of a
  replaced READY. The Mac channel event `output` therefore carries no
  generation or offset (deviation from the raw v12 fields above, accepted).
- `digest` is ignored in v1: comparing it needs the viewer to encode its own
  READY (drift repair above). Until then attach and grid snapshots repair
  drift.
- A READY restore keeps the owner's default palette, bg/fg and cursor
  defaults; the surface's own config must win (colors, and the cursor style
  unless the program chose one). ghostty-next applies them as local policy
  in the restore (PR 20, GhosttyNextKit 68ac618db); the Mac no longer
  re-applies its config after a READY.
- S2c (terminal-snapshot-local-history-v1): a viewer that opts in and is up
  to date gets, at each host resize, a READY cut exactly at the resize point,
  ordered after every earlier output frame, marked history: "local", with
  history_rows and history_digest (libghostty-vt digest v2 of the 64 history
  rows above the READY seam) and no history chunks. The Mac restores it with
  ghostty_surface_restore_snapshot_local_history: Ghostty reflows the old
  terminal with the owner's settings and keeps its history on a match (a
  smaller local scrollback limit still matches); a mismatch restores the READY
  without history, counts local_history_mismatch and sends snapshot-request
  (reason gap). A behind viewer, attach, overflow and request keep READY +
  history. 100k lines: 2.58 MB -> 60 KB base64 per settled resize.
- S3k (terminal-snapshot-images-v1): after the history of every plain READY
  the host sends the libghostty-vt Kitty replay of that cut as `snapshot
  {phase: "images"}` chunks; the viewer applies them with
  ghostty_surface_apply_kitty_replay, the only path where the private replay
  keys (E, J, B, L, R, M) work. No images follow a local READY: a match keeps
  the viewer's images, a mismatch asks for a plain READY. Cap 32 MiB of
  decoded pixels per READY (`skipped_images`).

## 3. Manual IO mode

ghostty-next keeps the desktop fork's C ABI so app code transfers:

- `ghostty_surface_config_s.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR`,
  `io_write_cb(userdata, bytes, len)`, `io_write_userdata`.
- `ghostty_surface_process_output(surface, bytes, len)` feeds host bytes.

Semantics (normative for the port):

1. No PTY, no subprocess, no termio read thread, no shell integration, no
   environment. The surface has a terminal state, a renderer and an input
   encoder.
2. Every byte from `process_output` is parsed into the local terminal.
   Parser-generated replies (DA1/2/3, DSR, CPR, XTVERSION, DECRQM mode
   reports, OSC 4/10/11/12 color queries, Kitty graphics and keyboard
   protocol replies) are dropped. The host answered them once already.
3. User input is encoded with the mirrored modes (cursor keys mode, Kitty
   keyboard flags, bracketed paste 2004, mouse tracking and format modes,
   focus reporting 1004) and delivered to `io_write_cb`. The embedder sends
   the bytes as `terminal.input` (attributed and ordered by the host) with
   `paste: false`, because Ghostty already applied bracketed paste.
4. The grid is set by the host (section 6), not computed from the view.
   New API: `ghostty_surface_set_grid(surface, cols, rows, generation)`
   locks the terminal grid; `ghostty_surface_set_size` still sets the pixel
   size and `ghostty_surface_size` still reports how many cells would fit
   (the phone's viewport proposal). With the grid locked, a larger view
   draws padding, a smaller one crops with a pan offset (section 4).
5. The phone never reflows on its own. Reflow belongs to the host; the host
   follows every grid change with a snapshot, which the phone restores.
6. New API: `ghostty_surface_restore_snapshot(surface, reader, phase)`,
   atomic, valid at any time, replacing the terminal state (phase READY) or
   prepending history (phase HISTORY). It replaces the desktop fork's
   `restore_kitty_replay` and the "create a fresh surface on resize"
   workaround.
7. Threading: `process_output`, `restore_snapshot` and `set_grid` are called
   from one serial embedder queue, never the main thread.
   `io_write_cb` runs on the thread that handled the input event; the
   embedder copies the bytes and returns at once.

8. No surface call blocks its caller on the renderer or a GPU completion.
   `process_output`, `set_grid`, `set_size`, font and theme updates,
   `set_focus` and `set_occlusion` enqueue work and return; a full renderer
   mailbox coalesces (latest size wins, output is appended) instead of
   waiting. Today's app blocks on these calls, which caused watchdog kills
   on the main thread and a "recreate the surface after a 2 s stall"
   recovery that leaks surfaces. The guarantee removes both at the cause.

The port of items 1 to 3 and 7 (same ABI as the desktop fork) is in review
on ghostty-next. Items 4 and 6 are new ghostty-next work after it.

### 3.1 Lessons from today's iOS app

An audit of today's app (lane private notes, file:line references) found:
it uses `GHOSTTY_SURFACE_IO_MANUAL` and filters replies in Swift; it
encodes keys with a fixed Swift table, so cursor-key mode, modifier
encoding, the Kitty keyboard protocol, function keys and Meta are wrong; on
the paired-Mac path it converts host render-grid JSON back into synthetic VT
bytes; it has no flow control (unbounded streams); it reaches a grid size by
adjusting the pixel size up to eight times; IME text is not drawn at the
cursor and the candidate window has no caret rect; it has no touch
selection and no bracketed paste. The rewrite keeps the per-surface serial
queue, tokened on-demand rendering and the cmux-tui byte attach. It drops
the render-grid path, the hybrid transport mode and the snapshot fallback.
Sections 3 to 7 fix the rest.

## 4. Rendering on iOS

- One `UIView` per visible terminal, backed by Ghostty's Metal renderer
  (`apprt/embedded.zig` iOS platform with `uiview`). No offscreen surfaces
  for terminals that are not visible; a tab switcher or Home preview uses
  the host's last snapshot drawn into a thumbnail, not a live surface.
- Draw on demand. A frame is requested when output, a snapshot, a cursor
  blink, selection or scroll changes the screen. The display link runs only
  while something animates (scroll deceleration, cursor blink if enabled)
  and stops otherwise. At 120 Hz (ProMotion) the link asks for the device
  maximum only during scroll and zoom gestures; output-driven frames are
  coalesced to one per vsync.
- Background: on `sceneDidEnterBackground` the view stops its display link,
  releases GPU resources (extend upstream `c4e16970a8`, which is macOS-only,
  to iOS), and never submits Metal work in the background (iOS terminates
  apps that use the GPU in the background).
- Grid versus view: when the canonical grid is narrower than the view, the
  extra area is padding in the terminal background color with a thin edge
  hint. When it is wider (a Mac set the grid and the phone does not count,
  or the user zoomed in), the phone keeps the font size and pans
  horizontally; a two-finger horizontal pan moves the window and the cursor
  column stays visible after output. A "fit width" toggle (setting
  `ios.terminal.fitWidth`, default off) scales the font down to the grid
  width instead.
- Theme: the host's theme colors (`colors` on attach) apply through
  `ghostty_surface_update_theme_config`, serialized with `process_output`.
- Fonts: bundled defaults plus system fonts; font size is client view state
  (pinch zoom), saved per device.

## 5. Input

Hardware keyboard:

- Ghostty's key encoder does all key encoding; the app has no key table.
- `pressesBegan/Ended` with `UIKey` (keyCode, modifierFlags, characters) map
  to `ghostty_surface_key` with the physical key code, so Kitty keyboard
  protocol and Ctrl, Alt (Option) and Shift combinations encode exactly as
  on the Mac.
- Command shortcuts go to the app first (UIKeyCommand: new tab, close,
  switch, palette, copy, paste, font size). Unclaimed Command combinations
  pass to the terminal. Option as Meta is a setting
  (`ios.terminal.optionAsMeta`, default true).
- Key repeat comes from the OS press stream; Ghostty does not synthesize
  repeats.

Software keyboard and IME:

- The terminal view adopts `UITextInput` with autocorrection, smart quotes,
  smart dashes, spell check and autocapitalization off and
  `keyboardType = .asciiCapable` by default (setting allows the default
  keyboard for non-Latin input).
- Marked text (IME composition: Japanese, Chinese, Korean, dictation in
  progress) is shown through Ghostty's preedit API at the cursor and never
  sent to the host. `caretRect(for:)` and `firstRect(for:)` return the
  cursor cell rect from `ghostty_surface_ime_point`, so the candidate
  window sits at the cursor. Only committed text (`insertText`) is encoded and sent.
  `unmarkText` commits; `setMarkedText(nil)` cancels.
- Backspace on an empty marked range sends DEL (0x7f) or the Kitty-encoded
  backspace per the mirrored mode.
- Dictation results arrive as committed text and go through bracketed paste
  when mode 2004 is on and the text has a newline.

Accessory bar (above the software keyboard, hidden with a hardware
keyboard):

- Default keys: Esc, Tab, Ctrl (sticky one-shot, double-tap to lock), Alt
  (same), arrows (one key with a drag pad: drag left, right, up, down;
  repeat while held), `~`, `/`, `|`, `-`, and a paste key. Long-press shows
  variants (Home/End/PgUp/PgDn on arrows, F1 to F12 on Esc).
- The key set is a setting (`ios.terminal.accessoryKeys`, ordered list);
  each key is an action id from the shared catalog, so agents and settings
  name the same keys.
- Sticky modifiers apply to the next key from either keyboard and clear
  after it.

Touch:

- Tap: focus the terminal (shows the keyboard). With mouse tracking on, a
  tap also sends a click at that cell.
- Pan: scrolls local scrollback (client view state). In the alternate screen
  with mouse tracking on, pan sends wheel events instead; with alternate
  scroll mode (1007) on and no mouse tracking, pan sends arrow keys.
- Long-press: starts a selection at the word; handles extend it
  (`UITextInteraction`-style handles drawn by the app over Ghostty's
  selection API). The edit menu (`UIEditMenuInteraction`) offers Copy, Paste,
  Select All, Open Link. Selection on off-screen history fetches pages from
  the host (section 7).
- Pinch: font size (view state). The new viewport is reported when the
  gesture ends, not during it.
- Two-finger tap: paste (setting, default on).

## 6. Resize and grid ownership

Definitions:

- Viewer: one attached view of one terminal (a Mac pane, a phone terminal
  view, a TUI pane). One device may hold several viewers.
- Viewport: the cells a viewer can show at its current pixel size and font
  (`cols`, `rows`), clamped to at least 2 x 1.
- Counting: a viewer counts toward the grid while (a) it is attached,
  (b) its presence says `visible: true`, (c) it has reported a viewport, and
  (d) its counts override is not `false`.
- Canonical grid: `cols = min(viewport.cols)` and `rows = min(viewport.rows)`
  over counting viewers, computed component-wise (so the result can come
  from two different viewers). With no counting viewer the grid keeps its
  last size.

This is the `smallest` policy of the existing shared-sizing reducer
(`cmux-tui-core/src/sizing_policy.rs` and `Packages/Shared/CmuxTerminalSizing`,
fixtures in `schemas/terminal-sizing/`). The session host is the only writer.

iOS rules that make "smallest wins" livable:

1. A phone viewer is `visible: true` only while its terminal view is on
   screen, the scene is foreground-active, and the device is unlocked. App
   switcher, background, lock, another tab in front, or the Home screen all
   send `visible: false` at once, so a phone in a pocket never shrinks a Mac
   user's grid.
2. The software keyboard does not change the reported viewport. The
   viewport is computed from the view's full height. When the keyboard
   covers the bottom, the view pans so the cursor row stays visible above
   the keyboard and the accessory bar. Otherwise each keyboard show and hide
   would resize the shared grid and reflow every other viewer.
3. Rotation, split view and pinch report the new viewport once, at the end
   of the transition or gesture.
4. Previews (Home list, tab switcher thumbnails) attach with
   `counts: false`.
5. Hysteresis: the host applies a viewport report at once when it shrinks
   the grid; it applies a report that grows the grid after 250 ms without a
   further report from the same viewer, so a burst of reports causes one
   reflow.

Every grid change is one host commit: new `generation`, `ioctl(TIOCSWINSZ)`
on the PTY, the size-state event, then a snapshot frame tagged with the new
generation on every viewer's channel. A viewer drops `bytes` frames whose
generation is older than the last snapshot it restored.

Example (same terminal):

| Event | Mac A viewport | iPhone viewport | Mac B viewport | Counting | Grid |
| --- | --- | --- | --- | --- | --- |
| Mac A attaches | 200 x 60 | | | A | 200 x 60 |
| iPhone opens it, portrait | 200 x 60 | 46 x 38 | | A, phone | 46 x 38 |
| Keyboard shows | 200 x 60 | 46 x 38 (unchanged) | | A, phone | 46 x 38 |
| Phone rotates to landscape | 200 x 60 | 98 x 18 | | A, phone | 98 x 18 |
| Mac B attaches | 200 x 60 | 98 x 18 | 120 x 50 | A, phone, B | 98 x 18 |
| Phone goes to background | 200 x 60 | hidden | 120 x 50 | A, B | 120 x 50 |
| Mac B user sets counts off | 200 x 60 | hidden | 120 x 50 | A | 200 x 60 |
| Mac A hides the tab | hidden | hidden | 120 x 50 | none | 200 x 60 (held) |

Kick: any attached participant may kick another (U6). The host commits it,
sends `kicked {by}` to the target, closes that viewer and recomputes the
grid in the same commit. The kicked phone shows "Disconnected by <name>" and
reattaches only on a user tap.

## 7. Scrollback

- The host owns the full scrollback (and the durable transcript where
  enabled). The phone holds a window: the active screen plus at most
  `ios.terminal.scrollbackBytes` (default 8 MiB) of history.
- Attach restores READY only. History pages follow lazily: the first
  `ios.terminal.prefetchRows` (default 1,000) rows at once, older pages when
  the user scrolls within 2 screens of the top of the local window. Pages
  are prepended through the snapshot HISTORY phase, newest first.
- New daemon op `terminal.history {terminal, before, max_bytes}` returns
  snapshot HISTORY pages older than a host row marker. Request file:
  `.cmux-scratch/nx-worker/cli-requests/terminal-snapshot-history.md`.
- When the local window is full, the oldest pages are dropped. Scrolling
  back past them fetches again.
- Search: within the local window with Ghostty's search; a "search all
  history" action runs on the host and returns row markers, which the phone
  fetches and reveals.
- Copy of a selection that reaches beyond the local window asks the host
  for the text of that range (`terminal.read_range`), so copy is never
  silently truncated.

## 8. Latency budget

Keystroke on the phone to the echoed glyph on the phone's glass:

| Stage | Budget |
| --- | --- |
| Touch or key event to encoded bytes | 1 ms |
| Send (no Nagle, small frames, one stream per terminal) | 1 ms |
| Network RTT | same LAN 5-10 ms; nearby region 20-40 ms; relayed 60-150 ms |
| Host: write to PTY, app echo, read | 1-2 ms |
| Host output coalescing | flush when idle or after 2 ms, whichever first |
| Phone: parse and mark dirty | under 1 ms for an echo |
| Next vsync and present | up to 8.3 ms at 120 Hz, 16.7 ms at 60 Hz |

Target: under 30 ms on the same LAN, under 60 ms in-region. The path badge
from lane 12 (`direct_lan`, `direct_wan`, `relayed`, `via_cloud_region`)
and the live RTT show in the terminal header, so a slow path is visible.

## 9. Power and memory

- Idle terminal on screen: no display link, no timers, no network traffic
  except transport keepalives owned by lane 12. Zero frames while nothing
  changes.
- Output-heavy terminal: at most one frame per vsync; parsing happens on the
  serial IO queue; the flood rule in section 2 bounds the work.
- Background: within the iOS background grace period the app sends
  `visible: false` presence, closes the terminal channels with
  `channel.close {reason: "background"}`, and keeps only the control
  connection lane 12 allows. On foreground it reattaches every visible
  terminal from a snapshot; target under 300 ms to first frame on the same
  LAN.
- Live surfaces: visible terminals only, plus up to two recently shown ones
  kept warm (terminal state, no GPU resources). Others are released and
  reattach from a snapshot.
- Memory warning: release GPU resources of non-visible surfaces, trim each
  local scrollback window to the prefetch size, drop warm surfaces.
- Thermal state serious or critical, or Low Power Mode: cap output frames at
  30 per second and disable cursor blink.
- Budget: under 150 MB resident for three live terminals with default
  scrollback on an iPhone 15-class device. Verified with Instruments
  (Allocations, Metal System Trace, Energy) during the lane 14 dogfood.

## 10. GhosttyNextKit pipeline

- Current pin for lane 14 (2026-10-03): release ios-v4,
  https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-76db9d14f3cd66cb026d56a0bd46eecaa085ece4-ios-v4/GhosttyNextKit.xcframework.zip,
  sha256 `e8f62d62a48eec2c685e997ba8efff2bb34712784f2d4aed988c38b691771126`.
  New API: `ghostty_surface_set_grid(s, cols, rows, generation)` (older
  generation refused; larger grid crops at the top-left, smaller grid pads
  in the background color, MANUAL_MIRROR never reflows) and
  `ghostty_surface_grid`; `ghostty_surface_restore_snapshot(s, bytes, len,
  phase)` and `ghostty_surface_encode_snapshot(s, write_cb, userdata,
  phase)` with phases READY=0, HISTORY=1, COMPLETE=2;
  `ghostty_surface_snapshot_version()` (1). set_grid, restore and encode run
  on the process_output serial queue. Also: surface calls no longer block
  on the renderer mailbox, 72 DPI fonts on iOS, IOSurfaceLayer detach before
  renderer free, bounded (100 ms) swap-chain release on hide. Evidence:
  ghostty-next PR 6 (CI: 101 Zig tests incl. a byte-equal snapshot round
  trip); `next/ios-render-smoke.sh --release` on the build host passes fill,
  grid (10x5 grid red only inside, stale generation refused) and snapshot
  restore. iOS draw contract (from ios-v3): no display link; the renderer
  thread draws on change and ghostty_surface_draw draws on main; the
  embedder view is a plain UIView passing pixel sizes from layoutSubviews.
  Never pin ios-v1 (module GhosttyKit) or ios-v2 (draws black).
- Status 2026-10-02: first release
  `xcframework-e699e418bf5e16bac6451dc44bd0c82907af58bc-ios-v1`
  (zip 96,269,903 bytes, sha256
  `781ef33200e19d5eb381c85e23c9a92ddd7351f07a3792c043de9bb61eac0d8c`,
  attestation verified with `gh attestation verify`). `next/smoke.sh
  --release` downloaded it, checked the sha256, linked all three slices,
  and ran `ghostty_init` plus a config round trip on macOS and in an iOS 27
  simulator on the build host. Two builds of one commit were not
  byte-identical: archive timestamps (fixed with `ZERO_AR_DATE=1`) and the
  Zig global cache path embedded in C objects from packages (open). Push and
  pull_request triggers did not start runs on the new repository;
  `workflow_dispatch` works and is the publish path until that is fixed.
- Workflow `next-xcframework.yml` in ghostty-next on a Blacksmith macOS 26
  runner (`blacksmith-6vcpu-macos-26`; repository variable
  `GHOSTTY_NEXT_MACOS_RUNNER` overrides). Never on a developer Mac. The
  fleet controller has no Ghostty recipe today (`cmux-ci` lists `cmux`,
  `ios`, `chromium`, `cmux-browser`), so the hosted runner is the
  reproducible lane.
- `next/build-xcframework.sh` pins Zig (version and SHA-256) and the Xcode
  path from `next/toolchain.env`, downloads the Metal toolchain when
  missing, builds `-Dxcframework-target=ios -Doptimize=ReleaseFast
  -Dsentry=false -Di18n=false`, and packages with
  `next/package_xcframework.py`: a deterministic zip (sorted entries, fixed
  timestamps and modes), `SHA256SUMS`, and `manifest.json` (commit, upstream
  base, Zig, Xcode and SDK versions, flags, per-slice SHA-256).
- A push to `main` publishes release `xcframework-<sha>-<flavor>` (flavor
  `ios-v4` at the time of writing; asset `GhosttyNextKit.xcframework.zip`) with the zip, sums, manifest and a build provenance attestation.
  A release is never replaced. Pull requests build and upload a workflow
  artifact only. `workflow_dispatch -f verify_reproducible=true` rebuilds on
  a second runner without caches and compares slice hashes.
- The iOS app pins one release with SwiftPM:
  `.binaryTarget(name: "GhosttyNextKit", url: "https://github.com/manaflow-ai/ghostty-next/releases/download/<tag>/GhosttyNextKit.xcframework.zip", checksum: "<sha256>")`,
  and Swift code does `import GhosttyNextKit`. The C API (`ghostty_*`) is
  unchanged.
  The zip SHA-256 is the SwiftPM checksum. A pin change is one reviewed
  commit that changes both values. `gh attestation verify` checks
  provenance.

## 11. Requests to other lanes

- Lane 12 (transport): `terminal_bytes` channel frames carry `kind`
  (`snapshot` keyframe or `bytes`), `generation`, `offset`; per-viewer
  credit and the `behind` resync of section 2; `presence.set` carries
  `visible` and `counts`; path badge and RTT exposed to the terminal view.
- cmux-tui owner (through the coordinator): capability
  `terminal-snapshot-v1` (snapshot attach, resync on overflow, `resized` as
  a snapshot), `terminal.history`, `terminal.read_range`, idle screen digest,
  grow hysteresis in the sizing reducer (fixture first). File:
  `.cmux-scratch/nx-worker/cli-requests/terminal-snapshot-history.md`.
- Lane 14 (iOS): consume GhosttyNextKit only through the pinned release; adopt
  the visibility, keyboard and preview rules of section 6; settings keys in
  sections 4, 5 and 7 go to the settings catalog with documented defaults.

## 12. Verification plan

- ghostty-next CI: Zig tests for manual-mirror (replies dropped, input
  encoded with mirrored modes, process_output parsed) before each
  xcframework build.
- Fidelity corpus: a set of recorded PTY byte streams (shell, editors in
  the alternate screen, Kitty graphics, wide and combining characters,
  hyperlinks). For each, the host and the phone library parse the stream;
  their READY snapshots must be byte-equal when versions match.
- Sizing: new fixtures in `schemas/terminal-sizing/` for visibility, counts
  off, grow hysteresis, and the example table in section 6; both reducers
  replay them.
- Flood: a 100 MB output test over a throttled link; the phone's memory and
  frame rate stay inside section 9, and the final screen equals the host's.
- Device: lane 14 dogfood on Lawrence's iPhone (no TestFlight, IOS1).

## 13. Open questions

- Mac Catalyst for the Home screen (IOS3) would need a `maccatalyst` slice;
  not built until IOS3 picks Catalyst.
- Whether `visible: false` should also apply when the phone shows the
  terminal in a small Home preview while the user reads messages (rule 4
  treats previews as non-counting).

## 14. Decided (coordinator, 2026-10-02)

- D1: the next upstream sync of `manaflow-ai/ghostty` reverts upstream
  `7a171895dd`, so the shipping iOS app keeps its iOS slices (section 1).
- D2: the session host gets the snapshot encoder by syncing
  `manaflow-ai/ghostty` past upstream `snapshot.h`; the desktop app and the
  daemon keep one parser. Byte replay stays behind `terminal-snapshot-v1`
  until then.
- D3: GHOSTSNP v1 is used with an on-screen Kitty image replay after each
  snapshot and an exact snapshot version match (section 2).
- D4: no Ghostty surface call blocks its caller (section 3, item 8).
- D5: iOS encodes keys with Ghostty's encoder from `pressesBegan`; no Swift
  key table (section 5).
- D6: input reaches `io_write_cb` synchronously on the caller's thread.
- D7: releases that are not bit-reproducible are accepted for now; the
  sha256 pin and the attestation protect integrity; the cache-path leak is
  fixed later.
- D8: the iOS grid rules of section 6 (keyboard never changes rows, a phone
  counts only while foreground and visible, 250 ms grow delay, previews do
  not count).
- D9: the ghostty-next xcframework and Swift module are named
  GhosttyNextKit, not GhosttyKit.
