# cmux HTTP terminal API (v1)

> Status: ships with cmux v1. Threat acceptance: enabling TCP grants any
> local process holding the bearer token full shell access (RCE). Use the
> UDS transport for stronger isolation. See the design doc §5 for the
> full threat model.

This document covers the v1 read/write surface (one-shot HTTP). Streaming
(SSE) is documented separately under "Streaming (Phase 2)" below.

## Quick start

```bash
# Read the bearer token (created on first launch, mode 0600).
T="$(cat ~/Library/Application\ Support/cmux/http-control-token)"

# List open surfaces.
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:9778/v1/surfaces

# Read the viewport as cells.
curl -s -H "Authorization: Bearer $T" \
  "http://127.0.0.1:9778/v1/surfaces/surface:1/screen?format=cells&region=viewport"

# Run `ls` in the surface (text + Enter).
curl -s -X POST -H "Authorization: Bearer $T" \
  -d '{"type":"text","text":"ls","submit":true}' \
  http://127.0.0.1:9778/v1/surfaces/surface:1/input
```

## Auth

All requests require `Authorization: Bearer <token>`. The token is
generated on first launch under
`~/Library/Application Support/cmux/http-control-token` (mode 0600).
Rotate from Settings → HTTP Control. Rotation closes existing
connections so an old token cannot keep talking.

The token is **never** injected into child terminal environments
(see design §5.2). A spawned shell does not see `CMUX_HTTP_TOKEN`,
`HTTP_CONTROL_TOKEN`, or any other env var derived from the token.

The bearer token check is constant-time. Bearer parsing accepts the
exact form `Bearer <value>` only; case differences (`bearer`, `BEARER`)
or extra whitespace are rejected.

