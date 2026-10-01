# Shared terminal sizing

A terminal has one PTY grid. Several people and devices can view it: Macs, iPhones,
iPads, the cmux-tui frontend. This document is the contract for who sets that grid,
how every viewer shows the bounds, and how a viewer is disconnected. It applies the
same way to local Mac terminals and to Cloud VM terminals.

## Owners

The process that owns the PTY decides the size. It is the **host**.

| Terminal | Host | Relays | Views |
| --- | --- | --- | --- |
| Local Mac terminal | cmux macOS app (`TerminalController`) | none | the host Mac's own pane, paired iPhones/iPads, other Macs viewing it through Devices |
| Cloud VM terminal | cmux-tui daemon on the VM | each Mac mirror (`CloudTuiManualMirrorSession`) | each Mac's own pane, iPhones/iPads behind a Mac, TUI clients |

Three roles are separate. The **host** owns the PTY and decides. A **relay**
is a connection that carries other views (a Cloud Mac carries the phones
paired to it). A **view** is one pane that shows the terminal; every view is
one participant. A Cloud Mac is both a relay and a view, and the two have
separate lifetimes: detaching the Mac's view never drops the relay or the
phones it carries.

A relay never decides. It forwards each leaf behind it to the host as its own
participant (for cmux-tui, one attached-view lease per leaf) and forwards the
host's size state and detach events back down unchanged.

Several Macs can view one Cloud terminal at once, each with its own window
size and each as its own direct client of the daemon, whether they belong to
one user or to several. Each Mac pins its pane to the host grid exactly, so a
Mac larger than the grid shows the hatch around it and a Mac smaller than the
grid shows the cut edge; both chips name the owning device by its device name
(`200×60 · Lawrence's Mac Studio`). Phones behind a Mac appear once, as that
Mac's sub-views with `via` naming it.

A Mac can also view another Mac's local terminal through Devices
(`DeviceTerminalMirrorSession`, over the same mobile RPC a phone uses). It
joins the host Mac's sizing exactly like a phone: participant
`mobile:<client_id>`, `device_kind: mac`, its own device name and id, the
same counts rules, bounds, chip, Disconnect and Reattach. Under Fit everyone
a smaller viewing Mac therefore shrinks the grid, as a phone does.

Both hosts run the same reducer:

- Swift: `Packages/Shared/CmuxTerminalSizing` (`TerminalSizingEngine`).
- Rust: `cmux-tui/crates/cmux-tui-core/src/sizing_policy.rs`.

`schemas/terminal-sizing/fixtures.json` is the conformance corpus. Both test suites
replay every case. A behavior change starts with a new fixture.

## Participants

A participant is one attached view: `id` (host-scoped, unique while attached),
`user_id` (verified Stack user id, set by the host or relay, never by the leaf),
`display_name`, `device_kind` (`mac`, `iphone`, `ipad`, `tui`, `browser`,
`unknown`), `device_name`, `device_id`, `via` (relay participant id, if any),
`viewport` (`cols`, `rows`, absent until reported) and `counts_override`
(`true`, `false` or absent).

`device_id` is a stable per-install id that tells two devices of one user
apart. A Mac sends a one-way digest of its host device id (so the size state
never carries its pairing identity; every view from one Mac shares it), an
iPhone or iPad its vendor identifier, and a cmux-tui client its host name.
Older clients send none.

A participant **counts toward size** when it is attached, has a viewport, and:

- `counts_override` is set: use it (tmux `attach -f ignore-size` is `false`).
- otherwise, in `smallest` and `largest`, every attached participant counts.
- otherwise, in `latest`, `priority` and `fixed`, a phone or tablet does not count
  while a `mac` or `tui` participant of the same `user_id` is attached and
  itself counts (it has a viewport and is not viewer-only). With two Macs of
  one user, the phone defers while either counts. Every other participant
  counts.

