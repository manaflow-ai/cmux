# Control Socket Protocol

As of protocol v9, every server speaks JSON Lines over a Unix domain socket. Send one JSON object per line. Every request receives one response line. `subscribe` and `attach-surface` also push event lines on the same connection.

For shell use, prefer `cmux-tui <verb>`; it wraps the same socket commands and preserves JSON output with `--json`.

Default socket path:

```text
$TMPDIR/cmux-tui-<uid>/<session>.sock
```

`identify` reports the protocol version:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"...","protocol":9,"capabilities":["attach-initial-size","workspace-registry-v1"],"session":"main","pid":12345}}
```

Responses have this shape:

```json
{"id":1,"ok":true,"data":{}}
{"id":2,"ok":false,"error":"unknown surface 99"}
```

Bad JSON returns `ok:false` with no request id.

## Command Contract

The full API contract lives in [`../spec/commands.md`](../spec/commands.md). `cmux-tui-core/src/server.rs` is the implementation source of truth.

The server command set in this branch is:

```text
identify
list-workspaces
send
read-screen
vt-state
new-tab
new-browser-tab
new-workspace
new-screen
new-pane
split
set-ratio
set-split-ratio
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
attach-surface
scroll-surface
```

`move-tab` moves a surface to a target pane and insertion index. It supports same-pane reorder and cross-pane moves.

```json
{"id":10,"cmd":"move-tab","surface":4,"pane":2,"index":0}
```

`move-workspace` moves a workspace to a zero-based insertion index. When moving
right, the final index is one less than the requested insertion index because
the source workspace is removed first.

```json
{"id":11,"cmd":"move-workspace","workspace":3,"index":0}
```

Protocol-v8 split nodes serialize as `{type:"split",split:<id>,dir,ratio,a,b}`. The `split` value remains stable until that node collapses. Resize an exact divider with:

```json
{"id":12,"cmd":"set-split-ratio","split":9,"ratio":0.65}
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

Protocol v7 and newer `title-changed` events carry the authoritative current `title`. Slow subscribers coalesce repeated pending title changes per surface to the latest value.

Browser input, navigation, activation, and browser reconfigure work from `resize-surface` enqueue per-surface CDP work. Protocol v7 and newer `resize-surface` responses include `data.accepted` and `data.reservation_id`; `true` means the resize was applied or queued, and `false` means it was already satisfied, pending, or waiting for its retry backoff. Completion arrives as `surface-resized`, and asynchronous failure arrives as `surface-resize-failed`. Two consecutive CDP call timeouts mark only that browser surface failed with `browser is not responding`.

## Attach Surface

`attach-surface` streams a PTY or browser surface.

```json
{"id":30,"cmd":"attach-surface","surface":4,"cols":120,"rows":40}
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

For browser surfaces, the server first sends `browser-state` with URL, title, size, status, stalled-frame state, and the latest PNG frame if one exists. Later updates send `browser-state` and `frame` events. Frame payloads are base64 PNG data and slow clients skip older frames rather than buffering unboundedly.

When the stream ends, it sends:

```json
{"event":"detached","surface":4}
```

## Client Compatibility

The remote TUI requires protocol v9. It rejects protocol-v8 servers before loading their workspace tree because v8 does not define stack layout nodes or `new-pane`.

Existing `set-ratio` clients remain source-compatible and the server keeps the pane-and-direction command unchanged. Protocol-v8 and newer frontends should read `layout.split` and send `set-split-ratio` so nested same-direction dividers are addressed exactly. Protocol v9 adds stack layout nodes and `new-pane`; clients must not send `new-pane` to a protocol-v8 server.

Attach clients mirror PTY surfaces locally. After `identify` advertises `attach-initial-size`, a client can include paired `cols` and `rows` in `attach-surface`, so the server records its initial size claim before capturing the first VT replay or render state. Older servers that omit the capability must receive neither field.

When several attach clients render the same surface at different sizes, sizing follows latest local interaction. A client reasserts its visible sizes after key input, mouse input, paste, focus gained, or terminal resize. Mux-driven redraws update local mirrors from `surface-resized` without reasserting an idle client's viewport.

## Browser Limitations

Browser surfaces appear in `list-workspaces` as `kind: "browser"` with `browser_source: "external"` or `"launched"` once live, plus additive `browser_status`, `browser_error`, and `browser_frames_stalled` fields. PTY and VT commands against browser surfaces return errors.