SSE streaming requires a fetch-streaming client that can set the
`Authorization` header (the browser's `EventSource` cannot). See
`/stream` docs in Phase 2.

## Host allowlist

Loopback only: `Host` must be `127.0.0.1:<port>` or `localhost:<port>`.
`Origin`, if present, must point at the same loopback. Other values
produce HTTP 403 with `code: "forbidden"`. The check defeats DNS
rebinding from a browser that resolves an attacker-controlled name to
`127.0.0.1`.

UDS clients send `Host: localhost:0` (or `127.0.0.1:0`); the
file-permission check on the socket (mode 0600) replaces the loopback
guarantee.

## Endpoints

### `GET /v1/surfaces`

Returns the list of open surfaces:

```json
{
  "surfaces": [
    {
      "handle": "surface:1",
      "uuid": "9D1A...",
      "workspace": "workspace:1",
      "title": "zsh",
      "cols": 120,
      "rows": 36,
      "alt_screen": false,
      "focused": true,
      "semantic_available": true
    }
  ]
}
```

Use `handle` (e.g. `surface:1`) as the path segment in subsequent calls.

### `GET /v1/surfaces/{id}/screen`

Query:

| Param    | Values                              | Default    |
| -------- | ----------------------------------- | ---------- |
| `format` | `text` \| `cells`                   | `text`     |
| `region` | `viewport` \| `screen` \| `scrollback` | `viewport` |
| `wrap`   | `preserve` \| `join`                | `preserve` |
| `trim`   | `true` \| `false`                   | `true`     |

`format=raw` is **rejected with HTTP 400** on this endpoint — raw
bytes are streaming-only (`GET /v1/surfaces/{id}/stream?mode=raw` in
Phase 2). See D29 in the design doc.

- **`format=text`**: returns `{ cols, rows, alt_screen, title, text }`.
  `text` is the rendered Unicode content of the requested region with
  no escape sequences.
- **`format=cells`**: returns the full ``CellGrid`` (`cols`, `rows`,
  `rows_data`, `cursor`, `region`, `alt_screen`, `semantic_available`,
  `hyperlink_uris`). Per-cell payload covers:
  - `t` — Unicode text for the cell (one grapheme cluster).
  - `fg` / `bg` — foreground/background colors as
    `{ "kind": "default"|"palette"|"truecolor", ... }`.
  - `attrs` — bitset of bold/italic/blink/reverse/strikethrough
    flags.
  - `underline.kind` — `none | single | double | dotted | dashed |
    curly`. `underline.color` is encoded under the same color shape
    as `fg`/`bg` (D25).
  - `wide` — `narrow | wide | spacer_tail | spacer_head`. Consumers
    MUST handle all four to render correctly at soft-wrap seams with
    CJK content.
  - `hyperlink` — index into the row's `hyperlink_uris` table when
    the cell sits under an OSC 8 hyperlink (D26). `null` otherwise.
  - `semantic` — OSC 133 segment annotation (`prompt | input | output`).
    Today cmux's shell-integration injection runs **only for zsh**
    (`cmux-zsh-integration.zsh`); `bash` / `fish` users see
    `semantic_available: false` and per-cell `semantic: null` (D27).
- **`wrap=join`** fuses adjacent rows whose per-row `wrap` /
  `wrap_continuation` flags are set, restoring logical-line text
  without column-width guessing (E19).
- **Out of scope (D28)**: Sixel, DCS, and Kitty graphics escape
  sequences are NOT decoded. In `cells`, image runs render as their
  containing cells with no image data. In `mode=raw` streaming
  (Phase 2) they pass through as opaque bytes.

### `POST /v1/surfaces/{id}/input`

Body: JSON object with `type` ∈ `{ text, keys, paste, raw, mouse, focus }`,
optional `focus: true` to give the surface keyboard focus before writing
(D17 — calls `setFocus(surface:gained: true)` synchronously, then writes).

- **`type=text`**: writes the literal UTF-8 in `text`. With
  `submit: true`, appends `\r` (NOT `\n`). To execute a command,
  ALWAYS use `submit: true` or send `keys: ["Enter"]` — embedding
  `\n` in `text` will not execute and produces garbage under shells
  with bracketed-paste enabled.
- **`type=paste`**: atomically wraps the payload in bracketed-paste
  markers when the surface has DEC 2004 active. Per spec §8.1
  ghostty's paste encoder unconditionally strips `0x1B` bytes from
  the payload, so embedded `ESC[201~` cannot escape the bracketed
  block (D15). cmux's per-surface serial actor (D30) prevents
  concurrent paste calls from interleaving.
- **`type=keys`**: semantic key events. `keys` is an array of strings
  in the form `"Mod+Mod+Key"` where Mod ∈ `Ctrl | Alt | Shift | Cmd`
  and Key is a single character or a named key (`Enter`, `Tab`,
  `Escape`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`,
  `PageDown`, `Space`, `Backspace`, `Delete`, `F1`..`F24`). ghostty
  encodes the bytes using the surface's active keyboard mode
  (DECCKM / kitty / modifyOtherKeys) automatically — no client-side
  mode tracking needed.
- **`type=raw`**: writes arbitrary bytes (base64-encoded). DISABLED
  by default in Settings; toggle "Allow type=raw input" to enable.
  Per spec §8.3 this allows OSC 52 clipboard ops and DSR / DECRQSS
  terminal queries whose replies are injected into stdin
  (reflection-injection risk). Without the gate, the route returns
  HTTP 403.
- **`type=mouse`**: writes a mouse event directly to ghostty
  (`ghostty_surface_mouse_*`), NOT via AppKit hit-test (D16). Fields:
  `action ∈ press | release | move | scroll`, `button ∈ left | middle | right`,
  `x`, `y`, `mods`, `scroll_dy`. Hit-test latency on the unrelated
  portal layer is unaffected.
- **`type=focus`**: writes a focus-change event to the surface; does
  NOT change macOS app focus. Use this when an automation flow needs
  ghostty to think the surface is/was focused without bringing the
  cmux window to the foreground.

Every write goes through a per-surface serial actor (D30) so the
HTTP layer cannot interleave fragments from two concurrent callers.
Backpressure: `pendingInputCapacityRemaining(surface:)` is exposed
on the in-process API; over-cap requests return HTTP 413.

### Error model

| HTTP | code                   | When                                              |
| ---- | ---------------------- | ------------------------------------------------- |
| 400  | bad_request            | Invalid params, `format=raw` on `/screen` (D29)   |
| 401  | unauthorized           | Missing / invalid Bearer                          |
| 403  | forbidden              | Host/Origin/type=raw blocked                      |
| 404  | not_found              | Unknown surface OR feature disabled (D11)         |
| 405  | method_not_allowed     | Path matches, method does not (Allow header set)  |
| 413  | payload_too_large      | Body > 1 MiB                                      |
| 415  | unsupported_media_type | `TerminalAccessError.unsupported` (D18)           |
| 429  | too_many_requests      | Per-surface write rate limit                      |
| 500  | internal_error         | Ghostty / unexpected                              |

Body shape: `{ "error": { "code": "...", "message": "..." } }`.
Per D11 a disabled endpoint returns `404 not_found` (NOT a distinctive
`featureDisabled` code) so a probe cannot tell whether the route is
toggled off or simply does not exist.

## Audit log

Every write goes into a JSONL audit log (D4 — always on). Default path:
`~/Library/Application Support/cmux/http-control-audit.jsonl`. Each
entry includes timestamp, surface handle, action kind, byte count, and
the request id used to correlate with the HTTP listener log. The path
is configurable in Settings → HTTP Control.

## Streaming: `GET /v1/surfaces/{id}/stream`

Server-Sent Events. Two modes:

| `?mode=` | Frame                                                                                |
|----------|--------------------------------------------------------------------------------------|
| `raw`    | `event: output` with `data: {"bytes_base64":"..."}` (live PTY bytes)                 |
| `cells`  | `event: screen` with `data: <CellGrid JSON>` (full snapshots; v1 has no diff stream) |

> Status: `mode=cells` is wired end-to-end. `mode=raw` is gated behind
> the upcoming ghostty PTY-tee patch (see design §15 #1) and currently
> returns HTTP 415 `unsupported_media_type` with reason
> `raw_stream_unavailable`.

### Authentication

Requires `Authorization: Bearer <token>`. The browser's native
`EventSource` does NOT support custom headers, so you cannot use it.
Use `fetch` with a streaming `ReadableStream`:

```js
async function subscribe(surfaceId, token, port, onEvent) {
  const res = await fetch(
    `http://127.0.0.1:${port}/v1/surfaces/${surfaceId}/stream?mode=cells`,
    { headers: {
        'Authorization': `Bearer ${token}`,
        'Last-Event-ID': sessionStorage.getItem('cmux.lastId') ?? '',
      } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const reader = res.body.getReader();
  const dec = new TextDecoder('utf-8');
  let buf = '';
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf('\n\n')) !== -1) {
      const frame = buf.slice(0, idx); buf = buf.slice(idx + 2);
      if (frame.startsWith(': ')) continue;   // heartbeat or gap comment
      let id, event = 'message', data = '';
      for (const line of frame.split('\n')) {
        if (line.startsWith('id: '))         id    = Number(line.slice(4));
        else if (line.startsWith('event: ')) event = line.slice(7);
        else if (line.startsWith('data: '))  data  = line.slice(6);
      }
      if (id !== undefined) sessionStorage.setItem('cmux.lastId', String(id));
      onEvent({ id, event, data: data ? JSON.parse(data) : null });
      if (event === 'end') return;
    }
  }
}
```

### Frame shapes

```
id: 42
event: output
data: {"bytes_base64":"aGVsbG8="}

id: 7
event: screen
data: { "format":"cells", "cols":80, "rows":24, "alt_screen":false,
        "title":"zsh", "cursor":{...}, "rows_data":[...] }

event: end
data: {}

: ping

: gap from=100 to=256
```

### Backpressure (§9.1)

The PTY tee that feeds `mode=raw` runs under Ghostty's renderer lock on
the io-reader thread. The server:

- never blocks the producer; the per-subscriber **event** ring is
  bounded (default 1024 events for raw, 256 for cells)
- drops oldest events on overflow; the next event's `id:` JUMPS,
  which is the signal that data was dropped (clients should re-fetch
  `GET /screen?format=cells` to resync)
- writes to the network on a separate dispatch queue
- emits a `: ping` heartbeat every 20s (configurable) so dead peers
  are detected
- caps concurrent streams per surface (default 8; extras get HTTP 503)

`mode=cells` is throttled by a server-side snapshot poller (default
5 Hz, configurable) that only emits when the cell grid's content
digest changes — idle surfaces produce zero traffic between
heartbeats.

### Resuming with `Last-Event-ID`

Send the last id you saw in the `Last-Event-ID` header. If the
requested id is still in the ring you resume from the next event. If
the requested id is below the ring's oldest, the server emits one
comment line `: gap from=<requested> to=<oldest>` and resumes from the
ring's oldest event. There is **no** separate `event: gap` frame in
v1 — the `id:` JUMP (or the synthetic comment on resume) is the only
gap signal.

### Stream end

When the underlying surface closes (or the token rotates), the server
sends `event: end` and closes the connection cleanly. Treat this as a
permanent terminal signal — do not auto-reconnect without rechecking
the token.

### Out of scope for v1

- Sixel / DCS / Kitty-image protocol: `mode=raw` carries these as
  opaque bytes (the bracketed sequences are part of the byte stream);
  `mode=cells` silently drops them (a CellGrid snapshot has no image
  cells in v1). See spec §15 for the v2 plan.
- Cell-level diff streaming: v1 only ships full snapshots throttled
  via the time-tick poller (see spec §9.1 / §15 open question).
- Live "dirty notifier" push from ghostty: v1 polls at a configurable
  tick rate and hashes the cell grid; a true push notifier may land
  in v2 (would require a third ghostty patch we did not authorize).

## Configuration

In addition to Settings → HTTP Control, the listener can be configured
from `cmux.json` under the `httpControl` block:

```jsonc
{
  "httpControl": {
    "enabled": true,
    "transport": "uds",
    "udsPath": "/tmp/cmux-http.sock",
    "tcpPort": 9778,
    "allowRawInput": false,
    "auditLogPath": "/Users/you/Library/Logs/cmux-http.jsonl"
  }
}
```

Schema: `web/data/cmux.schema.json` → `httpControl`. The values are
applied at app launch; rotating the token from Settings restarts the
listener so existing connections drop.
