# Sync UX: animation of synced changes, and terminal sizing across clients

Status: design + phase 1 implementation, 2026-10-19 (sync-ux lane, worktree
`feat-cmux-next-sync-ux`). Base read: `origin/feat-cmux-next` fa5ed5c04741,
`origin/feat-cnx-ios` 2f6c8a76d9b5. Companion: `plans/cmux-next/object-sync/DESIGN.md`
(identity and events this design relies on, section 5.3 there). Binding inputs:
`plans/cmux-next/motion.md` (tokens, rules 1-10), `docs/shared-terminal-sizing.md` (the sizing
contract), spec `terminal-frames.md` section 6 and `00-overview.md` U6, lane rules (decouple from
Swift, one protocol, no unit tests).

The ask (Lawrence, 2026-10-19): synced state changes (this client, another client, a remote host, a
Chief) must animate and look seamless: inserts, removals, reorders that move to the new place, and
renames that transition the text with no layout pop. One animation model for Mac, web and iOS.
Second: terminal and session sizing when clients with different screens view one session; decide
from first principles whether "smallest client wins" is right; offer policies with a great default;
specify the protocol and the treatment of clients that do not own the size; implement in the daemon
and the Mac app, with iOS on the same protocol.

## 0. Summary

1. Motion: a synced list animates the difference between what it draws and the new state, keyed by
   object id, batched per frame, on the existing critically damped springs (`move`, `appear`,
   `disappear`) and fades (`fadeIn`, `fadeOut`, `crossfade`). No motion for the first state, a
   snapshot (resync, reconnect, gap), a re-sort of more than 12 rows, off-screen rows, or a change
   the local user already sees (direct manipulation, optimistic intent). Reduce Motion: positions
   change in one frame; a rename keeps a crossfade of at most 0.1 s.
2. The Mac sidebar already follows most of this (keyed `SidebarListView`, one `move` spring for
   moves, inserts and removals, title crossfade). Gaps found: tab titles swap with no transition,
   a new row only opens with `ui.animations.newWorkspace` on (off by default), and the daemon's
   `origin` is dropped before the UI. The web views had no shared list motion for synced lists;
   cnx-ios animates with SwiftUI defaults and ignores Reduce Motion on its lists.
3. Sizing: the daemon and both reducers (Rust `cmux-terminal-sizing`, Swift `CmuxTerminalSizing`)
   already implement five policies (`latest`, `smallest`, `largest`, `priority`, `fixed`) with
   participants, counts overrides, a per-terminal override and a workspace default. The default was
   `smallest` (spec U6). From first principles the default should be **last active** (`latest`),
   with one change to its rules: a phone's or tablet's attach is not activity, and a phone is no
   longer silenced by its user's Mac in `latest`. The person typing gets a full-size terminal; a
   glance from a phone changes nothing; typing on the phone hands it the grid; typing on the Mac
   takes it back.
4. Clients that do not own the grid draw it padded (larger view) or cropped (smaller view), with a
   hatch, a 1 pt border and a chip `Sized for Mac Studio · 118×38`, and a one-click **Take over**.
   The CmuxNext app had none of this (it does not even subscribe to `size-state`); phase S3 adds it.
5. Non-PTY views (agent conversations, Chief, pages, sidebars) never share a size: each client
   lays them out for its own window. Only PTY grids (terminals, TUI agents in a terminal) need one
   size, and remote browser streams follow their own viewer rule (spec `remote-tab.md`).

## Part 1. Animation of synced changes

### 1.1 What exists today (read from code)

