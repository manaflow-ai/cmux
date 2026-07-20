# Event Contract

This file specifies event lines emitted by protocol v9, including compatibility notes for fields and attach behavior introduced in earlier versions. Event lines are JSON objects with an `event` string and no response envelope.

The schema notation and `Id`, `Workspace`, `Screen`, `Pane`, and `Tab` types come from [`commands.md`](commands.md#notation). `Cursor`, `Row`, and `Run` come from [`render.md`](render.md#shared-render-types).

Implemented event lines can appear on two stream types:

| Stream | How to start | Event names |
| --- | --- | --- |
| Subscribe stream | `subscribe` command | `tree-changed`, `layout-changed`, `surface-output`, `scroll-changed`, `surface-resized`, `surface-resize-failed`, `surface-exited`, `title-changed`, `bell`, `notification`, `config-reload-requested`, `window-title-requested`, `client-attached`, `client-changed`, `client-detached`, `empty`, `overflow` |
| Attach stream v5 | `attach-surface` command | `vt-state`, `output`, `detached`, `overflow` |
| Attach stream v6 | `attach-surface` command | `vt-state`, `resized`, `output`, `colors-changed`, `scroll-changed`, `detached`, `overflow` |
| Attach stream v7 render mode | `attach-surface` command | `render-state`, `render-delta`, `scroll-changed`, `detached`, `overflow` |

Events and command responses share one full-duplex connection. Each event or response is a complete transport message: a JSON line on Unix or a text frame on WebSocket. Clients must route messages by checking for `event`. If `event` is absent, the message is a command response and should be matched by `id`.

## Event Scoping

Every entity-scoped event carries its subject id in the field named below. Tree deltas also carry every parent id needed to place the entity. Legacy session-wide events have no numeric entity subject; the table marks them `session` rather than inventing an id and changing their v5/v6 payloads.

Subscribe events belong to the `subscribe` registration. Tree lifecycle deltas belong only to a subscription that selected `tree_events:"deltas"`; `tree-changed` belongs to the default `"coarse"` subscription and may also appear on a delta subscription as a resync fallback. The tree-event selection does not affect other subscribe events. Attach events belong to the attachment selected by `attach-surface`; their `surface` field permits multiple attachments on one connection. The table's canonical protocol-v7 subscribe and attach event-name sets are otherwise disjoint: an attach stream never emits tree/client/global events, and a v7 subscribe stream never emits render, byte, or attach-viewport events. The wire-compatibility exception is `scroll-changed`: protocol v6 already delivers that attach event name to legacy subscribe consumers. That legacy delivery is retained and recorded in the compatibility column; event instances remain ordered within the registration that produced them.

| Event | Stream | Subject field | Since/compatibility |
| --- | --- | --- | --- |
| `workspace-added` | subscribe (`deltas`) | `workspace` | protocol 7 |
| `workspace-closed` | subscribe (`deltas`) | `workspace` | protocol 7 |
| `workspace-renamed` | subscribe (`deltas`) | `workspace` | protocol 7 |
| `workspace-moved` | subscribe (`deltas`) | `workspace` | protocol 7 |
| `screen-added` | subscribe (`deltas`) | `screen` | protocol 7; parent `workspace` |
| `screen-closed` | subscribe (`deltas`) | `screen` | protocol 7; parent `workspace` |
| `screen-renamed` | subscribe (`deltas`) | `screen` | protocol 7; parent `workspace` |
| `pane-added` | subscribe (`deltas`) | `pane` | protocol 7; parents `workspace`, `screen` |
| `pane-closed` | subscribe (`deltas`) | `pane` | protocol 7; parents `workspace`, `screen` |
| `tab-added` | subscribe (`deltas`) | `surface` | protocol 7; parents `workspace`, `screen`, `pane` |
| `tab-closed` | subscribe (`deltas`) | `surface` | protocol 7; parents `workspace`, `screen`, `pane` |
| `tab-renamed` | subscribe (`deltas`) | `surface` | protocol 7; parents `workspace`, `screen`, `pane` |
| `tree-changed` | subscribe (`coarse`; `deltas` fallback) | session | protocol 5; `coarse` is the default and exact v6 behavior |
| `layout-changed` | subscribe | `screen` | protocol 6 |
| `surface-output` | subscribe | `surface` | protocol 5 |
| `surface-resized` | subscribe | `surface` | protocol 5 |
| `surface-exited` | subscribe | `surface` | protocol 5 |
| `title-changed` | subscribe | `surface` | protocol 5 |
| `bell` | subscribe | `surface` | protocol 5 |
| `notification` | subscribe | `notification` | protocol 6; optional related `surface` |
| `config-reload-requested` | subscribe | session | protocol 6 |
| `window-title-requested` | subscribe | session | protocol 6 |
| `client-attached` | subscribe | `client` | protocol 6 |
| `client-changed` | subscribe | `client` | protocol 6 |
| `client-detached` | subscribe | `client` | protocol 6 |
| `empty` | subscribe | session | protocol 5 |
| `agent-state-changed` | subscribe | `surface` | proposed protocol 6 |
| `vt-state` | byte attach | `surface` | protocol 5 |
| `resized` | byte attach | `surface` | protocol 6 |
| `output` | byte attach | `surface` | protocol 5 |
| `colors-changed` | byte attach | `surface` | protocol 6; subject field added in protocol 7 |
| `render-state` | render attach | `surface` | protocol 7 |
| `render-delta` | render attach | `surface` | protocol 7 |
| `scroll-changed` | byte/render attach | `surface` | protocol 6 legacy subscribe delivery retained |
| `detached` | byte/render attach | `surface` | protocol 5 |

## Ordering Guarantees

The server writes each response or event as one complete transport message. JSON lines and WebSocket text frames are not interleaved at the byte level.

For a single subscription, ordinary events are delivered in the order the mux broadcasts them. The server does not create a total order across unrelated producer threads beyond the order in which events enter the mux broadcaster.

Protocol v7 treats `title-changed` as a latest-state notification. A slow subscriber retains at most one pending title per surface. Repeated pending titles for the same surface coalesce to the newest `title` and take the newest event's position relative to ordinary events. Subscribers are independent, and a pending title is discarded when its surface exits.

Each subscription retains at most 4,096 pending events. If a client falls behind that bound, the server drains the accepted backlog, emits `overflow`, and ends that subscription. A subscribe client must open a new subscription and fetch `list-workspaces` to reconcile state. An attach client must reattach the named surface.

`subscribe` registers the event receiver before the command response is written. A client must not treat the `subscribe` response as an event-stream barrier.

`subscribe` does not send an initial tree snapshot. Clients that need the current tree should start `subscribe` and buffer events, call `list-workspaces`, apply that snapshot, then drain the buffer. This avoids a gap between snapshot and registration.

`attach-surface` has a stronger ordering contract. The server takes the VT replay snapshot and registers the live output tap under the same terminal lock. The attach stream therefore has no gap and no duplicated bytes between the `vt-state` replay and subsequent `output` chunks. In v5, the `vt-state` event is sent before the `attach-surface` command response.

Protocol v6 attach streams are ordered as `vt-state -> (resized | output | colors-changed)* -> detached`. The v6 `resized` event carries a fresh replay, and attach clients must replace their mirror terminal from that replay before applying later `output` chunks. `colors-changed` is ordered with `resized` and `output` for its attached surface. Clients that support only protocol 5 or older must refuse protocol v6 attach streams. The v6 `resized` replay is carried in the `data` field (verified against `server.rs`; an earlier draft called it `replay`).

Protocol v7 render attach streams are ordered as `render-state -> (render-delta | scroll-changed)* -> detached`. The initial state snapshot and render tap are registered under one terminal lock, matching the byte stream's no-gap/no-duplication guarantee. `render-delta` frames coalesce damage but preserve authoritative state order. See [`render.md`](render.md#stream-ordering).

When a surface exits, the mux removes it from the tree itself. Before `surface-exited`, a coarse subscription normally receives `tree-changed`, while a delta subscription normally receives the applicable close delta or the `tree-changed` fallback; either mode may also receive `empty`. By the time `surface-exited` is observed, frontends should consider the surface reaped from authoritative tree state.

## Subscribe Events

### overflow

| Field | Value |
| --- | --- |
| event | `overflow` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"overflow",error:string,scope?:"surface",surface?:Id}
```

Meaning: The client stopped draining events before the bounded server backlog filled. Without `scope`, the subscribe stream ended and the client must subscribe again, then fetch `list-workspaces`. With `scope:"surface"`, the attach notification stream ended and the client must reattach `surface`.

Example:

```json
{"event":"overflow","error":"subscriber fell behind; resubscribe to continue receiving events"}
```

### client-attached

| Field | Value |
| --- | --- |
| event | `client-attached` |
| status | implemented |
| since | protocol 6 additive extension |

Payload:

```text
object{event:"client-attached",client:uint64,transport:"unix"|"ws",name:string|null,kind:string|null}
```

Meaning: A control connection attached its first surface. A connection that never calls `attach-surface` does not emit this event, and later surfaces on the same connection do not emit it again. Use `list-clients` for the attached surface set and sizes.

Example:

```json
{"event":"client-attached","client":2,"transport":"ws","name":"lawrences-iphone","kind":"web"}
```

### client-changed

| Field | Value |
| --- | --- |
| event | `client-changed` |
| status | implemented |
| since | protocol 6 additive extension |

Payload:

```text
object{event:"client-changed",client:uint64,name:string|null,kind:string|null}
```

Meaning: The connection called `set-client-info`. The event is emitted for every successful call, including an idempotent call.

Example:

```json
{"event":"client-changed","client":2,"name":"lawrences-iphone","kind":"web"}
```

### client-detached

| Field | Value |
| --- | --- |
| event | `client-detached` |
| status | implemented |
| since | protocol 6 additive extension |

Payload:

```text
object{event:"client-detached",client:uint64}
```

Meaning: A control connection disconnected naturally or was ended by `detach-client`. This is emitted even if the connection never attached a surface.

Example:

```json
{"event":"client-detached","client":2}
```

### Tree delta events

Protocol v7 adds typed lifecycle deltas for ordinary tree mutations, delivered only when the subscription explicitly requests `tree_events:"deltas"`. The default `"coarse"` subscription receives none of these events. `entity` is the exact `Workspace`, `Screen`, `Pane`, or `Tab` payload defined for `list-workspaces` in `commands.md`; it is not a reduced event-only projection. Added and renamed events carry the entity after the mutation. Closed events carry its last-known payload immediately before removal. This lets clients remove a subtree without having to retain a second copy for close animation or cleanup.

For `*-added`, `index` is the zero-based insertion index in the parent's corresponding array. For `*-closed`, it is the former index. `workspace-moved` carries the new zero-based root index. Workspace events use the root `workspaces` array, include the resulting `workspace_revision`, and carry the stable key in `entity`. Tab events use the pane's `tabs` array. Rename events do not carry `index` because they do not reorder the entity.

One settled mutation may affect a subtree. A server may emit only the highest-level delta when its `entity` already contains the complete affected subtree; it must not also emit redundant descendant add/close deltas. If it emits multiple independent deltas, adds are parent-first and closes are child-first.

These lifecycle deltas do not encode every mutable tree field. Selection, reorder, split-layout, zoom, and other multi-entity changes continue to use their existing events or the `tree-changed` fallback. Under churn, or whenever the server cannot represent the authoritative result without ambiguity, the server may emit `tree-changed` to a delta subscriber instead of one or more deltas. Delta clients must implement both paths and treat `tree-changed` as a full-resync barrier, but they MUST NOT rely on it for ordinary delta-representable mutations.

### workspace-added

| Field | Value |
| --- | --- |
| event | `workspace-added` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"workspace-added",workspace:Id,index:usize,workspace_revision:uint64,entity:Workspace}
```

