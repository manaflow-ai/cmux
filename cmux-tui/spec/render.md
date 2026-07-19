# Render-Mode Attach Contract

Protocol v7 adds a server-rendered attach mode for rich frontends. The server remains the only terminal emulator: clients draw styled runs, place the cursor, and send input. Protocol v6 byte attach remains unchanged and is still the default.

The schema notation and common types in [`commands.md`](commands.md#notation) apply here.

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 7 |
| attach command | `attach-surface` with `mode:"render"` |

## Version And Mode Selection

`attach-surface.mode` is `"bytes"|"render"` and defaults to `"bytes"`. Omitting it has the exact protocol-v6 behavior: `vt-state`, followed by byte/replay attach events, followed by `detached`. All protocol-v6 commands, fields, event payloads, and ordering guarantees remain available to clients that omit `mode`.

A client must call `identify` and require `protocol >= 7` before sending `mode:"render"`. It may fall back to byte mode on protocol 6. A server must reject `mode:"render"` when it does not implement protocol 7; clients must not probe by sending the field to an older server.

Render mode applies only to PTY surfaces. Browser surfaces retain their separate browser attach path.

## Stream Ordering

A render attach stream is ordered as:

```text
render-state -> (render-delta | scroll-changed)* -> detached
```

The server captures the initial `render-state` snapshot and registers the live render tap while holding the same terminal lock. There is no terminal mutation between those operations, so the initial state and later deltas have no gap and no duplicated frame. The initial event may precede the `attach-surface` command response, as in byte mode.

For one surface, events are applied in transport order. `detached` is terminal for that surface's attach stream. Clients must discard later events for that attachment if transport buffering delivers any after `detached`.

On reconnect, re-attach and rebuild from the fresh `render-state`; discard cached scrollback pages.

Implementation note: ghostty-vt damage is consume-once because `walk_rows` clears the dirty flags. A server driving its local TUI plus any number of render attachments must build each frame once and fan that shared frame out to all consumers. Deltas are per-consumer only in delivery; damage computation is shared, not repeated per consumer.

## Shared Render Types

`Cursor`:

```text
object{
  x:uint16,
  y:uint16,
  style:"block"|"underline"|"bar",
  blink:boolean,
  visible:boolean,
  color:ColorHex|null
}
```

`x` and `y` are zero-based viewport coordinates. When `visible` is false because the terminal hid the cursor or the cursor is outside a scrolled viewport, clients must not draw it and must ignore `x` and `y`; the server sends `0` for a coordinate the engine does not expose. `style` and `blink` still report `cursor_visual`. `color` is the effective OSC 12 cursor color after server resolution, or `null` when the terminal has no explicit cursor color and the client should use its normal default-cursor treatment.

`Row`:

```text
object{row:uint16,runs:array<Run>}
```

`row` is zero-based within the containing viewport or `read-scrollback` page. Viewport rows are in `0..size.rows`. Runs are ordered left to right.

`Run`:

```text
object{
  text:string,
  fg:ColorHex|null,
  bg:ColorHex|null,
  attrs:uint16,
  underline?:"single"|"double"|"curly"|"dotted"|"dashed",
  width_hint?:uint16
}
```

`text` is plain UTF-8, never base64. Blank cells are represented as spaces. `fg` and `bg` are server-resolved RGB values: palette indexes and OSC palette overrides have already been applied. `null` means the corresponding `default_fg` or `default_bg`. `inverse` remains an attribute; clients swap the resolved foreground/background channels when drawing it.

Runs are maximal adjacent cell spans with the same `fg`, `bg`, `attrs`, and `underline`. An absent `underline` means no underline. `width_hint`, when present, is the number of terminal grid columns covered by the run and is authoritative over client Unicode-width calculations. The server includes it when a wide grapheme or spacer makes `text` width ambiguous. The total run width of a viewport row must equal `size.cols`.

`attrs` bits:

| Bit | Hex | Meaning |
| --- | --- | --- |
| 0 | `0x0001` | bold |
| 1 | `0x0002` | italic |
| 2 | `0x0004` | strikethrough |
| 3 | `0x0008` | inverse |
| 4 | `0x0010` | dim/faint |
| 5 | `0x0020` | invisible |
| 6 | `0x0040` | blink |
| 7-15 | `0xff80` | reserved; servers send zero and clients ignore |

`attrs` contains boolean attributes only. Unknown future bits must be ignored.

## render-state

| Field | Value |
| --- | --- |
| event | `render-state` |
| stream | render attach only |
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

`rows` is a complete snapshot of the current viewport and contains exactly `size.rows` entries. This draft uses `size.rows` for the numeric height because a JSON object cannot also use `rows` as the row-array key. `scrollback_rows` is the current number of retained rows above the live screen; the initial event does not inline scrollback.

Example:

```json
{"event":"render-state","surface":1,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#d8d9da","default_bg":"#131415","scrollback_rows":42,"rows":[{"row":0,"runs":[{"text":"$ ","fg":null,"bg":null,"attrs":0},{"text":"x","fg":"#ff0000","bg":null,"attrs":1}]}]}
```

## render-delta

| Field | Value |
| --- | --- |
| event | `render-delta` |
| stream | render attach only |
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

The cursor is always present, including cursor-only frames where `rows` is empty. With `full:false`, `rows` contains only dirty viewport rows and clients replace those rows by `Row.row`. Multiple engine mutations are coalesced into at most one delta per server render frame; clients must not infer PTY write boundaries from deltas.

`size` is present if and only if the surface resized. A resize always sends `full:true` and every viewport row at the new size. This full replacement is required because Ghostty may reflow content and invalidate every old row index. `full:true` may also be used without `size` when a palette/default-color change or engine full-damage state requires a complete repaint.

When `full:true`, `rows` contains exactly the complete current viewport. Optional `default_fg` and `default_bg` are present only when that default changed. `scrollback_rows` is present only when the count changed. Runs still carry resolved RGB, so any palette change that affects visible cells must dirty those rows or cause a full delta.

`scroll-changed` carries viewport offset/at-bottom metadata; it does not carry cells and does not replace a delta. If scrolling changes visible content, the render stream also supplies the resulting dirty or full rows in an ordered `render-delta`. The two events need not be adjacent because frame coalescing may include other terminal mutations.

## Scrollback

`read-scrollback` returns styled retained rows without moving the shared viewport. Its complete command schema and CLI mapping are in [`commands.md`](commands.md#read-scrollback).

`start` indexes the oldest row currently retained as zero. In a response, `Row.row` is relative to the returned page and the current absolute index is `start + Row.row`.

The inclusive `count` bound is `0 <= count <= 65,535`.

This keeps the relative row index representable as `uint16`.

Scrollback indexes are snapshots, not durable row ids. When the retention limit evicts `n` old rows, every surviving row's index decreases by `n`; `total` may grow, shrink, or stay constant. A clear operation can also reduce it. Each request is captured under the terminal lock and returns one internally consistent `start`, `rows`, and `total`, but separate requests do not form a transaction.

Resize reflow is owned by Ghostty. A resize may rewrap retained content, change row boundaries and `total`, and invalidate a prior `start`. The protocol promises the engine's retained rows as they exist when the request is captured; it does not promise stable logical-line identity or byte-for-byte row boundaries across sizes.

## Sizing And Multi-Client Presentation

Render mode uses the same single authoritative surface grid and smallest-client sizing rules as byte mode. See [`commands.md`](commands.md#sizing) for creation defaults, clamps, and the exact mutation rule.

A frontend may include paired `cols` and `rows` in `attach-surface` only after `identify.capabilities` includes `attach-initial-size`. The pair records its initial visible-size claim before the server captures `render-state`. After attachment, it sends `resize-surface` only after an actual local cell-grid change. It sends `release-surface-size` when the surface becomes hidden, while retaining the attach stream if it wants a warm cache. The server independently takes the minimum reported columns and rows across visible viewers. Larger frontends render the smaller authoritative grid with unused surrounding space. A render-size event from another client does not invalidate the frontend's last local report, so input and passive rendering cannot cause a resize feedback loop.

## Input

Input commands are unchanged. Use `send-key` for named, terminal-mode-aware keys; use `send` for UTF-8 or raw bytes; and use `resize-surface` for cell-grid changes. `send` with `paste:true` requests bracketed-paste wrapping only when the authoritative terminal currently has DEC private mode 2004 enabled. See [`commands.md`](commands.md#send).

## Open questions (v7 draft)

Only two engine-work questions remain:

3. The current wrapper exposes wide grapheme heads followed by empty cells but no explicit spacer discriminator. Confirm that the lower-level cell metadata can produce logical `text` plus an authoritative `width_hint` without confusing wide spacers with blank cells.
4. The wrapper exposes styled cells only for the viewport; scrollback count and plain text are available, but non-mutating styled random access is not. `read-scrollback` requires a wrapper/engine API that does not move the shared viewport or consume its damage flags.

Resolved v7 decisions: `size:{cols,rows}` is adopted, following the existing `Tab.size` precedent; exact underline style uses the optional `Run.underline` enum while `attrs` remains boolean-only; `BlockHollow` maps to wire style `"block"` because hollow rendering is a presentation concern and has no wire style; and the legacy subscribe delivery of `scroll-changed` remains the documented compatibility exception rather than forcing a renamed event.
