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

- `latest` (default, tmux 3.1+ `window-size latest`): the counting participant with
  the newest activity. Activity is attach, explicit focus-click, and keyboard,
  paste or mouse input. Hover and background tabs are not activity.
- `smallest` / `largest`: component-wise min / max over counting participants.
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

Disconnecting is not unpairing. Pairing revoke stays in pairing settings.

## Showing the bounds

Every viewer whose viewport differs from the grid draws, from the size state:

- a 1 pt border around the grid in the owner's color at 70% opacity;
- a faint hatch outside the grid, so empty space never reads as blank output;
- one small chip outside the grid's bottom-right corner,
  `118×38 · Maya's Mac` (plus `· 12 cols hidden` when the viewer is smaller),
  that opens the size panel;
- when the viewer is smaller, a short fade on the cut edge;
- on each change, the border animates to the new grid. There is no HUD.

Owner colors come from `TerminalSizingParticipantColor` (Swift, in
`CmuxTerminalSizing`; the iOS twin uses the same rule). The key is the
participant's `user_id`, else its `id`. The color is
`palette[fnv1a64(utf8(key)) % 10]` with FNV-1a offset `0xcbf29ce484222325`,
prime `0x100000001b3` and this palette, in order: `#3CC2B0`, `#EBA946`,
`#A688F5`, `#5AA9F2`, `#F07A8A`, `#7BC96F`, `#E58F4B`, `#C77DDB`, `#4FC1D9`,
`#D6C24A`.

On the Mac, the tab shows up to three attached people (owner first, with a
ring in the owner's color, `+N` for the rest) only while someone else is
attached. Its tooltip is `Size set by Maya's Mac · 118×38`, and clicking it
toggles the size panel. The panel always hangs from the tab (the accessory, or
the tab itself when the accessory is hidden), whichever entrypoint opened it:
tab, pane chip, context menu, command palette or shortcut. It holds the grid
and owner, a Size mode menu (with a cols × rows field pair in Fixed), one row
per participant ("sets size" on the owner; a hover menu with Counts toward
size and Disconnect; drag handles in Priority), and "Disconnect Others" with an
inline confirmation. "Size to My Window" lives in the tab context menu, the
palette and the shortcut. The tab context menu adds Size to My Window, a
Terminal Size submenu with the five modes, and Disconnect Others… while anyone
else is attached.

## Mac ↔ iPhone payloads

The Mac is the host of local terminals and the relay of Cloud terminals. The phone
sees one shape for both.

- `mobile.terminal.viewport` gains `device_kind`, `device_name` and
  `counts_override` (`null` clears it). The Mac sets `user_id` from the
  authenticated connection. The phone's participant id is `mobile:<client_id>`.
- `mobile.terminal.replay` results gain `size_state` (the wire object above) and
  `self_participant_id`.
- Push event `mobile.terminal.size_state {surface_id, state, self_participant_id}`
  on every published change.
- Push event `mobile.terminal.detached {surface_id, reason, by, at}`; `at` is
  ISO 8601. After it the Mac drops the phone's viewport and input for that surface
  until `mobile.terminal.reattach {surface_id, as_viewer}`, which answers like
  `replay`. `as_viewer: true` sets `counts_override: false`.
- `mobile.terminal.size_policy.set {surface_id, policy}` and
  `mobile.terminal.participant.disconnect {surface_id, participant_id}` let the
  phone use the same size panel.

For a Cloud terminal the Mac forwards the phone to cmux-tui as an attached-view
lease with the same identity, forwards `size-state` as
`mobile.terminal.size_state` (participant ids are the host's ids), and maps a
`detached` for that lease to `mobile.terminal.detached`.

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