### workspace-closed

| Field | Value |
| --- | --- |
| event | `workspace-closed` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"workspace-closed",workspace:Id,index:usize,workspace_revision:uint64,entity:Workspace}
```

### workspace-renamed

| Field | Value |
| --- | --- |
| event | `workspace-renamed` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"workspace-renamed",workspace:Id,workspace_revision:uint64,entity:Workspace}
```

### workspace-moved

| Field | Value |
| --- | --- |
| event | `workspace-moved` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"workspace-moved",workspace:Id,index:usize,workspace_revision:uint64,entity:Workspace}
```

### screen-added

| Field | Value |
| --- | --- |
| event | `screen-added` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"screen-added",workspace:Id,screen:Id,index:usize,entity:Screen}
```

### screen-closed

| Field | Value |
| --- | --- |
| event | `screen-closed` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"screen-closed",workspace:Id,screen:Id,index:usize,entity:Screen}
```

### screen-renamed

| Field | Value |
| --- | --- |
| event | `screen-renamed` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"screen-renamed",workspace:Id,screen:Id,entity:Screen}
```

### pane-added

| Field | Value |
| --- | --- |
| event | `pane-added` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"pane-added",workspace:Id,screen:Id,pane:Id,index:usize,entity:Pane}
```

### pane-closed

| Field | Value |
| --- | --- |
| event | `pane-closed` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"pane-closed",workspace:Id,screen:Id,pane:Id,index:usize,entity:Pane}
```

