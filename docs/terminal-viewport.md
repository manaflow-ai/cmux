# Local socket terminal viewports

The local v2 socket can give each connected client its own terminal render
viewport. This is intended for narrow clients such as phones steering many
workspaces at once.

## Set and reset

Send either of these methods on the same long-lived socket connection:

```json
{"id":1,"method":"terminal.viewport.set","params":{"surface_id":"<uuid>","columns":40,"rows":20}}
{"id":2,"method":"terminal.viewport.reset","params":{"surface_id":"<uuid>"}}
```

`columns`/`rows` are cell dimensions. A pixel form is also accepted:
`width`/`height` are positive pixel dimensions and are converted using the
surface's current cell metrics. `terminal.viewport.set` also accepts
`{"reset":true}` as a browser-viewport-style reset. The aliases
`mobile.terminal.viewport.set` and `mobile.terminal.viewport.reset` are
accepted for clients that share the mobile method namespace.

The response reports `mode` (`override` or `native`), effective `columns` and
`rows`, `override`, `pane_resized:false`, `pty_resized:false`, and
`projection:"render_grid"`.

The override is keyed by the accepted socket connection and surface. It is
discarded when that connection closes, so two clients can request different
sizes for one surface without affecting one another. `terminal.replay`,
`terminal.scroll`, and `surface.read_text` on that connection apply the
projection. The local `events.stream` endpoint remains the generic workspace
event stream; it does not replace a render-grid replay. A client that needs a
viewport across multiple requests must keep its control socket open (or send
the raw v2 methods from its own persistent client).

## Resize model

This local override reflows and crops the exported render-grid snapshot at the
connection boundary. It never calls the terminal resize path: the Mac pane,
Ghostty's PTY dimensions, shell wrapping, and other clients remain unchanged.
This is deliberate because a PTY resize is global and would make one phone's
width change every agent's terminal. The projection preserves styles, cursor,
scrollback rows, and producer identity. To keep a narrow viewport from
expanding a large history without bound, at most 16,384 wrapped scrollback
lines are retained; the newest lines win and the visible rows are always
preserved. `surface.read_text` is always projected as plain text. Replay
fallbacks (`snapshot_data_b64` and `data_b64`) are
preserved byte-for-byte because they are VT/control streams; those responses
report `viewport_override:false` when a render-grid frame is unavailable.

## `terminal.render_grid` revisions

`render_grid.render_revision` is a content polling token for one surface,
producer epoch, and row anchor (`viewport` or `screen`). It advances when the
canonical rendered grid, cursor/style state, active screen, retained-history
position, or grid size changes for that anchor. It does not advance for
transport sequence/state metadata, non-visual mode metadata, an unchanged
replay/re-emission, or a replay that merely asks for a different scrollback
depth. This keeps request-specific history budgets from making a polling
client appear dirty. A replay returns the same content revision it re-emits.

`render_grid.emission_revision` is the separate exact-emission identity. It
advances for every emitted frame, including unchanged replays, and is used only
for delta-chain continuity. A delta carries
`delta_base_emission_revision` (and the legacy
`delta_base_render_revision` field for compatibility). Clients polling for
changes should compare `anchor` + `render_epoch` + `render_revision`; clients
validating a delta should compare the emission identity and its base. An epochful
legacy/connection-projected frame with no emission identity cannot establish an
emission-delta baseline; a consumer must request a full replay in that case.
Epochless legacy deltas use the older render-revision/history chain when they
also carry the legacy render base; an epochless emission-only delta is
malformed and is rejected in favor of a full replay.

The content revision advances once per visible rendered batch, not once per raw
PTY chunk. A resize is a content change even when no bytes were received.
