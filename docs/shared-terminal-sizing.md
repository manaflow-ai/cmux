# Shared terminal sizing

A terminal has one PTY grid. Several people and devices can view it: Macs, iPhones,
iPads, the cmux-tui frontend. This document is the contract for who sets that grid,
how every viewer shows the bounds, and how a viewer is disconnected. It applies the
same way to local Mac terminals and to Cloud VM terminals.

## Owners

The process that owns the PTY decides the size. It is the **host**.

| Terminal | Host | Relays | Leaves |
| --- | --- | --- | --- |
| Local Mac terminal | cmux macOS app (`TerminalController`) | none | the Mac itself, paired iPhones/iPads |
| Cloud VM terminal | cmux-tui daemon on the VM | each Mac mirror (`CloudTuiManualMirrorSession`) | Macs, iPhones/iPads behind a Mac, TUI clients |

A relay never decides. It forwards each leaf behind it to the host as its own
participant (for cmux-tui, one attached-view lease per leaf) and forwards the
host's size state and detach events back down unchanged.

Both hosts run the same reducer:

- Swift: `Packages/Shared/CmuxTerminalSizing` (`TerminalSizingEngine`).
- Rust: `cmux-tui/crates/cmux-tui-core/src/sizing_policy.rs`.

`schemas/terminal-sizing/fixtures.json` is the conformance corpus. Both test suites
replay every case. A behavior change starts with a new fixture.

## Participants

A participant is one attached view: `id` (host-scoped, unique while attached),
`user_id` (verified Stack user id, set by the host or relay, never by the leaf),
`display_name`, `device_kind` (`mac`, `iphone`, `ipad`, `tui`, `browser`,
`unknown`), `device_name`, `via` (relay participant id, if any), `viewport`
(`cols`, `rows`, absent until reported) and `counts_override` (`true`, `false` or
absent).

A participant **counts toward size** when it is attached, has a viewport, and:

- `counts_override` is set: use it (tmux `attach -f ignore-size` is `false`).
- otherwise, in `smallest` and `largest`, every attached participant counts.
- otherwise, in `latest`, `priority` and `fixed`, a phone or tablet does not count
  while a `mac` or `tui` participant of the same `user_id` is attached. Every
  other participant counts.

The priority key is `<user_id or "anon:" + id>/<device_kind>`, so a priority list
survives reconnects and can rank "Maya's Mac" above "Maya's iPhone".

## Policy

`mode` is one of:

- `smallest` (default, "Fit everyone"): component-wise min over counting
  participants, so every attached device sees the whole grid.
- `latest` (tmux 3.1+ `window-size latest`): the counting participant with
  the newest activity. Activity is attach, explicit focus-click, and keyboard,
  paste or mouse input. Hover and background tabs are not activity.
- `largest`: component-wise max over counting participants.
- `priority`: the first key in `priority` that matches a counting participant
  (newest activity breaks ties inside one key). No match falls back to `latest`
  with reason `priority-fallback`.
- `fixed`: `fixed.cols` × `fixed.rows`, whatever is attached.

`owners` lists the participants that set a dimension, in attach order. A
viewport is clamped to at least 2 × 1.

With no counting participant the grid keeps its last size (reason `held`). An
owner detach selects the next owner in the same step. The grid never freezes
waiting for a departed owner.

Policy scope is a workspace default plus an optional per-terminal override. Any
workspace member with write access can change it. Every host emits the change to
all participants.

## Size state (wire format)

Hosts publish one JSON object per change, the same shape on both hosts:

```json
{"generation":7,"cols":118,"rows":38,"reason":"latest","owners":["c3"],
 "policy":{"mode":"latest","priority":[],"fixed":null},
 "participants":[{"id":"c3","user_id":"u_maya","display_name":"Maya Ortiz",
   "device_kind":"mac","device_name":"Mac Studio","via":null,
   "viewport":{"cols":118,"rows":38},"counts_override":null,
   "counts":true,"priority_key":"u_maya/mac"}]}
```

`generation` increases by one whenever any other field changes. Activity is not
published; it changes the state only when it changes the owner.

- cmux-tui: event `size-state` on the attach stream and to subscribers; command
  `get-size-state`.
- Mac mobile RPC: `mobile.terminal.size_state` push and a `size_state` field in
  `mobile.terminal.replay`.

## Commands

