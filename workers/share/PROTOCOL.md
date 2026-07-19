# cmux share protocol (v1)

One Durable Object instance per share session, keyed by an unguessable share
code. The host Mac holds one WebSocket to the DO; each guest browser holds one.
The DO fans out host->guest streams, relays guest->host input, and owns session
state: participants, roles, cursors, chat history.

Trust model: the DO is transport plus session bookkeeping. The host app is the
only authority for input. Every guest input message is re-validated on the host
against the sender's role and the shared-surface set; the DO also drops
messages from `viewer`-role guests early as a bandwidth courtesy, but that
check is not load-bearing.

## Connection

Both roles connect to
`wss://<worker>/v1/share/sessions/<code>/ws?token=<share JWT>` (native clients
may send `Authorization: Bearer` instead of the query param). The token is a
short-TTL Ed25519 JWT minted by the web API (`services/share/token.ts`,
mirroring the iroh relay token system): `iss=cmux`, `aud=cmux-share`,
`sub=<stack user id>`, `email`, `code=<share code>`, and `host=true` only on
tokens minted by the session-create endpoint. The worker verifies offline with
the public key, then forwards the upgrade to the session DO with the verified
identity in `x-share-*` headers; the token never reaches the DO. The DO id is
derived from the verified `code` claim, so a token can only ever reach its own
session's object. The session is created when the host's first connection
arrives; a guest connecting to a code with no session gets 404.

Sessions die when the host explicitly stops or has been disconnected for the
grace period (120 s, DO alarm). A dead session's code is permanently invalid.

## Roles

`editor` | `viewer`. Approval decisions are keyed by Stack user id and
remembered for the life of the session only. `deny` blocks that user id from
re-requesting for the rest of the session.

## Envelope

All messages are JSON text frames except grid/pixel payloads, which are binary
frames prefixed with a 1-byte kind tag (see Binary frames). JSON envelope:

```json
{ "t": "<type>", ... }
```

### Guest -> DO

- `hello` `{t, proto: 1}` — sent after connect; DO replies `session-state` or
  `access-pending` / `access-denied`.
- `cursor` `{t, ws, pane, x, y}` — pane-relative normalized coords; absent
  pane means cursor left the shared area (broadcast as cursor-hide).
- `chat` `{t, text, bubble: {ws, pane, x, y}?}` — bubble anchor optional.
- `input` `{t, ws, pane, data}` — key/text input for a terminal surface
  (editor role only; relayed to host, never stored).
- `compose` `{t, field, rev, ops: [...]}` — multiplayer textbox ops
  (slice 2; host-authoritative rebase).
- `sub` / `unsub` `{t, ws, pane}` — subscribe to a surface stream.
- `focus` `{t, ws}` — which workspace this guest is viewing (drives sidebar
  presence dots and per-workspace cursor scoping).
- `follow` `{t, user: <id|null>}` — follow mode; DO echoes viewport of the
  followed participant.

### Host -> DO

- `hello` `{t, proto: 1, shared: {workspaces: [...]}}` — declares the shared
  workspace set and initial layout snapshots.
- `layout` `{t, ws, tree}` — pane-tree snapshot for a workspace (sent on
  change; tree mirrors the bonsplit layout with pane ids, kinds, sizes).
- `approve` `{t, user, role}` / `deny` `{t, user}` / `kick` `{t, user}` /
  `role` `{t, user, role}` — moderation, initiated from host chat UI.
- `cursor`, `chat` — same shape as guest.
- `compose-state` `{t, field, rev, text, carets: [...]}` — authoritative
  composer state (slice 2).
- `end` `{t}` — host stopped sharing.

### DO -> all (fan-out)

- `session-state` `{t, shared, participants: [{user, email, role, color,
  focusWs}], chat: [...], you: {...}}` — full snapshot on join/approval.
- `presence` `{t, join|leave|role|focus updates}`
- `access-request` `{t, user, email}` — host UI renders approve/deny in chat.
- `cursor` `{t, user, ws, pane, x, y}` — not persisted; last-write-wins.
- `chat` `{t, user, text, bubble?, ts}` — appended to DO storage (session
  lifetime only).
- `session-ended` `{t, reason: "host-stopped" | "host-gone"}`

## Binary frames

First byte is a kind tag; remainder is the payload. Grid frames reuse the
existing cmux render-grid encoding (same bytes the iOS mirror consumes) so the
host does not re-encode per consumer:

- `0x01` grid frame: `[0x01][u32 ws][u32 pane][render-grid payload]`
- `0x02` pixel/video frame (slice 2): `[0x02][u32 ws][u32 pane][codec tag]
  [payload]` — H.264 (VideoToolbox) primary, WebP still fallback.

The DO forwards binary frames to guests subscribed to `(ws, pane)` without
parsing beyond the header.

## Ordering, pacing, hibernation

The DO forwards frames without buffering or dropping; pacing lives at the
edges. The host coalesces grid deltas per runloop hop (the existing
render-grid emission machinery) and caps pixel-frame rate; clients throttle
their own cursor sends (~30 Hz). Grid deltas depend on continuity, so any
consumer that may have missed frames must be given a full frame; the host
re-sends full frames whenever `guest-sub` reports a new subscriber.

The DO uses the WebSocket hibernation API. If it is evicted and rebuilt while
sockets are open, volatile per-connection state (subs, focus, follow) is lost:
on wake every surviving client gets a fresh `session-state` plus `resync`,
guests re-send `focus`/`sub`s/cursor, and the host re-sends `hello` and full
grid frames.