| Client | List | Identity | Moves | Inserts / removals | Renames | Reduce Motion |
| --- | --- | --- | --- | --- | --- | --- |
| Mac sidebar | `SidebarListView` (custom layer-backed NSView, `CmuxNextSidebar/Views`) | `SidebarRowKey` (workspace id, tab id, group id) | `RowMotion.run` on `move`, from the drawn frame | open/close their slot on `move`; a new workspace row opens only with `ui.animations.newWorkspace` (off by default) | `WorkspaceRowView.animateTitleChange`, `sidebar.workspaceTitleMotion` crossfade (default) | `Motion.animatesMovement` snaps rows; title transition skipped |
| Mac tab strip | `TabStripView` | `TabID` | additive CA tweens (200 ms, Chrome curve), "reorders keep their motion" | `ui.animations.newTab` | **none**: `TabCell.applyItem` sets `titleLayer.string` with actions disabled | movement snaps |
| Web (React) | New Tab lists use `useListMotion` (FLIP); every synced list (`SessionSidebar`, `HomeLists`, cloud `MachineList`, Home conversations, the web sidebar prototype) has **none** | `key={row.id}` | none | none | none | n/a |
| iOS (cnx-ios) | SwiftUI `List` + `ForEach` keyed by workspace id (`WorkspacesList.swift`) | workspace id | `.animation(smooth, value: ids)`: SwiftUI's default list move | same | **none** (no `contentTransition`) | **ignored** on these `.animation` calls |
| Daemon events | `WorkspaceDelta` / `TabDelta`: per-op data, entity snapshot, revision, `origin`, `mutationID`, `clientTransactionID` | | | | | |

`origin` and `mutationID` are decoded in `CmuxNextDaemon/Events` and then dropped in
`DaemonStore+Events.swift`; only `clientTransactionID` confirms local intents.

### 1.2 First principles

- The eye tracks objects, not slots. A moved row must be the same visual object travelling to its new
  place; a renamed row must stay where it is and change its text. So identity has to be the object
  id (object-sync 5.3: owner-assigned, never reused, a rename changes a field), and the renderer
  must keep one view per id across updates. Any position-keyed list breaks this.
- Motion explains a change the viewer did not cause. A change the local user just made is already on
  screen (drag release, inline rename, optimistic intent): animating it again is a double take. A
  change from elsewhere (another device, a Chief, an agent) needs the motion most.
- Motion must never lie about state or delay it. The model takes the new state at once; animation is
  presentation only, interruptible and retargeted from what is on screen (motion.md rule 6).
- Bursts are one change. Ten events in one frame are one transition per row. Animating them in
  sequence reads as jitter and costs frames.
- Some changes are not changes to explain: the first paint, a resync after a gap, a re-sort that
  moves most rows. Animating these is noise; they apply in one frame.
- Off screen there is nothing to explain. A row that is off screen before and after does not move;
  a row that enters or leaves the viewport starts or ends just past the edge, so a long jump never
  streaks across the list.
- Physics: critically damped springs (never past the target), the structural tokens that already
  exist. No new constants.

### 1.3 Alternatives compared

| Option | Identity | Bursts | Interrupt | Cost | Verdict |
| --- | --- | --- | --- | --- | --- |
| A. Re-render and let each platform's list animate (NSTableView row animations, SwiftUI `List` defaults, CSS transitions) | per platform | no model; SwiftUI animates every intermediate state | varies | low | Rejected: NSOutlineView animates only insert/remove, SwiftUI defaults ignore Reduce Motion and animate snapshots, the web has nothing. Three behaviors. |
| B. The sync layer emits animation commands ("move row 3 to 7") | positional | owner decides | poor | medium | Rejected: positions differ per client (filters, collapsed groups, pins); the owner cannot know what a client draws. |
| C. **Diff by id at the renderer, one planner, batched per frame, shared tokens** | object id | one plan per frame | from presentation | O(n log n) per batch | **Chosen.** Each client diffs what it draws against what it will draw; the same rules decide what animates. |
| D. Shared-element morph of every row (matched geometry everywhere) | id | yes | yes | high (layers per row, text snapshots) | Rejected as the default: costly and only needed for cross-container moves (tab to another window), which keep their own drag code. |

### 1.4 The model (all clients)