### tab-added

| Field | Value |
| --- | --- |
| event | `tab-added` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"tab-added",workspace:Id,screen:Id,pane:Id,surface:Id,index:usize,entity:Tab}
```

The tab's subject id is its `surface`, matching `Tab.surface`; the protocol has no separate tab id.

### tab-closed

| Field | Value |
| --- | --- |
| event | `tab-closed` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"tab-closed",workspace:Id,screen:Id,pane:Id,surface:Id,index:usize,entity:Tab}
```

### tab-renamed

| Field | Value |
| --- | --- |
| event | `tab-renamed` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{event:"tab-renamed",workspace:Id,screen:Id,pane:Id,surface:Id,entity:Tab}
```

`tab-renamed` reports a user-visible tab-name mutation such as `rename-surface`. Application title changes remain `title-changed`.

### tree-changed

| Field | Value |
| --- | --- |
| event | `tree-changed` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"tree-changed"}
```

Meaning: The workspace, screen, pane, tab, active selection, names, split layout, or surface set changed. The event does not include the new tree. Clients should call `list-workspaces`.

Protocol v7 retains this event in two negotiated roles. A `tree_events:"coarse"` subscription receives the exact protocol-v6 behavior: `tree-changed` is emitted wherever v6 emits it, and no lifecycle deltas are emitted. A `tree_events:"deltas"` subscription receives it only as an authoritative resync fallback under churn, for a mutation not represented by the delta set, or when coalescing makes an exact delta ambiguous. A delta client MUST NOT rely on `tree-changed` for ordinary mutations, but it must handle the fallback by re-fetching the tree and may discard buffered deltas older than the replacement snapshot. The server may emit it after earlier deltas when a later mutation invalidates them.

