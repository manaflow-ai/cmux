# Event Contract

This file specifies event lines emitted by protocol v5 and proposed protocol v6. Event lines are JSON objects with an `event` string and no response envelope.

Implemented event lines can appear on two stream types:

| Stream | How to start | Event names |
| --- | --- | --- |
| Subscribe stream | `subscribe` command | `tree-changed`, `surface-output`, `surface-resized`, `surface-exited`, `title-changed`, `bell`, `notification`, `empty` |
| Attach stream v5 | `attach-surface` command | `vt-state`, `output`, `detached` |
| Attach stream v6 | `attach-surface` command | `vt-state`, `resized`, `output`, `detached` |

Events and command responses share one JSON-lines connection. Clients must route lines by checking for `event`. If `event` is absent, the line is a command response and should be matched by `id`.

## Ordering Guarantees

The socket writes each response or event as one complete JSON line. Lines are not interleaved at the byte level.

For a single subscription, events are delivered in the order the mux broadcasts them. The server does not create a total order across unrelated producer threads beyond the order in which events enter the mux broadcaster.

`subscribe` registers the event receiver before the command response is written. A client must not treat the `subscribe` response as an event-stream barrier.

`subscribe` does not send an initial tree snapshot. Clients that need the current tree must call `list-workspaces`, then subscribe, then reconcile any events that arrive between the two operations according to application needs.

`attach-surface` has a stronger ordering contract. The server takes the VT replay snapshot and registers the live output tap under the same terminal lock. The attach stream therefore has no gap and no duplicated bytes between the `vt-state` replay and subsequent `output` chunks. In v5, the `vt-state` event is sent before the `attach-surface` command response.

Protocol v6 attach streams are ordered as `vt-state -> (resized | output)* -> detached`. The v6 `resized` event carries a fresh replay, and attach clients must replace their mirror terminal from that replay before applying later `output` chunks. Clients that support only protocol 5 or older must refuse protocol v6 attach streams. The field name `replay` on the v6 `resized` event could not be verified against this branch's code.

When a surface exits, the mux removes it from the tree itself. Subscribe streams normally receive `tree-changed` and possibly `empty` before `surface-exited` for that surface. By the time `surface-exited` is observed, frontends should consider the surface reaped from authoritative tree state.

## Implemented Subscribe Events

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

Example:

```json
{"event":"tree-changed"}
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

### surface-resized

| Field | Value |
| --- | --- |
| event | `surface-resized` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"surface-resized",surface:Id,cols:uint16,rows:uint16}
```

Meaning: A surface's final clamped cell size changed. A same-size `resize-surface` command returns success but emits no `surface-resized` event.

Example:

```json
{"event":"surface-resized","surface":1,"cols":120,"rows":40}
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

Payload:

```text
object{event:"title-changed",surface:Id}
```

Meaning: A surface title changed. The event does not include the new title. Clients should call `list-workspaces` to read the current tab title.

Example:

```json
{"event":"title-changed","surface":1}
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

## Implemented Attach Events

### vt-state

| Field | Value |
| --- | --- |
| event | `vt-state` |
| status | implemented |
| since | protocol 5 |

Payload:

```text
object{event:"vt-state",surface:Id,cols:uint16,rows:uint16,data:Base64}
```

Meaning: Initial VT replay for an attached PTY surface. Replaying `data` into a fresh Ghostty VT terminal with the supplied cell size reproduces current state.

Example:

```json
{"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"G1s/bA=="}
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
object{event:"resized",surface:Id,cols:uint16,rows:uint16,replay:Base64}
```

Meaning: Protocol v6 attach-only event indicating that the authoritative surface size changed and the existing mirror must be replaced from the supplied replay. Clients must create a fresh terminal mirror at `cols` by `rows`, replay `replay`, then continue applying later `output` chunks. The `replay` field name could not be verified against this branch's `server.rs`.

Example:

```json
{"event":"resized","surface":1,"cols":100,"rows":30,"replay":"G1s/bA=="}
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
| since | proposed protocol 6 |

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
| since | proposed protocol 6 |

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

Protocol v6 extends `subscribe` with optional filters:

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
