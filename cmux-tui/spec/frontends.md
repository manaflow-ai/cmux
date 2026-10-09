# Build a cmux-tui Frontend

This guide covers the private protocol-v12 frontend interface. Applications
and extensions should use [`cmux.protocol/2`](resource-api-v2.md) and its typed
terminal, browser, sidebar, and session streams.

Rich frontends consume the server's authoritative render state: draw runs, place the cursor, and send keys. Byte attach remains the terminal-piping path for clients that intentionally run a terminal emulator or forward raw PTY state elsewhere.

The complete command schemas are in [`commands.md`](commands.md), event schemas and scoping are in [`events.md`](events.md), and styled-cell details are in [`render.md`](render.md).

## 1. Connect

For a local native frontend, connect to the Unix socket described in [`transports.md`](transports.md#unix-socket). Send each JSON request followed by `\n`, split incoming bytes on `\n`, and ignore blank lines.

For a browser or remote-capable frontend, connect to the opt-in WebSocket listener. Send one complete JSON request per text frame and treat every received text frame as one complete response or event. Do not add newline framing. The TypeScript SDK exposes `WebSocketTransport` for browsers and compatible Node WebSocket implementations.

Every WebSocket authenticates before protocol commands. A static or previously issued credential uses this first-frame preamble, which is not a command and has no acknowledgement. Interactive clients may use the pairing exchange in [`transports.md`](transports.md#authentication-and-pairing) instead:

```json
{"auth":{"token":"replace-with-a-secret"}}
```

Only then send protocol requests. See [`transports.md`](transports.md#authentication-and-pairing) for rejection and bind rules.

## 2. Identify And Select Capabilities

Send [`identify`](commands.md#identify) immediately after connecting. Verify `data.app == "cmux-tui"` and `data.protocol == 12` before enabling protocol-v12 behavior. Preserve request `id` values and route every non-event response back to the pending request with that id.

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":["view-attachment-lease-v1","view-attachment-detach-v1","creation-receipts-v1","creation-attempt-keys-v1","creation-selector-fallbacks-v1"],"session":"main","pid":12345}}
{"id":2,"cmd":"set-client-info","kind":"frontend","capabilities":["view-attachment-lease-v1","view-attachment-detach-v1","creation-receipts-v1","creation-attempt-keys-v1","creation-selector-fallbacks-v1"]}
{"id":2,"ok":true,"data":{}}
```

Require `protocol == 12` for the complete flow in this guide, including lifecycle readiness, terminal lifecycle results, and per-surface client sizing. Stack layouts and `new-pane` remain available on protocol 9. Stable split ids and `set-split-ratio` remain available on protocol 8. Render mode, `read-scrollback`, bracketed-paste handling, and lifecycle deltas remain available on protocol 7. A frontend may fall back to protocol-v6 byte attach; it must not send newer fields to an older server.

Echo every optional capability the frontend will use through
`set-client-info`. Capability state belongs to this connection. Lease-capable
frontends must negotiate both view attachment capabilities before opening
streams; creation fallbacks require both creation capabilities.

## 3. Load And Track The Workspace Tree

Open [`subscribe`](commands.md#subscribe) with `tree_events:"deltas"`, buffer events as soon as the request is sent, then fetch [`list-workspaces`](commands.md#list-workspaces). Apply the snapshot before draining the buffer. The subscribe receiver is registered before its success response, so responses and events may race. Omitting `tree_events` selects the protocol-v6-compatible coarse stream instead.

Treat cmux-tui as the authority for terminal identity, process lifetime,
ordered input, output history, and canonical PTY geometry. A terminal is a
session resource, not a child of a workspace or tab. One terminal may appear
in any number of tabs or frontend projection nodes at once. Closing a tab,
pane, screen, workspace, window, or frontend connection only removes that
view. Only [`close-terminal`](commands.md#close-terminal) terminates and
tombstones the terminal on protocol v11. The public resource API names the
same lifecycle operation `terminal.close`.

The server workspace/screen/pane/tab tree is one durable shared projection.
It remains available to existing frontends and collaboration flows, but its
active workspace, screen, pane, and tab fields are defaults for that shared
projection, not global user focus. A frontend keeps its current workspace,
screen, pane, tab, text selection, scroll position, crop, pan, scale, hover,
drag state, and key-prefix state in client memory. It must not publish those
ephemeral values through the legacy focus commands.

A frontend may also persist a schema-versioned opaque projection with
`put-frontend-projection`. Use `scope:"personal"` and a stable user/profile or
device identity for a private durable view. Use `scope:"shared"` and a stable
group or collaboration-view identity for a view that multiple clients edit.
Existing application-specific scopes remain valid. A durable projection may
contain layouts, browser-only content, terminal placements, and saved focus or
viewport preferences. It may reference the same terminal UUID more than once,
but it never owns that terminal's process lifetime.

Use a stable profile or collaboration identity as the cmux session and
projection subject. Do not generate a new session on every app launch.
Workspace keys are lowercase canonical UUIDs; reject invalid keys instead of
deriving identity from a name. Projection references use canonical workspace,
tab, and terminal UUIDs.

Generate `origin` and `mutation_id` before sending a workspace mutation and
reuse both for retries. Apply a successful local response immediately, then
deduplicate its matching event by mutation identity. On boot-generation
change, event gap, or subscription overflow, discard daemon-local ids and
reconcile from a fresh `list-workspaces` snapshot plus the latest projection.

Protocol v7 and newer lifecycle events (`workspace-*`, `screen-*`, `pane-*`,
and `tab-*`) carry subject ids, parent ids, and exact `list-workspaces` entity
payloads. Apply those deltas in stream order. `layout-changed`, surface events,
and title events retain their documented focused invalidation paths.

Always implement `tree-changed`: it is the delta stream's coarse resync fallback for churn and changes not represented by lifecycle deltas. Do not rely on it for ordinary delta-representable mutations. On receipt, fetch a new `list-workspaces` snapshot and treat it as authoritative over older buffered deltas. See the [event-scoping table](events.md#event-scoping) before routing events from a connection with streams.

Every protocol-v8 and newer split layout node has a stable `split` id. Preserve that id as the UI key for the divider and call [`set-split-ratio`](commands.md#set-split-ratio) while dragging. Do not derive divider identity from child panes or tree position. Ratio changes, focus changes, tab changes, and leaf swaps preserve the id; collapsing that node removes it. Protocol-v9 stack nodes require at least one pane and identify an expanded pane that belongs to that list.

Initial surface dimensions and geometry ownership follow the consolidated
[`Sizing`](commands.md#sizing) contract. Passive clients report their viewport
without resizing the PTY. A client explicitly claims geometry for one terminal
view, and the canonical grid stays frozen when that owner disconnects until a
client makes another explicit claim. The Rust `chatmux-relay` wrapper closes a
lost relay attachment and waits for a newly attached viewer to make that
explicit claim; it does not elect a survivor or issue a cross-socket claim.

## 4. Render A PTY Surface

For a rich web or native frontend, call [`attach-surface`](commands.md#attach-surface) with `mode:"render"`:

```json
{"id":4,"cmd":"attach-surface","surface":1,"mode":"render"}
```

Capture `data.lease` from the response and bind it to this local view. Use
`resize-attached-view` for its grid, `release-attached-view-size` while the
view is cached but hidden, and `detach-attached-view` when the local view is
retired. Never reuse the lease for another surface or a replacement attach.

The first attach event is `render-state`. Allocate the grid from `size`, paint each row's maximal styled runs, apply server-resolved RGB/default colors, and draw the cursor only when `cursor.visible` is true. `text` is ordinary UTF-8; do not base64-decode it and do not instantiate xterm.js or another VT parser.

Apply later `render-delta` events in order. Replace each supplied row by `Row.row`; update the cursor on every delta, including an empty-row cursor-only delta. When `full:true`, replace the entire viewport. A resize includes the new `size`, sets `full:true`, and includes every row, so no old row mapping survives reflow. `scroll-changed` updates viewport position, and `detached` ends the attachment.

```text
render-state -> (render-delta | scroll-changed)* -> detached
```

The initial snapshot and render tap are registered under one lock, so there is no missing or duplicated frame between them. Attach events may arrive before the attach command response.

Call [`list-agents`](commands.md#list-agents) to read current agent records, optionally filtered by surface or state. Agent producers report state through [`report-agent`](commands.md#report-agent); a presentation-only frontend normally reads and displays these records rather than inventing its own agent state. There is no dedicated agent-change event in protocol v11, so re-fetch after a frontend reports state and when tree or surface lifecycle events make the presentation stale.

`render-state.scrollback_rows` and later count changes tell the frontend whether history exists. Fetch visible history in bounded pages with [`read-scrollback`](commands.md#read-scrollback); do not assume indexes remain stable across eviction or resize reflow. Merge pages and project absolute graphics anchors only when the page `epoch` equals the render `history_epoch`; suppress graphics and reload the page after a mismatch.

Browser surfaces use default attach mode. The initial `browser-state` contains URL, title, lifecycle status, frame-stall state, and the latest frame when available. Later `browser-state` and `frame` events update metadata and pixels separately. Send pointer input with `browser-mouse` and `browser-wheel`, keyboard input with `browser-key` or `browser-insert-text`, and navigation through `browser-navigate`, `browser-back`, `browser-forward`, `browser-reload`, and `browser-activate`. Each command acknowledges queueing with `{}`; observe the attach stream for eventual state.

## 5. Byte Mode For Terminal Piping

Use `mode:"bytes"`, or omit `mode`, when the client is a terminal pipe or deliberately maintains a second terminal emulator. This is the exact protocol-v6 contract: decode the initial `vt-state.data`, replay it into a fresh emulator at `cols` by `rows`, then apply decoded `output.data` bytes in order. On `resized`, replace the emulator from the fresh replay before later output. Apply `colors-changed` metadata and stop at `detached`.

```text
vt-state -> (resized | output | colors-changed | scroll-changed)* -> detached
```

Render mode is preferred for xterm.js-style web UIs and future Swift frontends because it avoids parser drift from the server's Ghostty state, including cursor visuals, resolved colors, dirty rows, and retained scrollback.

## 6. Send Input And Resize

Use [`send-key`](commands.md#send-key) for named keys and terminal-mode-aware encoding. Use [`send`](commands.md#send) for UTF-8 text or raw bytes. For a paste action, set `paste:true`; the server adds bracketed-paste markers only when the target terminal currently has DEC mode 2004 enabled and otherwise sends the payload unchanged.

Protocol v9 render mode has no PTY mouse or focus-input command. A render frontend cannot reproduce mouse-aware applications such as vim or tmux without maintaining its own terminal modes and using byte input. `send-mouse` and `send-focus` are required vNext primitives.

When the active frontend's geometry changes, convert pixels to cells, report
the view size, and explicitly claim terminal geometry for that view. A passive
frontend crops, pans, or scales the authoritative grid. Attaching a view never
changes canonical geometry. Render and byte clients observe the same grid,
while their scroll, selection, and viewport state remain independent.

## 7. Notifications And Agents

The workspace tree carries per-surface notification state for initial rendering. Subscribed frontends receive `notification` events with a notification subject id and an optional related surface. Show the notification and mark a related surface as needing attention until the user views it.

Call [`list-agents`](commands.md#list-agents) for current agent records. Agent producers use [`report-agent`](commands.md#report-agent); presentation-only frontends display server state rather than inventing a second agent-state model.

## End-To-End WebSocket Transcript

Each line is one WebSocket text frame. `C>` is client-to-server and `S>` is server-to-client. This transcript uses a static or previously issued credential; an interactive client completes pairing first instead.

```text
C> {"auth":{"token":"secret"}}
C> {"id":1,"cmd":"identify"}
S> {"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":12,"session":"main","pid":12345}}
C> {"id":2,"cmd":"subscribe","tree_events":"deltas"}
S> {"id":2,"ok":true,"data":{}}
C> {"id":3,"cmd":"list-workspaces"}
S> {"id":3,"ok":true,"data":{"workspaces":[...]}}
C> {"id":4,"cmd":"attach-surface","surface":1,"mode":"render"}
S> {"event":"render-state","surface":1,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#d8d9da","default_bg":"#131415","scrollback_rows":0,"history_epoch":1,"rows":[{"row":0,"runs":[{"text":"$ x","fg":null,"bg":null,"attrs":0}]}]}
S> {"id":4,"ok":true,"data":{}}
C> {"id":5,"cmd":"send","surface":1,"text":"echo ready\n"}
S> {"id":5,"ok":true,"data":{}}
S> {"event":"render-delta","surface":1,"cursor":{"x":0,"y":0,"style":"block","blink":true,"visible":true,"color":null},"full":false,"rows":[{"row":0,"runs":[{"text":"ok ","fg":null,"bg":null,"attrs":0}]}]}
C> {"id":6,"cmd":"resize-surface","surface":1,"cols":4,"rows":1}
S> {"id":6,"ok":true,"data":{"accepted":false,"reservation_id":null}}
C> {"id":7,"cmd":"set-client-sizing","surface":1,"enabled":true,"exclusive":true}
S> {"id":7,"ok":true,"data":{}}
C> {"id":8,"cmd":"resize-surface","surface":1,"cols":4,"rows":1}
S> {"event":"render-delta","surface":1,"cursor":{"x":0,"y":0,"style":"block","blink":true,"visible":true,"color":null},"full":true,"size":{"cols":4,"rows":1},"rows":[{"row":0,"runs":[{"text":"ok  ","fg":null,"bg":null,"attrs":0}]}]}
S> {"id":8,"ok":true,"data":{"accepted":true,"reservation_id":2}}
C> {"id":9,"cmd":"rename-surface","surface":1,"name":"shell"}
S> {"event":"tab-renamed","workspace":4,"screen":3,"pane":2,"surface":1,"entity":{"surface":1,"kind":"pty","browser_source":null,"name":"shell","title":"","size":{"cols":4,"rows":1},"dead":false}}
S> {"id":9,"ok":true,"data":{}}
```

The ordering around streaming commands is intentional. Once streaming begins, never assume request-response alternation.
