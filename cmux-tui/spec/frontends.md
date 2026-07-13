# Build a cmux-tui Frontend

This is the canonical integration path for an external cmux-tui frontend. A frontend is a protocol client: it connects over Unix JSON-lines or WebSocket text frames, builds UI from the authoritative tree, subscribes to invalidation events, and attaches to terminal surfaces for byte-exact VT streaming. The complete request and result schemas are in [`commands.md`](commands.md); event schemas and ordering are in [`events.md`](events.md).

## 1. Connect

For a local native frontend, connect to the Unix socket described in [`transports.md`](transports.md#unix-socket). Send each JSON request followed by `\n`, and split incoming bytes on `\n`. Ignore blank lines.

For a browser or remote-capable frontend, the server must be started with `--ws <addr>` or `server.ws`. Send one complete JSON request per WebSocket text frame and treat every received text frame as one complete JSON response or event. Do not add newline framing. The TypeScript SDK exposes `WebSocketTransport` for browsers and compatible Node WebSocket implementations.

If the WebSocket listener has a token, its first frame must be the transport preamble below. It is not a command and the server sends no acknowledgement:

```json
{"auth":{"token":"replace-with-a-secret"}}
```

Only after that preamble should the client send protocol requests. See [`transports.md`](transports.md#authentication-preamble) for rejection and bind rules.

## 2. Identify the Server

Send [`identify`](commands.md#identify) immediately after connecting. Verify `data.app == "cmux-tui"` and `data.protocol == 6` before enabling protocol-v6 behavior. Preserve request `id` values and route every non-event response back to the pending request with that id.

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":6,"session":"main","pid":12345}}
```

## 3. Load and Track the Workspace Tree

Call [`list-workspaces`](commands.md#list-workspaces) to load the authoritative workspace, screen, pane, tab, surface, active-selection, notification, and short-id state. Then call [`subscribe`](commands.md#subscribe) on the same connection or on a dedicated connection.

`subscribe` does not send an initial snapshot. It registers its receiver before its success response is written, so an event can race with the response. A robust frontend should:

1. Start `subscribe` and buffer events.
2. Fetch `list-workspaces`.
3. Apply the snapshot.
4. Process buffered invalidations and re-fetch the affected state.

Treat `tree-changed` as an instruction to call `list-workspaces`, `layout-changed` as an instruction to refresh layout/tree data, and surface/title/notification events as invalidations according to [`events.md`](events.md). Responses and events can be interleaved; route a message with `event` as an event and a message without it as a response.

## 4. Attach and Render a Terminal Surface

For a PTY tab, send [`attach-surface`](commands.md#attach-surface) with its numeric surface id. The stream begins with a `vt-state` event containing `cols`, `rows`, and a standard-base64 `data` field. Decode `data` to bytes and feed the VT replay into a fresh terminal emulator, such as xterm.js.

After the replay, apply each base64-decoded `output.data` byte chunk in arrival order. On `resized`, resize the emulator, discard its old parser state, and replace it from the event's fresh base64 replay before applying later output. `scroll-changed` updates viewport state. `detached` ends the surface stream. Protocol v6 guarantees this order:

```text
vt-state -> (resized | output | scroll-changed)* -> detached
```

To send user input, call [`send`](commands.md#send) with `text` for UTF-8 text or `bytes` for standard-base64 raw bytes. For named keys and terminal mode-aware encoding, use [`send-key`](commands.md#send-key). When the frontend's terminal geometry changes, call [`resize-surface`](commands.md#resize-surface) with the final cell `cols` and `rows`; do not resize from pixel dimensions until the frontend has converted them to cells.

Browser surfaces use the browser attach events documented in [`events.md`](events.md) rather than VT replay/output.

## 5. Notifications and Agents

The workspace tree carries per-surface notification state for initial rendering. A subscribed frontend also receives `notification` events with title, body, level, and optional surface. Show the notification and mark the referenced surface as needing attention until the user views it; then use the relevant selection/read path described in [`commands.md`](commands.md).

Call [`list-agents`](commands.md#list-agents) to read current agent records, optionally filtered by surface or state. Agent producers report state through [`report-agent`](commands.md#report-agent); a presentation-only frontend normally reads and displays these records rather than inventing its own agent state. There is no dedicated agent-change event in protocol v6, so re-fetch after a frontend reports state and when tree or surface lifecycle events make the presentation stale.

## End-to-End WebSocket Transcript

Each line below is one WebSocket text frame. `C>` is client-to-server and `S>` is server-to-client. The auth line is present only when `--ws-token` or `server.ws_token` is configured.

```text
C> {"auth":{"token":"secret"}}
C> {"id":1,"cmd":"identify"}
S> {"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":6,"session":"main","pid":12345}}
C> {"id":2,"cmd":"subscribe"}
S> {"id":2,"ok":true,"data":{}}
C> {"id":3,"cmd":"list-workspaces"}
S> {"id":3,"ok":true,"data":{"workspaces":[...]}}
C> {"id":4,"cmd":"attach-surface","surface":1}
S> {"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"G1s/..."}
S> {"id":4,"ok":true,"data":{}}
C> {"id":5,"cmd":"send","surface":1,"text":"echo ready\n"}
S> {"id":5,"ok":true,"data":{}}
S> {"event":"output","surface":1,"data":"ZWNobyByZWFkeQ0K"}
C> {"id":6,"cmd":"resize-surface","surface":1,"cols":120,"rows":36}
S> {"event":"resized","surface":1,"cols":120,"rows":36,"data":"G1s/..."}
S> {"id":6,"ok":true,"data":{}}
S> {"event":"tree-changed"}
```

The event/response ordering shown around streaming commands is intentional: attach events can precede the command response, and subscribe events can race with its response. Never assume request-response alternation once streaming begins.