Example:

```json
{"event":"tree-changed"}
```

### layout-changed

| Field | Value |
| --- | --- |
| event | `layout-changed` |
| status | implemented |
| since | protocol 6 |

Payload:

```text
object{event:"layout-changed",screen:Id}
```

Meaning: A screen's pane geometry changed through split, close/collapse, ratio update, apply-layout, swap, or zoom. The event is emitted once per settled command and does not include the new layout. Clients should re-fetch `export-layout` or `list-workspaces`.

Example:

```json
{"event":"layout-changed","screen":3}
```

### surface-output

| Field | Value |
| --- | --- |
| event | `surface-output` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"surface-output",surface:Id}
```

Meaning: A surface has new output or was marked dirty. For PTY surfaces, this is coalesced by the surface dirty flag and is not a byte stream. For browser surfaces, this can indicate a new frame or dirty state. Use `attach-surface` for byte-exact PTY streaming.

Example:

```json
{"event":"surface-output","surface":1}
```

### scroll-changed

| Field | Value |
| --- | --- |
| event | `scroll-changed` |
| status | implemented |
| since | protocol 6 |

Payload:

```text
object{event:"scroll-changed",surface:Id,offset:uint64,at_bottom:boolean}
```

Meaning: A PTY surface viewport moved within its scrollback. The event is emitted after a settled viewport mutation from user scrolling, `scroll-surface`, input snapping the viewport to the live bottom, or PTY output that changes the viewport position. `offset` is the same row offset used by the scrollbar geometry, and `at_bottom` is true when the viewport is pinned to the live bottom.

Protocol v6 subscribe streams receive all scroll changes, and byte attach streams receive changes for the attached surface only. Both v7 tree-event modes retain that subscribe delivery, and render attach streams also receive changes for their attached surface. This pre-v7 overlap is retained for v6 compatibility and is the exception described in [Event Scoping](#event-scoping).

Example:

```json
{"event":"scroll-changed","surface":1,"offset":12,"at_bottom":false}
```

### surface-resized

| Field | Value |
| --- | --- |
| event | `surface-resized` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"surface-resized",surface:Id,cols:uint16,rows:uint16,reservation_id:uint64|null}
```

