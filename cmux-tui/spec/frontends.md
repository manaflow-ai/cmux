# Build a cmux-tui Frontend

This is the canonical integration path for an external cmux-tui frontend. This document narrates the complete protocol-v9 flow. Rich frontends should consume the server's authoritative render state: draw runs, place the cursor, and send keys. Byte attach remains the terminal-piping path for clients that intentionally run a terminal emulator or forward raw PTY state elsewhere.

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

Send [`identify`](commands.md#identify) immediately after connecting. Verify `data.app == "cmux-tui"` and `data.protocol == 9` before enabling protocol-v9 behavior. Preserve request `id` values and route every non-event response back to the pending request with that id.

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":9,"session":"main","pid":12345}}
```

Require `protocol == 9` for the complete flow in this guide, including stack layouts and `new-pane`. Stable split ids and `set-split-ratio` remain available on protocol 8. Render mode, `read-scrollback`, bracketed-paste handling, and lifecycle deltas remain available on protocol 7. A frontend may fall back to protocol-v6 byte attach; it must not send newer fields to an older server.

## 3. Load And Track The Workspace Tree

Open [`subscribe`](commands.md#subscribe) with `tree_events:"deltas"`, buffer events as soon as the request is sent, then fetch [`list-workspaces`](commands.md#list-workspaces). Apply the snapshot before draining the buffer. The subscribe receiver is registered before its success response, so responses and events may race. Omitting `tree_events` selects the protocol-v6-compatible coarse stream instead.

Protocol v7 and newer lifecycle events (`workspace-*`, `screen-*`, `pane-*`, and `tab-*`) carry subject ids, parent ids, and exact `list-workspaces` entity payloads. Apply those deltas in stream order. `layout-changed`, surface events, and title events retain their documented focused invalidation paths.

Always implement `tree-changed`: it is the delta stream's coarse resync fallback for churn and changes not represented by lifecycle deltas. Do not rely on it for ordinary delta-representable mutations. On receipt, fetch a new `list-workspaces` snapshot and treat it as authoritative over older buffered deltas. See the [event-scoping table](events.md#event-scoping) before routing events from a connection with streams.

Every protocol-v8 and newer split layout node has a stable `split` id. Preserve that id as the UI key for the divider and call [`set-split-ratio`](commands.md#set-split-ratio) while dragging. Do not derive divider identity from child panes or tree position. Ratio changes, focus changes, tab changes, and leaf swaps preserve the id; collapsing that node removes it. Protocol-v9 stack nodes require at least one pane and identify an expanded pane that belongs to that list.

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

Call [`list-agents`](commands.md#list-agents) to read current agent records, optionally filtered by surface or state. Agent producers report state through [`report-agent`](commands.md#report-agent); a presentation-only frontend normally reads and displays these records rather than inventing its own agent state. There is no dedicated agent-change event in protocol v9, so re-fetch after a frontend reports state and when tree or surface lifecycle events make the presentation stale.

`render-state.scrollback_rows` and later count changes tell the frontend whether history exists. Fetch visible history in bounded pages with [`read-scrollback`](commands.md#read-scrollback); do not assume indexes remain stable across eviction or resize reflow.

Browser surfaces use their separate browser attach events rather than terminal render rows.

## 5. Byte Mode For Terminal Piping

Use `mode:"bytes"`, or omit `mode`, when the client is a terminal pipe or deliberately maintains a second terminal emulator. This is the exact protocol-v6 contract: decode the initial `vt-state.data`, replay it into a fresh emulator at `cols` by `rows`, then apply decoded `output.data` bytes in order. On `resized`, replace the emulator from the fresh replay before later output. Apply `colors-changed` metadata and stop at `detached`.

```text
vt-state -> (resized | output | colors-changed | scroll-changed)* -> detached
```

Render mode is preferred for xterm.js-style web UIs and future Swift frontends because it avoids parser drift from the server's Ghostty state, including cursor visuals, resolved colors, dirty rows, and retained scrollback.

## 6. Send Input And Resize

Use [`send-key`](commands.md#send-key) for named keys and terminal-mode-aware encoding. Use [`send`](commands.md#send) for UTF-8 text or raw bytes. For a paste action, set `paste:true`; the server adds bracketed-paste markers only when the target terminal currently has DEC mode 2004 enabled and otherwise sends the payload unchanged.

When the active frontend's geometry changes, convert pixels to cells and call [`resize-surface`](commands.md#resize-surface) with the final `cols` and `rows`. A smaller passive frontend should crop or pan the authoritative grid instead of fighting another client with resize loops. Render and byte clients share one surface size.

## 7. Notifications And Agents

The workspace tree carries per-surface notification state for initial rendering. Subscribed frontends receive `notification` events with a notification subject id and an optional related surface. Show the notification and mark a related surface as needing attention until the user views it.

Call [`list-agents`](commands.md#list-agents) for current agent records. Agent producers use [`report-agent`](commands.md#report-agent); presentation-only frontends display server state rather than inventing a second agent-state model.

## End-To-End WebSocket Transcript

Each line is one WebSocket text frame. `C>` is client-to-server and `S>` is server-to-client. This transcript uses a static or previously issued credential; an interactive client completes pairing first instead.

```text
C> {"auth":{"token":"secret"}}
C> {"id":1,"cmd":"identify"}
S> {"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":9,"session":"main","pid":12345}}
C> {"id":2,"cmd":"subscribe","tree_events":"deltas"}
S> {"id":2,"ok":true,"data":{}}
C> {"id":3,"cmd":"list-workspaces"}
S> {"id":3,"ok":true,"data":{"workspaces":[...]}}
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