| Action | cmux-tui | Mac mobile RPC / socket |
| --- | --- | --- |
| Set policy | `set-size-policy {surface?, workspace?, policy}` | `terminal.size_policy.set` |
| Counts override | `set-size-counts {surface, client?, lease?, counts}` | `mobile.terminal.viewport` `counts_override` |
| Disconnect one | `detach-client {client, by}` / `detach-attached-view {surface, lease, by}` | `terminal.participant.disconnect` |
| Disconnect others | `detach-client` for each | `terminal.participants.disconnect_others` |
| Reattach | normal attach | `mobile.terminal.reattach` |

## Detach

A detached leaf receives `detached {surface, reason, by?}`. `reason` is
`network`, `disconnected-by`, `host-shutdown` or `superseded`. `by` carries the
actor's `user_id`, `display_name` and `device_name`.

- `network`: reconnect automatically, keep the priority slot.
- `disconnected-by`: never reconnect automatically. iOS shows "Detached from
  <tab>", who and when, with **Reattach** and **Reattach as viewer**. A Mac mirror
  shows the same state in the pane.
- A relay that receives `disconnected-by` for one of its leaves forwards it to that
  leaf only and keeps its own attachment.
- A relay that is itself detached for any reason but `network` forwards the same
  `reason`, `by` and `at` to every leaf behind it, since they lost their path to
  the terminal, and drops their sub-views. After the relay reattaches, each leaf
  reattaches normally.

The Mac socket `terminal.size_state` (and `cmux surface size`) adds
`detachment {reason, by, at}` while this Mac view is detached, else `null`; the
grid it reports is then the last state seen before the detach.

Disconnecting is not unpairing. Pairing revoke stays in pairing settings.

## Showing the bounds

Every viewer whose viewport differs from the grid draws, from the size state
(a viewer whose viewport equals the grid draws none of it, even while others
are attached):

- a 1 pt border around the grid in the separator grey (below);
- a faint hatch outside the grid, so empty space never reads as blank output;
- one small chip outside the grid's bottom-right corner,
  `118×38 · Maya's Mac` (plus `· 12 cols hidden` when the viewer is smaller),
  that opens the size panel. It never covers the grid's last row: on the
  iPhone it goes in the letterbox below, beside or above the grid, and when
  the grid fills the viewport it shrinks to `118×38` at the viewport's
  top-trailing corner;
- when the viewer is smaller, a short fade on the cut edge;
- on each change, the border animates to the new grid. There is no HUD.

The sizing UI uses one grey, the one every other border in the app uses. On
the Mac that is the workspace's split divider / tab-bar separator color
(`BonsplitConfiguration.Appearance.separatorColor`, from `pane-border-color`,
Ghostty `split-divider-color`, or the chrome background). The grid border, the
chip outline and the owner ring draw in it; the hatch, cut-edge fade, chip tint
and avatar fills derive from it with opacity. There are no per-participant
colors; the owner is marked by a thin ring on its avatar.

On the Mac, the tab shows only while someone else is attached, and never
shows this view itself. It draws one grey initials circle per other person
(grouped by `user_id`) and, for this user's own other devices, one grey device
glyph per device kind (iPhone, iPad, laptop, terminal). Up to three items,
owner first with the neutral ring, then `+N`. Its tooltip is `Size set by Maya's Mac · 118×38`, and clicking it
toggles the size panel. The panel always hangs from the tab (the accessory, or
the tab itself when the accessory is hidden), whichever entrypoint opened it:
tab, pane chip, context menu, command palette or shortcut. It holds the grid
and owner, a Size mode menu (with a cols × rows field pair in Fixed), one row
per participant ("sets size" on the owner, "not counted" on a participant the
grid ignores; a hover menu with Counts toward
size and Disconnect; drag handles in Priority), and "Disconnect Others" with an
inline confirmation. "Size to My Window" lives in the tab context menu, the
palette and the shortcut. The tab context menu adds Size to My Window, a
Terminal Size submenu with the five modes, and Disconnect Others… while anyone
else is attached.
The iPhone size sheet uses the same grey avatars and marks rows "Sets size"
or "Not counted" the same way. Its greys use the platform separator color
(`UIColor.separator`); the Mac uses the separator token above.

On the iPhone, when the grid is larger than the phone, the phone renders the
exact shared grid scaled to its width and pinned to the bottom. Pinch zooms
and pans; the chip then adds `· scaled`. The phone shows sizing chrome only
after the host's latest size state includes the phone's confirmed viewport
and no viewport report of its own is pending, so it never draws bounds for a
grid it is about to change. While the displayed grid's top edge is inside the
viewport (scaled or letterboxed), the phone hides the scroll-edge band of
scrollback above the grid, so that area shows only the hatch and the chip.