Planner input: the rows drawn now (or none: first state), the new rows, and flags. Output: per row
`kinds` (`insert`, `remove`, `move`, `rename`) and `animate`, and an overall `still` reason.

1. **Identity.** A row is its object id. A pending optimistic row carries the client-minted id that
   the owner accepts as the final id (object-sync 5.3 item 1), so confirmation changes nothing.
2. **Diff.** `move` = rows whose order changed relative to the rows kept (longest increasing
   subsequence of old positions; a row pushed down by an insert above is not a move, its slide comes
   from the layout delta). `rename` = title changed. `insert`, `remove` by id.
3. **Batch.** Events that arrive before the next frame fold into one plan
   (`createFrameBatcher` on the web, `FrameBatcher` in `SidebarBridge` on the Mac, one `Transaction`
   per run-loop turn on iOS).
4. **Still** (apply in one frame): `initial`, `snapshot` (resync, reconnect, gap), `burst` (more than
   12 rows moved), `motion-off` (`ui.animationSpeed: off`), `direct` (every event in the batch came
   from this client's own direct manipulation or an intent it already drew).
5. **Visible only.** A row off screen before and after does not animate. Entering or leaving rows
   start or end just past the visible edge.
6. **Drawing.**
   - Move: from the drawn place (including a running animation) to the new place on `move`
     (0.15 s, damping 1), translation only.
   - Insert: the rows below slide to make room on `move`; the new row fades in on `fadeIn` (0.12 s)
     in its slot (the Mac sidebar opens the slot's height on `move`, as today).
   - Remove: the row leaves the flow at once (held where it was), the rows below slide up on `move`,
     and it fades out on `disappear` and is dropped.
   - Rename: the old text fades out on `fadeOut` (0.08 s) over the new text fading in on `fadeIn`.
     A box that sizes to its text (a web tab, an iOS tab chip) springs its width on `move` so the
     neighbours slide; a title that fills its row (sidebar rows, Mac tabs, whose widths come from the
     strip's layout) keeps its width and only crossfades. No HUD, no highlight flash.
7. **Reduce Motion.** No translation or size animation. A rename keeps a crossfade of at most
   `crossfade` (0.1 s), as motion.md rule 7 allows for non-structural opacity changes; inserts and
   removals apply in one frame (no crossfade standing in for movement).
8. **Origin.** `origin` and `actor` from the event (object-sync 5.3 item 5) choose only `direct`
   versus animated. Remote changes never get a different, louder animation: the same motion, so a
   change from the phone and one from the Mac look the same on a third client.

### 1.5 Per platform

- **Web.** `webviews/src/motion/syncMotion.ts` (planner, batcher, tokens),
  `useSyncListMotion.ts` (FLIP on Web Animations sampled from the spring, so WebKit runs it on Core
  Animation), `SyncTitle.tsx` (rename crossfade, optional width spring). Adoption order: Home
  conversation list, `SessionSidebar`, cloud `MachineList`, the web sidebar prototype.
- **Mac.** Keep `SidebarListView` and `RowMotion` (already the model). Add: a crossfade on tab
  rename (`TabCell`, `Motion.crossfadeAction`, skipped on the first sync, under Reduce Motion and
  for the local inline rename); pass `origin` through `DaemonStore` so a direct change is `still`;
  the burst rule for re-sorts. No Swift data adapter is added: the store already owns the state.
- **iOS (cnx-ios, Abdulaziz's branch).** `ForEach` by id stays; replace the raw
  `.animation(theme.motion.smooth.animation, value: ids)` with the shared rule: an explicit
  `withAnimation(.spring(response: 0.15, dampingFraction: 1))` around applying a remote batch, no
  animation for snapshots and under `accessibilityReduceMotion`; titles get
  `.contentTransition(.opacity)` with `.animation(.easeOut(duration: 0.12), value: title)`. Same
  fixtures (`schemas/sync-motion/streams.json`) for its gallery. This lane does not edit
  `feat-cnx-ios`; the change is a follow-up for its owner (bead below).

### 1.6 Fixtures and gallery

`schemas/sync-motion/streams.json`: one initial list and five recorded streams (renames from another
Mac, a reorder from the iPhone, inserts and a removal from a second client, a 12 ms burst, a
reconnect snapshot), with the client that made each change. The web gallery entry
`motion.sync-list` (`webviews/src/motion/syncMotion.gallery.tsx`, area "Sync UX") replays each
stream on a Mac window frame and an iPhone frame side by side, with a Replay button; the gallery's
Reduced motion control shows the reduced path; variant `long-list-offscreen` checks the off-screen
rule. The entry is separate from the subagent-prototype search/toggles work in the gallery shell.

## Part 2. Terminal sizing across clients

### 2.1 What exists today (read from code)

- Reducer: `cmux-tui/crates/cmux-terminal-sizing` (Rust) and `Packages/Shared/CmuxTerminalSizing`
  (Swift), identical, replayed against `schemas/terminal-sizing/fixtures.json` by Rust
  (`cmux-mobile-core`), Swift and Kotlin (`cmux-mobile-ffi`). Modes `latest`, `smallest` (the default
  before this design), `largest`, `priority`, `fixed`; participants with user, device kind, device id, `via` (relay),
  viewport, counts override; `held` when nobody counts.
- Daemon: one engine per terminal runtime (`cmux-tui-core/src/mux/terminal_sizing.rs`), policy =
  per-terminal override, else workspace default, else the reducer default; both in memory only (lost
  on daemon restart). `set-size-policy`, `set-size-counts`, `get-size-state`, `note-size-activity`,
  `detach-client`, `reattach-view`; event `size-state` to clients that list `shared-sizing-v1`.
  Keyboard, paste and mouse input through `send` / `send-keys` count as activity automatically. One
  resize site: `apply_terminal_grid` then `resize_surface` then `TIOCSWINSZ` in `cmux-pty`.
  The spec's 250 ms growth hysteresis is not implemented.
- CmuxNext Mac app: legacy client. It reports its viewport (`resize-attached-view`), claims the grid
  with `set-client-sizing {exclusive}` on every visible size change, and hides with
  `set-size-counts`. It does not list `shared-sizing-v1`, so it never receives `size-state`; it locks
  its Ghostty surface to the announced grid (`ghostty_surface_set_grid`: a larger view pads, a smaller
  one crops) but draws no bounds, chip or take-over.
- cmux-tui TUI: full client (focus as activity, size menu, border chip).
- cnx-ios: sends `resize-surface` with the phone's grid, no `size-state`; its own audit lists
  "shared-sizing policy is unresolved". Classic iOS (`Packages/iOS`) speaks the Mac mobile RPC
  version, whose Mac emitter does not exist on this branch.

### 2.2 First principles

- A PTY has exactly one grid: every program in it (shell, `vim`, a TUI agent) formats for one
  `cols × rows`. Any shared policy makes some viewer non-native. The question is only who pays.
- The viewer who pays should be the one not interacting. Typing, pasting and clicking into the
  terminal are the signals of who is using it; looking is not.
- A size change is expensive: the program reflows or redraws, scrollback rewraps, every viewer
  re-renders. Policies must not flap (no change on a glance, on a keyboard show, on a background
  app, on a burst of window-resize reports).
- A non-owner must always see the whole truth: the exact grid, padded or cropped, never a reflowed
  fake, plus who owns it and a one-step way to take it.
- Only PTYs need this. Agent conversations, Chief, pages and every list are documents each client
  lays out for its own window; they must never be pinned to another device's size.

### 2.3 Policies compared

| Policy | Who pays | Flapping | Good for | Bad for |
| --- | --- | --- | --- | --- |
| `smallest`, "Fit everyone" (old default, tmux before 3.1) | every larger screen, all the time, even when the small viewer only watches | every attach of a small viewer shrinks everyone | pair-programming where everyone must see every cell | a Mac user whose phone or second Mac is merely open: a 200-column window shows 54 columns |
| `latest`, "Last active" (tmux 3.1+ default) | viewers who are not typing | only when the active person changes | one person moving between devices (the common cmux case: Mac at the desk, phone on the couch) | two people typing in turns (each turn reflows) |
| `largest` | every smaller screen (cropped) | attach of a large viewer | presenting on a big display | phones: always cropped |
| `priority` (ranked devices) | everyone below the first counting rank | when a ranked device comes and goes | "my Mac Studio always wins" | needs setup |
| `fixed` | everyone not that size | never | demos, recordings, reproducible bugs | everyone else |
| Per-client independent grids | nobody | n/a | impossible for one PTY | requires one PTY per viewer: a different program state per client |

### 2.4 Decision

Default **Last active** (`latest`), user-selectable per terminal (override) and per workspace
(default), with the other four modes kept. Rules (reducer, both languages, fixtures updated):

1. Activity is input (keyboard, paste, mouse) into the terminal, an explicit focus click, or
   **Take over**. Hover, scroll, background tabs and window resizes are not activity.
2. A desktop's attach is activity (the user opened that tab on that machine). A phone's or tablet's
   attach is **not** activity: a glance never takes the grid. A handheld that is the only counting
   view still sets the grid (nobody else is there).
3. In `latest` a phone is no longer silenced by its user's Mac (the old "phone defers to the same
   user's counting desktop" rule now applies only to `priority`). Typing on the phone hands it the
   grid; typing on the Mac takes it back.
4. Viewers that stop counting (hidden tab, app in background, locked phone, preview with
   `counts:false`) never own the grid; the owner then falls to the most recently active counting view.
5. Ties between handhelds whose attach was not activity: the later entry wins (both languages
   break ties the same way). An attach again (a reconnect) replaces the entry in place and resets a
   handheld's activity to 0: a phone that typed and then reconnects gives the grid back to the
   desktop that attached last, until it types again.
6. A client must name its device kind (`set-client-info` before the attach, or the relay
   sub-view's identity). A client with no kind is `unknown` and is treated as a desktop, so its
   attach is activity. The Mac's phone relay and cnx-ios do not send a kind yet: phase S3 and the
   iOS follow-up fix that, not the reducer.

Why not keep `smallest`: in the common case (one person, Mac plus phone or two Macs) it makes the
best screen the worst one whenever another device is open, and the iOS rules that "make smallest
livable" (visibility, keyboard, previews) exist only to fight that default. Why not `largest`: phones
are always cropped. `latest` puts the cost on whoever is not using the terminal, and the take-over
chip makes the hand-off explicit when needed. The spec's U6 ("the smallest attached viewer wins") is
superseded by this decision pending Lawrence's confirmation (decision D1 below); it is one value
(`TerminalSizingMode::default`), so reverting is one line plus the fixtures.

Two-people-typing ping-pong (the one weakness of `latest`): phase S4 adds a hand-off lease: a
non-owner's input takes the grid only after the owner has been idle for 1.5 s (Take over is always
immediate). It needs an injected clock in the reducer; until then `latest` behaves as tmux does.

### 2.5 Protocol (cmux-tui, unchanged frames, fields named)

Already on the wire (docs/shared-terminal-sizing.md "cmux-tui wire parameters"); this design uses
them as they are:

- Client viewport report: `resize-attached-view {surface, lease | view, cols, rows}` (relay
  sub-views add `identity`), `release-attached-view-size`. In `cmux.wire/1` terms this is
  `presence.set {viewport {cols, rows}, visible, active}` (object-sync 5.3 item 6).
- Visibility: `set-size-counts {surface, lease | view | participant, counts: true | false | null}`.
- Activity (the "active-client lease"): implicit on `send` / `send-keys` from an attached view;
  explicit `note-size-activity {surface, view?}` for focus clicks and **Take over**.
- Policy per session: `set-size-policy {surface, policy}` (terminal override, `null` mode clears it)
  and `set-size-policy {workspace, policy}` (workspace default). `policy = {mode, priority[], fixed}`.
- Published state: event `size-state {surface, runtime, state, self_participant}` and
  `get-size-state {surface}`; `state = {generation, cols, rows, reason, owners[], policy,
  participants[{id, user_id, display_name, device_kind, device_name, device_id, via, viewport,
  counts_override, counts, priority_key}]}`.
- Capability: a client lists `shared-sizing-v1` in `set-client-info.capabilities` to receive
  `size-state` on its attach streams.

Added by this design:

- Policy persistence (phase S2): the terminal override and the workspace default are part of the
  workspace document (journaled with the layout), so a daemon restart keeps them; `cmux.json`
  `terminal.sizing.defaultPolicy` (`latest` default) sets the default for new workspaces.
- Growth hysteresis (phase S2): a report that grows the grid applies after 250 ms without a newer
  report from the same view (spec terminal-frames 6 rule 5), with an injected clock (no sleep).

### 2.6 Visual treatment for non-owners

From the size state, a view whose own viewport differs from the grid draws (Mac, iOS, web, TUI the
same way; docs/shared-terminal-sizing.md "Showing the bounds" is the detailed contract):

- the exact grid, padded (larger view) or cropped with a short fade on the cut edge (smaller view);
  never reflowed to the view, never scaled on the Mac (the iPhone may scale to width, marked
  `· scaled`);
- a 1 pt border in the split divider color on sides that face unused space, and a faint diagonal
  hatch outside the grid;
- one chip outside the grid's bottom-right corner: `Sized for <device name> · 118×38`
  (`· 12 cols hidden` when cropped), and a **Take over** button in the same chip. Take over sends
  `note-size-activity` under `latest` and `priority`; under `smallest`, `largest` or `fixed` it sets
  the terminal override to `latest` and then notes activity, in one action, so the click always
  gives this view the grid;
- the chip shows only while the view does not own the grid or another device is attached; a view
  that owns the grid draws nothing extra.
- Motion: the border and hatch move with the grid on `move`; under Reduce Motion they jump. No HUD.

### 2.7 Phases and status

| Phase | What | Status |
| --- | --- | --- |
| S1 | Reducer default `latest`; handheld attach is not activity; phone deferral only in `priority`; tie rule; fixtures updated (red under the old rules, green under the new); daemon socket tests updated | this lane, landing |
| S2 | Policy persistence in the workspace document, `terminal.sizing.defaultPolicy` setting, growth hysteresis | next |
| S3 | CmuxNext Mac app: list `shared-sizing-v1`, decode `size-state`, note activity on focus click, bounds overlay and chip with Take over, size menu in the tab context menu | next |
| S4 | Hand-off lease (1.5 s owner idle) with an injected clock | after S3 |
| S5 | cnx-ios on the same protocol: `set-client-info` identity fields, `resize-attached-view` instead of `resize-surface`, visibility through `set-size-counts`, chip and take-over (owner: cnx-ios lane) | follow-up bead |

## Part 3. Decisions for Lawrence

- D1 Default terminal sizing policy. Reply `last active: the grid follows whoever last typed or took over; a phone glance never resizes the Mac (recommended)` or `fit everyone: the smallest attached screen always wins (old spec U6)` or `largest: the biggest screen wins, smaller ones are cropped`.
- D2 New workspace rows from other devices. Reply `open the row's slot with the move spring even while "new workspace animation" is off, because a remote insert needs explaining (recommended)` or `keep remote inserts instant while ui.animations.newWorkspace is off, as local ones are`.
- D3 Two people typing in one terminal under last active. Reply `add the 1.5 s hand-off lease so turns do not reflow on every keystroke (recommended)` or `keep tmux behavior: every keystroke from the other person takes the grid at once`.
