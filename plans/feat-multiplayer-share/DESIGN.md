# Multiplayer workspace share (cmux.com/share/&lt;id&gt;)

A host Mac shares one workspace read-only to authenticated web viewers. Everyone
sees everyone's cursor (colored kite pointers), can cursor-chat Figma-style, and
messages also collect in a floating chat panel. Transport hub is a Cloudflare
Durable Object (GPL-3.0-or-later, `workers/share/`).

## Topology

```
cmux macOS host ── wss ──► ShareSession DO ◄── wss ── web viewer(s) at cmux.com/share/<id>
```

- One `ShareSession` Durable Object per share id (`idFromName(shareId)`).
- Host authenticates with a per-session `hostToken` returned by create.
- Viewers authenticate with a Stack access token; the worker verifies it
  (same pattern as `workers/presence/src/auth.ts`) and passes verified
  identity headers to the DO. The DO never sees unauthenticated input.
- Viewer admission requires explicit host approval per user (allow/deny).

## HTTP surface (worker)

- `POST /v1/share/create` — Stack bearer auth. Body `{ title? }`. Returns
  `{ shareId, hostToken, url }`. `shareId` is 22 chars base62.
- `GET /v1/share/:id/host?token=<hostToken>` — WebSocket upgrade, host lane.
- `GET /v1/share/:id/ws?access_token=<stack access token>` — WebSocket
  upgrade, viewer lane (query param because browsers cannot set WS headers).
- `GET /healthz` — liveness.

## WebSocket messages (JSON, one object per frame)

Participant = `{ id, email, name, color, role: "host"|"viewer" }`. The DO
assigns `id` and `color` (index into a fixed palette; host is always color 0).

Viewer lifecycle:
- DO→viewer `{ type: "join_state", state: "pending"|"approved"|"denied" }`
- DO→host `{ type: "join_request", requestId, email, name }`
- host→DO `{ type: "join_response", requestId, allow: bool }`
  Approval is remembered per user id for the life of the session.

Sync (targeted; DO stores no terminal data):
- DO→host `{ type: "sync_request", participantId }` when a viewer is approved
- host→DO `{ type: "snapshot", to: participantId, workspace: Workspace }`
  forwarded only to that viewer.

Live stream, host→DO, broadcast to approved viewers:
- `{ type: "layout", workspace: Workspace }` on any pane/layout change
- `{ type: "term", surfaceId, seq, data_b64 }` raw PTY output chunk
- `{ type: "term_resize", surfaceId, cols, rows }`
- `{ type: "textbox", paneId, text, selStart, selEnd, active }` host textbox mirror

Presence, any→DO, broadcast to everyone including host:
- `{ type: "cursor", x, y }` — normalized [0,1] workspace coordinates; DO
  stamps `participantId` and rebroadcasts (rate limited to 30/s per sender)
- `{ type: "chat", text, x, y }` — cursor-chat bubble + floating panel entry;
  DO stamps `participantId`, `ts`, keeps the last 200 in DO storage and
  replays them to newly approved viewers
- DO→all `{ type: "presence", participants: [Participant] }` on any change

### Workspace shape

```jsonc
{
  "title": "issue-118 korean ime",
  "size": { "width": 1512, "height": 916 },       // host logical pixels
  "panes": [
    {
      "id": "pane-uuid",
      "kind": "terminal" | "browser" | "textbox" | "other",
      "title": "zsh — worktrees/…",
      "rect": { "x": 0, "y": 0, "w": 0.5, "h": 1.0 },  // normalized [0,1]
      "surfaceId": "uuid",                              // terminal panes only
      "cols": 120, "rows": 40,
      "replaySeq": 123456,                              // snapshot only
      "replay_b64": "…"                                 // snapshot only, ≤256KB
    }
  ]
}
```

## Rendering (web)

- Route `web/app/[locale]/share/[id]/page.tsx`. Requires Stack sign-in; the
  signed-out state shows the Stack sign-in redirect.
- Workspace is laid out at the host's logical size inside a wrapper that gets
  `transform: scale(k)` to fit the viewport (mobile works for free; refined
  scaling later).
- Terminal panes render with `ghostty-web` (`Terminal.write` of decoded
  chunks; `seq` gap ⇒ re-request snapshot). Read-only: no `onData` wiring.
- Non-terminal panes render as titled placeholder tiles (browser panes show
  title + URL if present).
- Cursors: the Sky kite path from `AgentCursorPointerView` (cua PR
  https://github.com/manaflow-ai/cmux/pull/7151) as inline SVG, gradient
  recolored per participant; name label chip next to it.
- Cursor chat: press `/` to type at your cursor; bubble floats next to the
  cursor for 6s and every message appends to the floating chat panel pinned
  bottom-right of the workspace.

## macOS host

- Command palette action `palette.shareWorkspace` ("Share Workspace…"):
  creates the session, copies the URL, connects the host WebSocket
  (`URLSessionWebSocketTask`), starts streaming.
- Join requests present `NSAlert.runCmuxModal` — "<email> wants to view this
  workspace" with Allow/Deny.
- Terminal bytes come from `MobileTerminalByteTee` (`outputUpdates` streams +
  `replayState` for snapshots).
- Host cursor is a local `NSEvent` mouse-moved monitor over the workspace
  window, normalized and throttled.
- Remote cursors + chat bubbles render in a non-activating overlay window on
  the workspace (same approach as `ComputerUseCursorOverlayController` from
  PR 7151), tinted per participant.
- Textbox mirror: host broadcasts textbox text + selection on change
  (host→viewer only in this pass; viewer textbox carets are a follow-up).

## Security

- Share ids are unguessable but the page still requires Stack auth + explicit
  host approval per user; denial is remembered for the session.
- Host token is generated by the DO at create, stored hashed, single active
  host connection at a time (new host connection supersedes the old).
- Read-only: the DO drops any viewer message other than `cursor`/`chat`
  (oversize frames close the socket). No input path to the Mac exists in the
  protocol.
- Session ends when the host disconnects for >60s or sends `{type:"end"}`;
  the DO closes viewer sockets with an `ended` frame and deletes state.

## Licensing

`workers/share/` is GPL-3.0-or-later (LICENSE file + SPDX headers), matching
the repo's open-source license lane.
