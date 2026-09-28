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
- otherwise a phone or tablet does not count while a `mac` or `tui` participant of
  the same `user_id` is attached. Every other participant counts.

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

- a 1.5 pt border around the grid in the owner's color;
- a hatch outside the grid, so empty space never reads as blank output;
- a corner chip `118 × 38 · Maya's Mac Studio` that opens the size panel;
- when the viewer is smaller, an amber fade on the cut edge and a `+N cols` pill;
- on each change, a border flash and a size HUD (driven by an injected clock).

The tab shows attached people, a ring on the owner, the grid size, and a
dashed-box glyph when this viewer does not match. The size panel has the mode
control, a size map, one row per participant (counts switch, priority order,
disconnect), and "Disconnect other clients".