The priority key is `<user_id or "anon:" + id>/<device_kind>/<device_id>`, or
`<user_id or "anon:" + id>/<device_kind>` for a device without an id, so a
priority list survives reconnects and can rank "Maya's Mac Studio" above
"Maya's MacBook Pro" above "Maya's iPhone". A policy entry in the older
two-segment form still matches every device of that kind for that user
(newest activity among them wins), so stored policies keep working. There is
no stored-policy rewrite: the next edit in a size panel, which writes the
keys of the listed participants, replaces legacy entries with per-device
keys.

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
   "device_kind":"mac","device_name":"Mac Studio","device_id":"9f2c41d07a3e5b18",
   "via":null,"viewport":{"cols":118,"rows":38},"counts_override":null,
   "counts":true,"priority_key":"u_maya/mac/9f2c41d07a3e5b18"}]}
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
| Disconnect one | `detach-client {client, surface?, by}` / `detach-attached-view {surface, lease, by}` | `terminal.participant.disconnect` |
| Reattach own view | `reattach-view {surface, counts?}` | `mobile.terminal.reattach`; the Mac pane's Reattach |
| Disconnect others | `detach-client` for each | `terminal.participants.disconnect_others` |
| Reattach | normal attach | `mobile.terminal.reattach` |

## Detach

Disconnecting is tmux `detach-client` for one view: the view stops counting,
stops sending input and shows the Detached card; the terminal keeps running
and every other viewer keeps its session, including the device that asked.

Who may disconnect whom: any participant of the terminal may disconnect any
other participant. Every path that can ask is already limited to the
terminal's signed-in account or workspace members (the Mac mobile RPC accepts
only same-account connections; the cmux-tui daemon accepts only authorized
clients). A Mac's own UI never disconnects its own view; another participant
may:

- Local terminal: a phone or viewing Mac may disconnect the host Mac's pane
  view (`mac:<surface>`). The PTY stays on the host; the pane leaves the
  engine, keeps its latest grid for the reattach, shows the Detached card and
  drops keyboard and text input until Reattach (or Reattach as viewer, which
  sets `counts_override: false`).
- Cloud terminal: a phone may disconnect the Mac that relays it. The Mac
  forwards `detach-client {client: <its own participant>, surface}`; the
  daemon detaches only that Mac's view (below) and never the relay, so the
  phone keeps its session through the same connection. Against a daemon
  without `sizing-view-detach-v1` the Mac refuses the request rather than
  drop the relay.
- "Disconnect Others" disconnects every other view, Macs included.

A detached leaf receives `detached {surface, reason, by?}`. `reason` is
`network`, `disconnected-by`, `host-shutdown` or `superseded`. `by` carries the
actor's `user_id`, `display_name` and `device_name`.

- `network`: reconnect automatically, keep the priority slot.
- `disconnected-by`: never reconnect automatically. iOS shows "Detached from
  <tab>", who and when, with **Reattach** and **Reattach as viewer**. A Mac mirror
  shows the same state in the pane.
- A relay that receives `disconnected-by` for one of its leaves forwards it to that
  leaf only and keeps its own attachment.
- A view-only detach of a relay's own view (`detached` with `scope: "view"`)
  concerns that view alone: the relay keeps its connection and every sub-view,
  shows the Detached card on its own pane, stops sending its own activity and
  input, and reattaches with `reattach-view` without reconnecting.
- A relay that is itself detached (no `scope`) for any reason but `network`
  forwards the same `reason`, `by` and `at` to every leaf behind it, since they
  lost their path to the terminal, and drops their sub-views. After the relay
  reattaches, each leaf reattaches normally.

The Mac socket `terminal.size_state` (and `cmux surface size`) adds
`detachment {reason, by, at}` while this Mac view is detached, else `null`; the
grid it reports is then the last state seen before the detach.

Disconnecting is not unpairing. Pairing revoke stays in pairing settings.

## Showing the bounds

Every viewer whose viewport differs from the grid draws, from the size state
(a viewer whose viewport equals the grid draws none of it, even while others
are attached):

- a 1 pt border in the split divider color (colors below) on each side of
  the grid that faces unused space. A side flush with the viewport edge gets
  no line, because the tab bar, navigation bar or pane edge already draws one
  there;
- a faint hatch outside the grid: thin diagonal lines in the divider color at
  60%, with no fill, so the terminal background shows through and empty
  space never reads as blank output;
- one small chip outside the grid's bottom-right corner,
  `118×38 · Maya's Mac` (plus `· 12 cols hidden` when the viewer is smaller),
  that opens the size panel. It never covers the grid's last row: on the
  iPhone it goes in the letterbox below, beside or above the grid, and when
  the grid fills the viewport it shrinks to `118×38` at the viewport's
  top-trailing corner;
