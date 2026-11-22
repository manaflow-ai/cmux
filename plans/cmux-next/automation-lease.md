# cmux next: the automation lease (browser use and computer use)

Contract, 2026-10-04. Owner: the agent automation lead (computer use, shared human/agent UX). Applies to two hosts: the browser host (`cmux-tui/crates/cmux-browser-host`, targets are tabs, owner browser lead) and the CUA host (`manaflow-ai/cmux-cua`, `cmux-cua-core`, targets are windows and apps). Inputs: browser-host.md section 1 provider frames (`lease`, `user.input`) and section 3 (lease ownership), computer-use.md (C1 user stop wins, decision 9), coordinator decisions of 2026-10-04 (the host owns the lease state machine; the UX only renders it; any user input in the leased target pauses).

Test vectors: `schemas/automation-lease/vectors.json`. Both hosts replay every case from an empty host and must match the result, the lease snapshot and the lease frames after every step. The CUA host keeps a vendored copy with the source commit recorded; a change to this contract changes the vectors and both implementations together.

## Model

One lease per target. A target is a browser tab (`targetId`) or a desktop window or app (`{pid, window_id}` rendered as a string key by the CUA host).

```
lease { session, actor, on_behalf_of?, origin, label, since_ms, state: driving | paused | user_driving }
```

`session`, `actor`, `on_behalf_of` and `origin` are stamped from the connection, never taken from the caller. `label` is the agent's free-form task label (the badge text). `since_ms` is the time the lease started; pause and hand back do not change it. The host also keeps `needs_fresh_observe` (not rendered).

A host also keeps a set of names the user stopped. `stop` adds the lease's principal: its `on_behalf_of` when present, else its `actor`. `acquire` and `act` refuse a caller with `stopped_by_user` when EITHER its `actor` OR its `on_behalf_of` is in the set, under any session name. "Stop" means that agent stops, whoever it claims to act for, and every agent acting for a stopped principal stops too (decisions of the browser lease review, 2026-10-04: a new session name cannot dodge a stop; hq-07's stricter actor-or-principal rule). `allow {actor}` removes exactly that name from the set; a caller is accepted again only when neither of its names remains stopped.

Provider engines (`cef`, `webkit`: the person's own tabs) refuse the implicit shared session: when the caller did not name a session (the host substituted its default), `acquire` and `act` on such a target fail with `session_required`. Headless Chromium and desktop targets still accept the implicit session.

## Operations

Agent operations (origin is not `user`; a `user` origin gets `agent_origin_required`):

| Op | Effect |
| --- | --- |
| `acquire {target, engine?, implicit_session?}` | implicit session on a `cef`/`webkit` target: `session_required`. Caller `actor` or `on_behalf_of` in the stopped set: `stopped_by_user`. No lease: create it in `driving`. Same session: no change. Another session: `lease_held`. |
| `act {target}` (any input: click, type, key, scroll, drag, set value, navigate) | as `acquire` when there is no lease. Holder in `paused`: `paused_by_user`; in `user_driving`: `user_driving`; with `needs_fresh_observe`: `stale_after_hand_back`. |
| `observe {target}` (snapshot, screenshot, read) | never blocked, never takes a lease. The holder's observe in `driving` clears `needs_fresh_observe`. |
| `release {target}` | holder: remove the lease. No lease: no change. Another session: `not_lease_holder`. |
| `session_end {session}` | remove every lease of the session (also on host restart and idle TTL). |

Signals and user operations (`user` origin only; any other origin gets `user_origin_required`, checked first):

| Op | Effect |
| --- | --- |
| `user_input {target}` (a signal from the app or the helper: a person pressed a key, clicked or scrolled in the target) | `driving` becomes `paused`. Other states and no lease: no change. |
| `take_over {target}` | `driving` or `paused` becomes `user_driving`. No lease: `no_lease`. |
| `hand_back {target}` | `paused` or `user_driving` becomes `driving` and sets `needs_fresh_observe`. `driving`: `not_paused`. No lease: `no_lease`. |
| `stop {target}` | remove the lease and add its stop key (`on_behalf_of`, else `actor`) to the stopped set (C1, user stop wins). No lease: `no_lease`. |
| `allow {actor}` | remove that name from the stopped set. The person can always do this (badge, palette, CLI, op); hosts write an audit event for every stop and allow. |

Routed responses (browser host, item 4c, 2026-10-06): `tab.handleEvents {target, events}`, `dialog.respond {target, dialogId}` and `filechooser.respond {target, chooserId}` are neither `act` nor `observe`. They never take, block or refresh a lease, and they do not clear `needs_fresh_observe`, so the session that only listens for a tab's dialogs can register and answer while another session holds the tab's lease, and while the lease is `paused` or `user_driving`. In place of the lease, the routing rule (driver-protocol.md, "Sessions and tabs") limits them: a dialog, chooser or download goes to ONE session, and only that ROUTED session may answer it; `dialog.respond` and `filechooser.respond` from any other session fail with `not_found` (the same error as an unknown id, so a session cannot probe another's dialogs), and the dialog or chooser stays open. A stopped principal is still refused at its next `acquire` or `act`, but today it can still answer a dialog or chooser routed to it (the stop check is in the lease table, which these ops skip); open question to the owner whether a stop must also refuse routed responses. These ops are not lease table operations, so `schemas/automation-lease/vectors.json` has no cases for them; the browser host's routing tests (`headless_routes.rs`, `tests/chromium.rs` `shared_browser_events_reach_one_session`) cover them. Implemented in the session engine (`provider_engine.rs`, the `registration` set) for every tab source; the headless source enforces the routed-session rule for `dialog.respond` today and for `filechooser.respond` when headless file choosers land (parity 10/11).

`user_input` is a signal from the user's own client, so it carries no user origin check of its own; hosts accept it only on the authenticated provider or user connection.

## Frames

After every operation, the host sends one `lease {target, lease?}` frame for each target whose rendered lease changed (any field of the lease above, `state` included). `lease: null` clears the badge. No change, no frame. The app never shows a lease it did not receive.

Browser host: the existing provider frame `lease {targetId, lease?}`; the `Lease` struct gains `state`. CUA host: the same JSON shape on its socket stream to the app (`{"type": "lease", "target": ..., "lease": ...}`).

## Rendering (shared UX, Swift)

The app has one lease view model fed by two sources (the browser host provider link and the CUA host socket). Every target with a lease shows:

- Badge: agent brand mark, label, state (`driving` = "Agent is driving", `paused` = "Paused: you used this tab/window", `user_driving` = "You are driving"), in the session color (the same color function as the cmux-cua cursor).
- Actions: Stop (always), Pause is implicit (user input), Take over (when `driving` or `paused`), Hand back (when `paused` or `user_driving`). All four are user-origin ops through one shared action path (badge button, palette, menu, CLI, MCP `expose: never`).
- Agent cursor: drawn in the session color at the last act point. Browser panes draw it as a layer inside the pane; desktop windows use the cmux-cua cursor overlay.
- Titlebar indicator: count of live leases on this Mac; click opens Agent Activity.

## Error codes

`lease_held`, `paused_by_user`, `user_driving`, `stale_after_hand_back`, `stopped_by_user`, `session_required`, `not_lease_holder`, `no_lease`, `not_paused`, `user_origin_required`, `agent_origin_required`. Agents receive the code and a short reason; `paused_by_user` and `user_driving` tell the agent to wait for hand back, not to retry.
