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

## Streaming (Phase 2)

SSE on `GET /v1/surfaces/{id}/stream?mode=raw|cells`. Cells streaming
is a full-snapshot stream (no diff in v1; design §15 #2 deferred to
v2). See Phase 2 docs for `Last-Event-ID` resume semantics and the
seq-jump gap signal.

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