Meaning: A surface's final clamped cell size changed. `reservation_id` identifies the accepted asynchronous browser resize that completed, and is `null` for PTY resizes. A same-size `resize-surface` command returns success but emits no `surface-resized` event.

Example:

```json
{"event":"surface-resized","surface":1,"cols":120,"rows":40,"reservation_id":7}
```

### surface-resize-failed

| Field | Value |
| --- | --- |
| event | `surface-resize-failed` |
| status | implemented |
| since | protocol 7 |

Payload:

```text
object{event:"surface-resize-failed",surface:Id,cols:uint16,rows:uint16,error:string,retry_after_ms:uint64|null,reservation_id:uint64}
```

Meaning: An accepted asynchronous browser resize failed. `reservation_id` matches the accepted request. A numeric `retry_after_ms` is the delay before the requesting client retries the same geometry. `null` means automatic retries are exhausted; a new geometry request or browser reconnection may retry it. The event is broadcast, so subscribers that did not request this geometry must not echo it.

Example:

```json
{"event":"surface-resize-failed","surface":1,"cols":120,"rows":40,"error":"browser is not responding","retry_after_ms":250,"reservation_id":7}
```

### surface-exited

| Field | Value |
| --- | --- |
| event | `surface-exited` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"surface-exited",surface:Id}
```

Meaning: A PTY child exited or a browser surface was closed. The mux has already reaped the surface from the tree by the time this event is observed.

Example:

```json
{"event":"surface-exited","surface":1}
```

### title-changed

| Field | Value |
| --- | --- |
| event | `title-changed` |
| status | implemented |
| since | protocol 5 |
| `title` field | protocol 7 |

Payload:

```text
object{event:"title-changed",surface:Id,title:string}
```

Meaning: A surface title changed. Protocol v7 includes the authoritative current title, so clients can update that surface directly without fetching the workspace tree. Protocol v5-v6 events omit `title`; clients connected to those versions must call `list-workspaces`.

Example:

```json
{"event":"title-changed","surface":1,"title":"build logs"}
```

### bell

| Field | Value |
| --- | --- |
| event | `bell` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"bell",surface:Id}
```

Meaning: A PTY surface emitted a terminal bell.

Example:

```json
{"event":"bell","surface":1}
```

### notification

| Field | Value |
| --- | --- |
| event | `notification` |
| status | implemented |
| since | protocol 6 |

Payload:

```text
object{event:"notification",notification:Id,title:string,body:string,level:"info"|"warning"|"error",surface:Id|null}
```

Meaning: A notification was posted. If `surface` is present, clients should mark that surface as unread/attention until the user views it.

Example:

```json
{"event":"notification","notification":44,"title":"Build failed","body":"api tests failed","level":"error","surface":1}
```

### config-reload-requested

| Field | Value |
| --- | --- |
| event | `config-reload-requested` |
| status | implemented |
| since | protocol 6 |

Payload:

```text
object{event:"config-reload-requested"}
```

Meaning: Emitted by `reload-config` so attached TUI frontends can re-read local mux config and redraw.

Example:

```json
{"event":"config-reload-requested"}
```

### window-title-requested

| Field | Value |
| --- | --- |
| event | `window-title-requested` |
| status | implemented |
| since | protocol 6 |

Payload:

```text
object{event:"window-title-requested",title:string}
```

Meaning: Emitted by `set-window-title` and `clear-window-title` so attached TUI frontends can write OSC 0/2 to their controlling stdout. Empty `title` clears the title.

Example:

```json
{"event":"window-title-requested","title":"hello"}
```

### empty