The cmux-tui frontend joins as `device_kind: "tui"` named after its host
(`cmux-tui` when the host name is unknown). It takes the size state from the
`attach-surface` answer, so it never waits for the first change event. Focus
and input on its pane are activity only; against a `shared-sizing-v1` daemon it
never sends the legacy `set-client-sizing`, so a counts choice made on another
device stays. Its
pane's bottom border carries the chip text, ` 118×38 · Lawrence's Mac `
(plus `· 12 cols hidden` when the TUI is narrower), under the same rule: only
while someone else is attached or the TUI's viewport differs from the grid.
Clicking it, or the pane context menu, opens a Terminal size menu with the five
modes (Fixed keeps the current grid, Priority puts this client first) and one
submenu per participant with Counts toward size and Disconnect. Against a
daemon without `shared-sizing-v1` the TUI keeps its legacy per-client menu.

## Mac ↔ iPhone payloads

The Mac is the host of local terminals and the relay of Cloud terminals. The phone
sees one shape for both.

- `mobile.terminal.viewport` gains `device_kind`, `device_name` and
  `counts_override` (`null` clears it). The Mac sets `user_id` from the
  authenticated connection. The phone's participant id is `mobile:<client_id>`.
- `mobile.terminal.replay` requests carry the phone's viewport on the first
  replay: `client_id`, `viewport_columns`, `viewport_rows`,
  `viewport_generation`, `device_kind`, `device_name`. The Mac registers or
  updates the phone participant and applies the resulting grid before it
  captures, so one connect is one grid change, straight to the fitted grid.
  Results gain `size_state` (the wire object above) and `self_participant_id`.
- Push event `mobile.terminal.size_state {surface_id, state, self_participant_id}`
  on every published change.
- Push event `mobile.terminal.detached {surface_id, reason, by, at}`; `at` is
  ISO 8601. After it the Mac drops the phone's viewport and input for that surface
  until `mobile.terminal.reattach {surface_id, as_viewer}`, which answers like
  `replay`. `as_viewer: true` sets `counts_override: false`.
- `mobile.terminal.size_policy.set {surface_id, policy}` and
  `mobile.terminal.participant.disconnect {surface_id, participant_id}` let the
  phone use the same size panel.

For a Cloud terminal the Mac forwards the phone to cmux-tui as a relay
sub-view with the same identity (created or updated from the replay's
viewport before anything is captured). Until the host's state shows that
viewport (at most 3 s), the replay answers `viewport_transition` and the phone
retries, so its first frame is already at the host's new grid. The Mac forwards
`size-state` as
`mobile.terminal.size_state` (participant ids are the host's ids), and maps a
`detached` for that lease to `mobile.terminal.detached`. A non-network `detached`
for the Mac's own attachment goes to every phone viewing the terminal through
this Mac as `mobile.terminal.detached` with the same `reason`, `by` and `at`.

## cmux-tui wire parameters

The daemon advertises `shared-sizing-v1` in `identify`. Without it a Mac mirror
keeps the legacy claim and resize path, and phones behind it are not forwarded.

- `set-client-info` gains optional `user_id`, `display_name`, `device_kind`,
  `device_name`.
- `attach-surface` responses gain `participant` (the host id of this view).
- A relay sub-view (a phone behind a Mac) has no byte stream:
  `resize-attached-view {surface, view: "mobile:<client_id>", identity:
  {user_id, display_name, device_kind, device_name}, cols, rows}` creates or
  updates it, keyed by (connection, `view`), and answers `{participant}`.
  `release-attached-view-size` and `detach-attached-view` also accept
  `{surface, view}`.
- `set-size-policy {surface, policy}`; `set-size-counts {surface, lease? | view?
  | participant?, counts: true | false | null}`; `get-size-state {surface}`
  answers `{state}`.
- Event `size-state {surface, state}`.
- `note-size-activity {surface, view?}` records explicit activity for this
  connection's participant, or for a relay sub-view with `view`.
- A client opts in by listing `shared-sizing-v1` in `set-client-info`
  `capabilities`; without it the daemon sends no `size-state` events.
- `detach-client {client, by}` takes a numeric client id or a participant id.
  `detached` gains `reason`, `by` and, for a relay sub-view, `view`; the relay
  keeps its own attachment and forwards the event to that leaf.