- when the viewer is smaller, a short fade on the cut edge;
- on the iPhone, a grid at least one row shorter than the viewport pins to the
  top, with the unused space below it. With the keyboard up the grid stays put
  while its content fits above the keyboard, and otherwise slides up only far
  enough to keep the cursor row visible. The chrome draws only above the
  keyboard. Keyboard toggles never change the phone's reported viewport in a
  shared-sizing session, on the alternate screen too, so they never resize
  other devices' grids;
- on each change, the border animates to the new grid. There is no HUD.

The sizing UI is neutral, with no per-participant colors; the owner is marked
by a thin ring on its avatar.

Lines on the terminal (the grid border, the hatch and the chip outline) use
the gray of the split dividers, so the bounds read as one more pane edge. On
the Mac that is the workspace's split divider color
(`BonsplitConfiguration.Appearance.splitDividerColor`: a configured pane
border color, else Ghostty's `split-divider-color`, else the chrome separator); on iOS it is
`UIColor.separator` resolved in the appearance the terminal chrome uses for
the theme (dark when white text reads better on the background). A
translucent divider color composites over the terminal background, the
backdrop the divider itself draws on. The hatch is that color at 60% over the
background (`BonsplitSizingChromePalette` on the Mac,
`TerminalSizingChromePalette` in `CmuxMobileTerminalKit` on iOS). The chip is
filled with the terminal background and outlined in the divider color.

Only text keeps a contrast floor. Text and glyph colors derive from the
surface they sit on by one pure function per platform
(`BonsplitContrastPalette` in bonsplit on the Mac, `TerminalSizingPalette` on
iOS): the surface's text color is mixed into its background in gamma-encoded
sRGB (72% for glyphs and text, 14% for avatar fills), then moved toward black
or white until WCAG 2 contrast holds. Chip text reaches 4.5:1 on the terminal
background; avatar initials and glyphs reach 4.5:1 on their fill, and the
owner ring 3:1. Fills are opaque, never alpha over an unknown background.

| Surface | Background / foreground |
| --- | --- |
| Mac tab accessory | the tab's fill (selected) or the tab bar, and the tab bar text color |
| Mac pane border, hatch, cut fade, chip | the terminal theme background and foreground; lines in the split divider color |
| Mac size panel avatars | the popover's window background and label color |
| iPhone border, hatch, cut fade, chip | the surface's terminal theme background and foreground; lines in `UIColor.separator` |
| iPhone size sheet avatars | the inset-grouped row background and label color |

System colors resolve in the appearance that draws them, so a light terminal
theme under dark macOS still gets dark glyphs. A cut edge fades the text into
the terminal background.

On the Mac, the tab shows only while someone else is attached, and never
shows this view itself. It draws one neutral initials circle per other person
(grouped by `user_id`) and, for this user's own other devices, one neutral device
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
The iPhone size sheet uses the same neutral avatars and marks rows "Sets size"
or "Not counted" the same way. It opens from the chip and from **Connected
Devices…** in the terminal title menu (the title button beside the back
button), whose subtitle counts the other attached devices ("2 others", or
"Only this device"). The menu item shows whenever the terminal's Mac has
published a size state, including while this phone's viewport matches the
grid and the chip is hidden. Both entrypoints call the same action.

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

- `mobile.terminal.viewport` gains `device_kind`, `device_name`, `device_id`
  and `counts_override` (`null` clears it). A viewing Mac sends
  `device_kind: mac`. The Mac sets `user_id` from the
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
  phone use the same size panel. `participant_id` may name the host Mac's own
  pane (`mac:<surface>`) on a local terminal, or the relaying Mac's host id on
  a Cloud terminal; the phone confirms first, naming that Mac.

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
  `device_name`, `device_id`. Relay identities take the same fields.
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
- `detach-client {client, surface?, by}` takes a numeric client id or a
  participant id; `surface` resolves the participant on that terminal (ids are
  per terminal). `detached` gains `reason`, `by` and, for a relay sub-view,
  `view`; the relay keeps its own attachment and forwards the event to that
  leaf.
- `sizing-view-detach-v1`: the daemon advertises it; a client that lists it
  in `set-client-info` survives losing its own view. `detach-client` naming
  that client's own view participant detaches the view only: the view leaves
  the engine, its reports and activity are ignored, and the client receives
  `detached {surface, reason, by, scope: "view"}` while its connection, byte
  stream and relay sub-views stay. `reattach-view {surface, counts?}` restores
  the view with its latest report (`counts: false` reattaches as a viewer).
  A numeric client id, or a client without the capability, is still kicked
  whole.