| Field | Value |
| --- | --- |
| event | `empty` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"empty"}
```

Meaning: Every workspace is gone. Remote clients also synthesize this event locally when the socket connection is lost.

Example:

```json
{"event":"empty"}
```

## Attach Events

### render-state

| Field | Value |
| --- | --- |
| event | `render-state` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{
  event:"render-state",
  surface:Id,
  size:object{cols:uint16,rows:uint16},
  cursor:Cursor,
  default_fg:ColorHex,
  default_bg:ColorHex,
  scrollback_rows:uint32,
  rows:array<Row>
}
```

Meaning: Initial authoritative viewport state for `attach-surface` with `mode:"render"`. `Cursor`, `Row`, `Run`, color resolution, and the complete-snapshot invariant are defined in [`render.md`](render.md#render-state).

### render-delta

| Field | Value |
| --- | --- |
| event | `render-delta` |
| status | proposed |
| since | protocol 7 |

Payload:

```text
object{
  event:"render-delta",
  surface:Id,
  cursor:Cursor,
  full:boolean,
  size?:object{cols:uint16,rows:uint16},
  default_fg?:ColorHex,
  default_bg?:ColorHex,
  scrollback_rows?:uint32,
  rows:array<Row>
}
```

Meaning: One coalesced render frame. The cursor is always present; `rows` contains dirty replacements unless `full:true`. `size` is present if and only if the surface resized, and every resize is a full viewport replacement. See [`render.md`](render.md#render-delta).

### vt-state

| Field | Value |
| --- | --- |
| event | `vt-state` |
| status | implemented |
| since | protocol 5 |
| `colors` field | protocol 6 additive extension |

Payload:

```text
object{
  event:"vt-state",
  surface:Id,
  cols:uint16,
  rows:uint16,
  data:Base64,
  colors:object{
    fg:ColorHex|null,
    bg:ColorHex|null,
    cursor:ColorHex|null,
    selection_bg:ColorHex|null,
    selection_fg:ColorHex|null,
    palette?:object{[index:string]:ColorHex},
    cursor_style:"block"|"underline"|"bar"|null,
    cursor_blink:boolean|null
  }
}
```

Meaning: Initial VT replay for an attached PTY surface. Replaying `data` into a fresh Ghostty VT terminal with the supplied cell size reproduces current state. `colors` is captured with the replay and reports the surface's effective foreground, background, and cursor colors, including active OSC 10/11/12 overrides. Protocol v7 adds sparse `palette`, whose decimal string keys identify authored OSC 4 overrides; omitted indexes retain the frontend theme palette, and older servers omit the field. The additive protocol-v6 `cursor_style` and `cursor_blink` fields report the surface's current DECSCUSR-derived cursor state when available, then fall back to the session's Ghostty `cursor-style` and `cursor-style-blink` defaults. A field is `null` when the server cannot determine it; the current server does not track selection colors, so `selection_bg` and `selection_fg` are `null`. Ghostty's VT replay formatter does not emit DECSCUSR, so attach clients must apply the cursor metadata instead of inferring shape or blink from `data`.

Example:

```json
{"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"G1s/bA==","colors":{"fg":"#d8d9da","bg":"#131415","cursor":null,"selection_bg":null,"selection_fg":null,"cursor_style":"bar","cursor_blink":false}}
```

### output

| Field | Value |
| --- | --- |
| event | `output` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"output",surface:Id,data:Base64}
```

Meaning: Live PTY bytes applied after the `vt-state` snapshot. Chunks preserve byte order for the attached surface. Chunk boundaries are implementation details.

Example:

```json
{"event":"output","surface":1,"data":"bHMNCg=="}
```

### resized

| Field | Value |
| --- | --- |
| event | `resized` |
| status | implemented in protocol 6 attach stream |
| since | protocol 6 |

Payload:

```text
object{event:"resized",surface:Id,cols:uint16,rows:uint16,replay?:Base64,data?:Base64,colors?:TerminalColors}
```

Meaning: Protocol v6 attach-only event indicating that the authoritative surface size changed and the existing mirror must be replaced from the supplied replay. Protocol v7 sends the replay in `replay` and adds the fresh `colors` snapshot, including sparse palette overrides; protocol-v6 compatibility payloads use `data` and omit `colors`. Clients must accept either replay field, create a fresh terminal mirror at `cols` by `rows`, apply the replay, restore the supplied colors when present, then continue applying later `output` chunks.

Example:

```json
{"event":"resized","surface":1,"cols":100,"rows":30,"replay":"G1s/bA==","colors":{"fg":"#d8d9da","bg":"#131415","cursor":null,"selection_bg":null,"selection_fg":null,"palette":{"4":"#445566"},"cursor_style":"bar","cursor_blink":false}}
```

### colors-changed

| Field | Value |
| --- | --- |
| event | `colors-changed` |
| status | implemented in protocol 6 attach stream |
| since | protocol 6 additive extension |
| `surface` field | protocol 7 additive extension |

Payload:

```text
object{
  event:"colors-changed",
  surface?:Id,
  fg:ColorHex|null,
  bg:ColorHex|null,
  cursor:ColorHex|null,
  selection_bg:ColorHex|null,
  selection_fg:ColorHex|null,
  palette?:object{[index:string]:ColorHex},
  cursor_style:"block"|"underline"|"bar"|null,
  cursor_blink:boolean|null
}
```

Meaning: The session defaults or a surface's live OSC palette state changed. Each live PTY byte-attach stream receives the effective colors for its surface. Active per-surface OSC 10/11/12 overrides remain authoritative; protocol-v7 sparse `palette` entries replace authored OSC 4 indexes while omitted indexes retain the frontend theme palette. Live palette events omit cursor metadata so the frontend preserves its current cursor; default-color events include authoritative cursor state. Protocol v7 requires the explicit `surface` subject id so multiple attach streams on one connection can be routed without implicit stream state. Protocol-v6 payloads omit `surface` and `palette`; v6 clients remain compatible because the new fields are additive. The current server emits `null` for both selection fields because it cannot query the terminal's OSC 17/19 selection-color state.

Example:

```json
{"event":"colors-changed","surface":1,"fg":"#d8d9da","bg":"#131415","cursor":null,"selection_bg":null,"selection_fg":null,"cursor_style":"bar","cursor_blink":false}
```

### detached

| Field | Value |
| --- | --- |
| event | `detached` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"detached",surface:Id}
```

Meaning: The attach stream ended because the surface disappeared or its output tap stopped.

Example:

```json
{"event":"detached","surface":1}
```

## Proposed Events

### agent-state-changed

| Field | Value |
| --- | --- |
| event | `agent-state-changed` |
| status | proposed |
| since | proposed protocol 10 |

Payload:

```text
object{
  event:"agent-state-changed",
  surface:Id,
  previous:"working"|"blocked"|"idle"|"done"|"unknown"|null,
  state:"working"|"blocked"|"idle"|"done"|"unknown",
  source:"detected"|"socket"|"hook",
  session:string|null,
  updated_at_ms:uint64
}
```

Meaning: The authoritative agent state for a surface changed. Hook-authority and socket reports override detection as described in `commands.md`.

Example:

```json
{"event":"agent-state-changed","surface":1,"previous":"working","state":"blocked","source":"hook","session":"abc","updated_at_ms":1710000000000}
```

### notification

| Field | Value |
| --- | --- |
| event | `notification` |
| status | proposed |
| since | proposed protocol 10 |

Payload:

```text
object{
  event:"notification",
  notification:Id,
  title:string,
  body:string,
  level:"info"|"warning"|"error",
  surface:Id|null,
  created_at_ms:uint64
}
```

Meaning: A notification was posted by `notify`, a hook, or an internal mux action.

Example:

```json
{"event":"notification","notification":44,"title":"Build failed","body":"api tests failed","level":"error","surface":1,"created_at_ms":1710000000000}
```

## Proposed Subscribe Filters

Proposed protocol v10 extends `subscribe` with optional filters:

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `events` | `array<string>` | default all | Event names to include |
| `surfaces` | `array<IdRef>` | default all | Surface-scoped events to include |

Request:

```json
{"id":1,"cmd":"subscribe","events":["bell","agent-state-changed"],"surfaces":[1,"a8f3k2"]}
```

Filtering applies only to events produced after the subscription is registered. Non-surface events are included only when their event name matches `events` or when `events` is absent.
