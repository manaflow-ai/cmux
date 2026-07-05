# Control Socket Protocol

As of protocol v6, every server speaks JSON Lines over a Unix domain socket. Send one JSON object per line. Every request receives one response line. `subscribe` and `attach-surface` also push event lines on the same connection.

Default socket path:

```text
$TMPDIR/cmux-mux-<uid>/<session>.sock
```

`identify` reports the protocol version:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-mux","version":"...","protocol":6,"session":"main","pid":12345}}
```

Responses have this shape:

```json
{"id":1,"ok":true,"data":{}}
{"id":2,"ok":false,"error":"unknown surface 99"}
```

Bad JSON returns `ok:false` with no request id.

## Command Contract

The full API contract is intended to live in `mux/spec/`, but that directory is not present in this checkout. Until it lands, `mux-core/src/server.rs` is the command source of truth.

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
focus-pane
select-tab
select-screen
select-workspace
subscribe
attach-surface
scroll-surface
```

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
{"event":"surface-resized","surface":4,"cols":120,"rows":40}
{"event":"surface-exited","surface":4}
{"event":"title-changed","surface":4}
{"event":"bell","surface":4}
{"event":"tree-changed"}
{"event":"empty"}
```

`surface-resized` reports the final clamped cell size and is emitted only when the surface size actually changes.

## Attach Surface

`attach-surface` streams a PTY surface. Browser surfaces return `browser panes are not supported over attach yet`.

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
{"event":"resized","surface":4,"cols":132,"rows":43,"data":"<base64-vt-replay>"}
```

The `resized` attach frame carries the new cell size and a fresh VT replay captured at that size. It is delivered in the same attach stream as output frames, so a client can reset its local terminal, apply the replay, and continue consuming later output in order.

When the stream ends, it sends:

```json
{"event":"detached","surface":4}
```

## Client Compatibility

The remote TUI requires protocol v6. It refuses servers reporting any other protocol version because attach streams need resize markers carrying replay data.

Attach clients mirror PTY surfaces locally. On first render, a client can resize the server surface before requesting `attach-surface`, so the initial VT replay is captured at the visible geometry.

When several attach clients render the same surface at different sizes, sizing follows latest local interaction. A client reasserts its visible sizes after key input, mouse input, paste, focus gained, or terminal resize. Mux-driven redraws update local mirrors from `surface-resized` without reasserting an idle client's viewport.

## Browser Limitations

Browser surfaces appear in `list-workspaces` as `kind: "browser"` with `browser_source: "external"` or `"launched"`. PTY and VT commands against browser surfaces return errors. `attach-surface` does not stream browser pixels as of protocol v6, and the remote TUI shows a placeholder for browser panes.
