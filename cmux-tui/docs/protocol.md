# Control Socket Protocol

As of protocol v8, every server speaks JSON Lines over a Unix domain socket. Send one JSON object per line. Every request receives one response line. `subscribe`, `subscribe-topology`, and `attach-surface` also push event lines on the same connection.

Unix requests and authenticated WebSocket command frames are limited to 4 MiB.
The Unix reader closes an oversized connection without buffering past that
limit.

For shell use, prefer `cmux-tui <verb>`; it wraps the same socket commands and preserves JSON output with `--json`.

Default socket path, using `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`:

```text
<runtime-dir>/cmux-tui-<uid>/<session>.sock
```

On Darwin, an oversized environment runtime root falls back to the private mode-`0700` directory `/tmp/cmux-tui-<uid>`. Filesystem socket paths accept 103 bytes and reject 104 bytes; paths are never truncated.

`identify` reports protocol v8 as the preferred version and v9 as the opt-in maximum:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"...","protocol":8,"protocol_min":6,"protocol_max":9,"capabilities":["canonical-topology-snapshot-v1","projection-state-reconnect-v1","stable-entity-uuid-v1","terminal-activity-v1","terminal-control-lease-v1","terminal-input-idempotency-v1","terminal-ordered-input-v1","topology-resume-v1"],"session":"main","session_id":"<uuid>","daemon_instance_id":"<uuid>","topology_revision":47,"canonical_topology_revision":42,"pid":12345}}
```

`ping` returns the same session, daemon, process, and revision authority fields
without the `app` field. Supervisors can prove readiness and process continuity
with `ping`; they do not need to decode `topology-snapshot`.

Responses have this shape:

```json
{"id":1,"ok":true,"data":{}}
{"id":2,"ok":false,"error":"unknown surface 99"}
```

Bad JSON returns `ok:false` with no request id.

## Command Contract

The full API contract lives in `spec/`. `cmux-tui-core/src/server.rs` is the implementation source of truth.

The server command set in this branch is:

```text
identify
ping
open-presentation
update-presentation
close-presentation
list-presentations
claim-projection-state
update-projection-state
update-projection-states
release-projection-state
list-projection-states
topology-snapshot
list-workspaces
send
read-screen
vt-state
new-tab
new-browser-tab
new-workspace
new-screen
split
set-ratio
move-tab
move-workspace
set-default-colors
close-surface
close-pane
close-screen
close-workspace
rename-pane
rename-surface
rename-screen
rename-workspace
resize-surface
release-surface-size
focus-pane
select-tab
select-screen
select-workspace
browser-mouse
browser-wheel
browser-key
browser-insert-text
browser-navigate
browser-back
browser-forward
browser-reload
browser-activate
subscribe
subscribe-topology
attach-surface
scroll-surface
```

## Canonical Topology

Protocol v8 clients should require `canonical-topology-snapshot-v1`, `stable-entity-uuid-v1`, and `topology-resume-v1`. Fetch one atomic snapshot:

```json
{"id":12,"cmd":"topology-snapshot"}
{"id":12,"ok":true,"data":{"daemon_instance_id":"<uuid>","session_id":"<uuid>","revision":41,"topology":{"workspaces":[]}}}
```

Resume from that exact daemon, session, and revision on a persistent connection:

```json
{"id":13,"cmd":"subscribe-topology","daemon_instance_id":"<uuid>","session_id":"<uuid>","revision":41}
{"id":13,"ok":true,"data":{"status":"subscribed","daemon_instance_id":"<uuid>","session_id":"<uuid>","from_revision":41,"current_revision":41,"replayed":0}}
{"event":"topology-delta","daemon_instance_id":"<uuid>","session_id":"<uuid>","base_revision":41,"revision":42,"operation":"workspace-created","targets":{"workspaces":["<uuid>"]},"replacement":{"workspaces":[...]}}
```

Every successful structural topology transaction produces one delta. Failed and no-op requests produce none. Focus, selection, zoom, and scroll are presentation state, so legacy navigation commands keep their legacy events and advance only legacy `topology_revision`, not this canonical revision. Capability-v1 carries a complete replacement so clients can apply it deterministically. Replacement construction and wire bandwidth scale with the full topology, so this bootstrap does not make mutation cost independent of dormant workspaces. A follow-up capability can add typed patches without weakening the cursor and recovery contract. The retained history and each subscriber queue are bounded by count and serialized bytes. A stale daemon, stale session, future revision, history gap, oversized replay, or slow consumer requires a fresh snapshot. One connection may open one topology stream; the daemon permits 256 live streams. Duplicate and excess subscriptions fail before allocating a journal mailbox. Presentations, terminal content and geometry, titles, process status, notifications, agent records, PTY bytes, and render frames are outside this stream.

`projection-state-reconnect-v1` stores only stable logical-window to workspace and selected-screen mappings in daemon memory. Registered protocol-v9 frontends claim each stable window UUID, atomically update affected windows after local projection succeeds, and release a record when the user explicitly closes that window. Disconnect preserves mappings while releasing claims, renderer resources, and terminal-control leases. These mappings do not advance canonical topology revision and do not survive daemon restart.

Canonical protocol-v8 objects retain numeric IDs as current-daemon handles for legacy commands. Their parallel UUID fields are the daemon-owned identities and remain stable through rename, reorder, and move operations. Protocol-v7 tree payloads stay numeric and have no UUID guarantee. A recreated entity receives a new UUID. A daemon restart changes `daemon_instance_id`, so a client cannot resume against a replacement process even when `session_id` is unchanged.

`move-tab` moves a surface to a target pane and insertion index. It supports same-pane reorder and cross-pane moves.

```json
{"id":10,"cmd":"move-tab","surface":4,"pane":2,"index":0}
```

`move-workspace` moves a workspace to an insertion index.

```json
{"id":11,"cmd":"move-workspace","workspace":3,"index":0}
```

## Events

`subscribe` starts event streaming:

```json
{"id":20,"cmd":"subscribe"}
```

Response data is `{}`. Future event lines may interleave with responses.

Subscribed event lines are:

```json
{"event":"surface-output","surface":4}
{"event":"surface-resized","surface":4,"cols":120,"rows":40,"reservation_id":7}
{"event":"surface-resize-failed","surface":4,"cols":120,"rows":40,"error":"browser is not responding","retry_after_ms":250,"reservation_id":7}
{"event":"surface-exited","surface":4}
{"event":"title-changed","surface":4,"title":"build logs"}
{"event":"bell","surface":4}
{"event":"tree-changed"}
{"event":"empty"}
```

`surface-resized` reports the final clamped cell size and is emitted only when the surface size actually changes. `surface-resize-failed` reports an asynchronous browser resize failure and the delay before an automatic retry, or `null` after retries are exhausted. Browser resize completions repeat the numeric `reservation_id` returned by the accepted request so clients can ignore stale completions.

Protocol v7 `title-changed` carries the authoritative current `title`. Slow subscribers coalesce repeated pending title changes per surface to the latest value.

Browser input, navigation, activation, and browser reconfigure work from `resize-surface` enqueue per-surface CDP work. Protocol v7 `resize-surface` responses include `data.accepted` and `data.reservation_id`; `true` means the resize was applied or queued, and `false` means it was already satisfied, pending, or waiting for its retry backoff. Completion arrives as `surface-resized`, and asynchronous failure arrives as `surface-resize-failed`. Two consecutive CDP call timeouts mark only that browser surface failed with `browser is not responding`.

## Attach Surface

`attach-surface` streams a PTY or browser surface.

```json
{"id":30,"cmd":"attach-surface","surface":4}
```

The server first sends:

```json
{"event":"vt-state","surface":4,"cols":120,"rows":40,"data":"<base64-vt-replay>"}
```

Then it sends ordered stream frames:

```json
{"event":"output","surface":4,"data":"<base64-pty-bytes>"}
{"event":"resized","surface":4,"cols":132,"rows":43,"replay":"<base64-vt-replay>"}
```

The `resized` attach frame carries the new cell size and a fresh VT replay captured at that size. It is delivered in the same attach stream as output frames, so a client can reset its local terminal, apply the replay, and continue consuming later output in order.

Registered protocol-v9 clients may request the explicit noncanonical compatibility stream:

```json
{"id":31,"cmd":"attach-surface","surface":4,"mode":"compatibility"}
{"event":"vt-state","surface":4,"surface_uuid":"<uuid>","runtime_epoch":17,"generation":1,"sequence":240,"fidelity":"noncanonical-byte-stream","cols":120,"rows":40,"data":"<base64-vt-replay>"}
{"event":"output","surface":4,"surface_uuid":"<uuid>","runtime_epoch":17,"generation":1,"start_sequence":240,"next_sequence":243,"data":"YWJj"}
```

The client accepts output only when the UUID and epoch match, the generation is current, and `start_sequence` equals its previous cursor. `resized` increments the generation and carries a complete replay plus the new cursor boundary. Overflow, a cursor gap, an unexpected generation, or a new runtime epoch requires reattach and full replay. The client-side parser is a presentation replica and cannot claim canonical state parity.

For browser surfaces, the server first sends `browser-state` with URL, title, size, status, stalled-frame state, and the latest PNG frame if one exists. Later updates send `browser-state` and `frame` events. Frame payloads are base64 PNG data and slow clients skip older frames rather than buffering unboundedly. Canonical browser endpoints advertise `frontend_projection:"frontend-optional"`, so a frontend without this PNG consumer can omit only the browser presentation while retaining sibling terminal convergence. The daemon identity remains reserved and cannot be reused by a local browser overlay.

When the stream ends, it sends:

```json
{"event":"detached","surface":4}
```

## Client Compatibility

The remote TUI accepts protocol v7 and v8. It uses the retained legacy attach and event contract in both versions and refuses older or unknown newer versions.

The external renderer backend can negotiate protocol v9 with `register-client`. V9 moves each terminal one-way from shared legacy mutation to independent connection-and-presentation-bound input and geometry leases. It adds lane transfer, bounded automation input delegation, atomic input groups, one daemon-assigned input order per canonical terminal, and acknowledged idempotent retry receipts. The complete contract is in `../spec/terminal-control-v9.md`.

Attach clients mirror PTY surfaces locally. On first render, a client can resize the server surface before requesting `attach-surface`, so the initial VT replay is captured at the visible geometry.

When several attach clients render the same surface at different sizes, sizing follows latest local interaction. A client reasserts its visible sizes after key input, mouse input, paste, focus gained, or terminal resize. Mux-driven redraws update local mirrors from `surface-resized` without reasserting an idle client's viewport.

## Browser Limitations

Browser surfaces appear in `list-workspaces` as `kind: "browser"` with `browser_source: "external"` or `"launched"` once live, plus additive `browser_status`, `browser_error`, and `browser_frames_stalled` fields. PTY and VT commands against browser surfaces return errors.
