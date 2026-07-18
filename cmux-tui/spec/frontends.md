# Build a cmux-tui Frontend

This is the canonical integration path for an external cmux-tui frontend. Protocol v8 frontends use the canonical topology snapshot/resume stream and consume the server's authoritative render state: draw runs, place the cursor, and send keys. Byte attach remains the terminal-piping path for clients that intentionally run a terminal emulator or forward raw PTY state elsewhere.

The complete command schemas are in [`commands.md`](commands.md), event schemas and scoping are in [`events.md`](events.md), and styled-cell details are in [`render.md`](render.md).

## 1. Connect

For a local native frontend, connect to the Unix socket described in [`transports.md`](transports.md#unix-socket). Send each JSON request followed by `\n`, split incoming bytes on `\n`, and ignore blank lines.

For a browser or remote-capable frontend, connect to the opt-in WebSocket listener. Send one complete JSON request per text frame and treat every received text frame as one complete response or event. Do not add newline framing. The TypeScript SDK exposes `WebSocketTransport` for browsers and compatible Node WebSocket implementations.

Every WebSocket authenticates before protocol commands. A static or previously issued credential uses this first-frame preamble, which is not a command and has no acknowledgement. Interactive clients may use the pairing exchange in [`transports.md`](transports.md#authentication-and-pairing) instead:

```json
{"auth":{"token":"replace-with-a-secret"}}
```

Only then send protocol requests. See [`transports.md`](transports.md#authentication-preamble) for rejection and bind rules.

## 2. Identify And Select Capabilities

Send [`identify`](commands.md#identify) immediately after connecting. Verify `data.app == "cmux-tui"`. Preserve request `id` values and route every non-event response back to the pending request with that id. Select features by named capability.

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":8,"protocol_min":6,"protocol_max":9,"capabilities":["canonical-topology-snapshot-v1","projection-state-reconnect-v1","render-attach-v1","stable-entity-uuid-v1","terminal-control-lease-v1","terminal-input-idempotency-v1","terminal-ordered-input-v1","topology-resume-v1"],"session":"main","session_id":"<uuid>","daemon_instance_id":"<uuid>","topology_revision":47,"canonical_topology_revision":42,"pid":12345}}
```

Require `render-attach-v1` before requesting render mode. Require all of `canonical-topology-snapshot-v1`, `stable-entity-uuid-v1`, and `topology-resume-v1` before using protocol-v8 topology synchronization. A frontend may fall back to the protocol-v7 legacy tree flow and protocol-v6 byte attach; it must not send capability-gated fields to an older server.

Supervisors may use `ping` for readiness and continuity checks. Its `session_id`,
`daemon_instance_id`, `pid`, and `canonical_topology_revision` prove socket
authority and process continuity without fetching the full topology.

## 3. Load And Track The Workspace Tree

Fetch [`topology-snapshot`](commands.md#topology-snapshot), persist its `daemon_instance_id`, `session_id`, `revision`, and topology together, then open [`subscribe-topology`](commands.md#subscribe-topology) with that daemon, session, and revision. Registration either succeeds with every retained structural mutation after the snapshot or returns `resnapshot-required`. There is no mutation gap between the snapshot and a successful registration. Keep focus, selection, zoom, and scroll in the connection-owned presentation registry.

Check that each `topology-delta` matches the accepted daemon and session and begins at the locally applied revision. Replace canonical topology with its `replacement` and advance to its `revision`. The replacement contains stable UUIDs alongside legacy numeric IDs. Key long-lived frontend objects by UUID; numeric IDs remain command handles for the current daemon.

On `resnapshot-required` or `topology-resnapshot-required`, discard the cursor, fetch a new atomic snapshot, and open a new topology subscription. Never bridge a daemon change by revision alone, because a restarted daemon can reload the same session identity. The legacy fallback is `subscribe` plus `list-workspaces`; it remains available for protocol-v7 servers.

### Restore Native Windows Across Frontend Restart

A protocol-v9 native frontend with `projection-state-reconnect-v1` registers stable client and process UUIDs. After restoring its stable window UUIDs, it calls `list-projection-states`, rejects daemon records absent from the restored window set, and claims every live window before projecting canonical topology. A new claim fences the prior frontend process.

After a successful local projection transaction, replace every live window mapping in one `update-projection-states` request. Include source and destination when moving a workspace. Disconnect preserves mappings while releasing claims, renderer presentations, and terminal-control leases. Call `release-projection-state` only for an explicit window close. A changed `daemon_instance_id` means the daemon-memory registry was lost, so rebuild placement from the frontend session and canonical topology.

Initial surface dimensions and smallest-client resize reporting follow the consolidated [`Sizing`](commands.md#sizing) contract.

## 4. Render A PTY Surface

For a rich web or native frontend, call [`attach-surface`](commands.md#attach-surface) with `mode:"render"`:

```json
{"id":4,"cmd":"attach-surface","surface":1,"mode":"render"}
```

The first attach event is `render-state`. Allocate the grid from `size`, paint each row's maximal styled runs, apply server-resolved RGB/default colors, and draw the cursor only when `cursor.visible` is true. `text` is ordinary UTF-8; do not base64-decode it and do not instantiate xterm.js or another VT parser.

Apply later `render-delta` events in order. Replace each supplied row by `Row.row`; update the cursor on every delta, including an empty-row cursor-only delta. When `full:true`, replace the entire viewport. A resize includes the new `size`, sets `full:true`, and includes every row, so no old row mapping survives reflow. `scroll-changed` updates viewport position, and `detached` ends the attachment.

```text
render-state -> (render-delta | scroll-changed)* -> detached
```

The initial snapshot and render tap are registered under one lock, so there is no missing or duplicated frame between them. Attach events may arrive before the attach command response.

`render-state.scrollback_rows` and later count changes tell the frontend whether history exists. Fetch visible history in bounded pages with [`read-scrollback`](commands.md#read-scrollback); do not assume indexes remain stable across eviction or resize reflow.

Browser surfaces use their separate browser attach events rather than terminal render rows. A native frontend may claim a canonical browser presentation only after consuming the `browser_endpoint` transport for the exact snapshot authority, numeric handle, and stable surface UUID. Recreating a local WKWebView with the same UUID is a client-owned overlay, not a daemon reattach. An endpoint marked `frontend_projection:"frontend-optional"` may be pruned by a frontend that does not consume its transport; the frontend also collapses any empty canonical browser-only pane and continues projecting sibling PTYs. The omitted surface remains daemon-owned and reserves its canonical UUID against local overlay collisions. The terminal isolation in [cmux-browser PR 4](https://github.com/manaflow-ai/cmux-browser/pull/4) does not expose an AppKit browser-content endpoint; `browser_endpoint` is the alignment contract for that later integration.

## 5. Byte Mode For Terminal Piping

Use `mode:"bytes"`, or omit `mode`, when the client is a terminal pipe or deliberately maintains a second terminal emulator. This is the exact protocol-v6 contract: decode the initial `vt-state.data`, replay it into a fresh emulator at `cols` by `rows`, then apply decoded `output.data` bytes in order. On `resized`, replace the emulator from the fresh replay before later output. Apply `colors-changed` metadata and stop at `detached`.

```text
vt-state -> (resized | output | colors-changed | scroll-changed)* -> detached
```

Render mode is preferred for xterm.js-style web UIs and future Swift frontends because it avoids parser drift from the server's Ghostty state, including cursor visuals, resolved colors, dirty rows, and retained scrollback.

## 6. Send Input And Resize

Use [`send-key`](commands.md#send-key) for named keys and terminal-mode-aware encoding. Use [`send`](commands.md#send) for UTF-8 text or raw bytes. For a paste action, set `paste:true`; the server adds bracketed-paste markers only when the target terminal currently has DEC mode 2004 enabled and otherwise sends the payload unchanged.

A registered v9 frontend follows `terminal-control-v9.md` instead of these
legacy mutation commands. Open a presentation, then publish visibility through
renderer configuration or `activate-terminal-presentation`. Visibility alone
must not acquire input or geometry. Acquire input when dispatching actual
input, and acquire geometry only for an explicit canonical resize. Keep each
queued request UUID and payload until its receipt is definitive. After an
uncertain response, query `terminal-request-status` before any resend and send
`acknowledge-terminal-request` after consuming the result.

When the active frontend's geometry changes, convert pixels to cells and call [`resize-surface`](commands.md#resize-surface) with the final `cols` and `rows`. A smaller passive frontend should crop or pan the authoritative grid instead of fighting another client with resize loops. Render and byte clients share one surface size.

## 7. Notifications And Agents

Registered protocol-v9 frontends require `terminal-activity-v1`. Start `subscribe-topology`, then fetch `terminal-activity-snapshot`; events queued before the snapshot are harmless because the persisted snapshot owns that sequence prefix. A terminal is unread when its latest fact sequence is greater than that reader's receipt. Call `mark-terminal-seen` with the fact sequence after the terminal becomes visible. Never clear global activity. A reconnect reuses the descriptor's stable `client_uuid`, restores its receipts, and applies only contiguous later fact sequences. Legacy clients continue deriving notification fields through the reserved legacy reader.

Call [`list-agents`](commands.md#list-agents) for current agent records. Agent producers use [`report-agent`](commands.md#report-agent); presentation-only frontends display server state rather than inventing a second agent-state model.

## End-To-End WebSocket Transcript

Each line is one WebSocket text frame. `C>` is client-to-server and `S>` is server-to-client. This transcript uses a static or previously issued credential; an interactive client completes pairing first instead.

```text
C> {"auth":{"token":"secret"}}
C> {"id":1,"cmd":"identify"}
S> {"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":8,"protocol_min":6,"protocol_max":9,"capabilities":["canonical-topology-snapshot-v1","projection-state-reconnect-v1","render-attach-v1","stable-entity-uuid-v1","terminal-control-lease-v1","terminal-input-idempotency-v1","terminal-ordered-input-v1","topology-resume-v1"],"session":"main","pid":12345}}
C> {"id":2,"cmd":"topology-snapshot"}
S> {"id":2,"ok":true,"data":{"daemon_instance_id":"1dbcaf41-c45b-4b5f-962f-7a9b20a40353","session_id":"4c28ed8c-d4e8-487e-a063-d7df07d378f9","revision":41,"topology":{"workspaces":[...]}}}
C> {"id":3,"cmd":"subscribe-topology","daemon_instance_id":"1dbcaf41-c45b-4b5f-962f-7a9b20a40353","session_id":"4c28ed8c-d4e8-487e-a063-d7df07d378f9","revision":41}
S> {"id":3,"ok":true,"data":{"status":"subscribed","daemon_instance_id":"1dbcaf41-c45b-4b5f-962f-7a9b20a40353","session_id":"4c28ed8c-d4e8-487e-a063-d7df07d378f9","from_revision":41,"current_revision":41,"replayed":0}}
C> {"id":4,"cmd":"attach-surface","surface":1,"mode":"render"}
S> {"event":"render-state","surface":1,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#d8d9da","default_bg":"#131415","scrollback_rows":0,"rows":[{"row":0,"runs":[{"text":"$ x","fg":null,"bg":null,"attrs":0}]}]}
S> {"id":4,"ok":true,"data":{}}
C> {"id":5,"cmd":"send","surface":1,"text":"echo ready\n"}
S> {"id":5,"ok":true,"data":{}}
S> {"event":"render-delta","surface":1,"cursor":{"x":0,"y":0,"style":"block","blink":true,"visible":true,"color":null},"full":false,"rows":[{"row":0,"runs":[{"text":"ok ","fg":null,"bg":null,"attrs":0}]}]}
C> {"id":6,"cmd":"resize-surface","surface":1,"cols":4,"rows":1}
S> {"event":"render-delta","surface":1,"cursor":{"x":0,"y":0,"style":"block","blink":true,"visible":true,"color":null},"full":true,"size":{"cols":4,"rows":1},"rows":[{"row":0,"runs":[{"text":"ok  ","fg":null,"bg":null,"attrs":0}]}]}
S> {"id":6,"ok":true,"data":{}}
C> {"id":7,"cmd":"rename-surface","surface":1,"name":"shell"}
S> {"event":"tab-renamed","workspace":4,"screen":3,"pane":2,"surface":1,"entity":{"surface":1,"kind":"pty","browser_source":null,"name":"shell","title":"","size":{"cols":4,"rows":1},"dead":false}}
S> {"id":7,"ok":true,"data":{}}
```

The ordering around streaming commands is intentional. Once streaming begins, never assume request-response alternation.
