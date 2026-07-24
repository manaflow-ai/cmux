# Multiplayer workspace sharing

Terminal-only v1 shares the host's currently focused workspace at
`https://cmux.com/share/<code>`. A session contains one workspace. The guest
sees its live terminal output, split layout, cursors, and chat. An editor can
also type into any terminal in that workspace.

## Session flow

Cmd+Shift+P → **Share Workspace…** creates the session, copies its link, and
opens session chat. A guest must sign in with Stack Auth before requesting
access. The host sees the guest's email and chooses **Allow editing**,
**View only**, or **Deny**. Approval lasts only for that session.

Editors can send input to every current terminal leaf. Viewers cannot send
terminal input. All participants can move colored cursors and exchange messages
in session chat. Approved guests can also create cursor-anchored chat bubbles
from the web viewer; the host sees them at their terminal anchors.

Stopping sharing invalidates the link. A host disconnect starts a two-minute
grace period for reconnection; the session ends if the host does not return.
Session codes are not reusable.

## Layout

The host's bonsplit tree is authoritative. The web viewer preserves each
split's axis, nesting, order, and ratio. Terminal leaves render the host's
render-grid stream. Browser, agent, and other leaves remain placeholders so
the surrounding split geometry stays intact. Guests cannot resize or change
the host layout.

## Architecture

```text
Mac host ──WebSocket──▶ ShareSession DO (`workers/share/`) ◀──WebSocket── guest browser
```

- `workers/share/` contains the separate GPL-3.0 Cloudflare Worker and one
  Durable Object per unguessable session code. It owns session lifecycle,
  approvals, roles, presence, chat history, subscriptions, and fan-out. The
  wire contract is `workers/share/PROTOCOL.md`.
- `web/app/api/share/sessions/` creates sessions and mints connection tokens
  through `web/services/share/token.ts`. Tokens are short-lived Ed25519 JWTs
  bound to a share code and verified Stack identity.
- `web/app/[locale]/share/[code]/` contains the Stack-gated viewer, exact split
  layout, terminal grids and input, placeholders, cursors, and chat.
- `Sources/Share/` contains the host command, session controller, layout
  serializer, terminal grid streaming, moderation, chat, cursor overlays, and
  guest-input application. Shared native protocol and authorization types
  live in `Packages/macOS/CmuxWorkspaceShare/`.

## Trust boundaries

Stack Auth establishes identity, not permission. The Durable Object derives a
participant from the verified socket token, never from a client-supplied user
id. It withholds streams until host approval and rejects viewer input early.

The host Mac remains the input authority. Before applying each relayed input,
it checks the participant's current role, the session's sole shared workspace,
the current pane tree, and that the target is a terminal. Durable Object checks
are defense in depth and are not the host's authorization source.

Browser WebSockets carry their short-lived token in the query string because
the browser API cannot set an `Authorization` header. The Mac sends its token
only in an `Authorization: Bearer` header. Worker invocation logging is disabled
so query tokens do not enter automatic request logs.

Share pages use a no-referrer policy, opt out of indexing, and do not initialize
analytics. Client-side navigation into a share page also suppresses analytics
events containing a share path.

## Relay delivery safety

The relay reserves delivery credit per socket before sending server data. Each
logical delivery sends its payload first, followed by an `ack-request`. Credit
includes the exact payload and ACK-request bytes plus frame overhead, is stored
in the socket attachment, and survives Durable Object hibernation.

Only an ACK whose nonce exactly matches an outstanding entry on that socket
releases its credit. Unknown, duplicate, replayed, and cross-socket ACKs release
nothing. A socket can have at most 128 outstanding deliveries and must stay
below 2 MiB of reserved credit. A delivery that would reach that ceiling is not
sent and that socket is closed.

Server JSON messages and complete binary frames, including the binary header
and payload, must each be smaller than 1 MiB.

## Hard limits

- 32 live connections per session, including the host
- 16 pending access requests per session
- 64 pane subscriptions per guest connection
- 4,000 UTF-8 bytes per chat message
- 500 retained chat messages per session

### One-second rate budgets

The general non-host ingress budget is 120 messages and 512 KiB per socket.
Verb-specific budgets also apply:

- Cursors: 30 source messages per socket, 240 source messages per room, and
  4,096 recipient deliveries per room
- Chat: 2 messages per socket and 8 per room
- Terminal input: 60 messages per editor and 240 per room
- Subscription churn: 64 subscribe or unsubscribe messages per socket and 256
  per room

Here, a room is one share session. The cursor recipient budget bounds fan-out
amplification as participant count grows.

## Deferred

Multi-workspace navigation and Follow, browser video and input, agent composer
co-editing, and mobile clients are outside v1.

The release feature flag defaults off until the production backend is
configured. This document describes the v1 contract, not a production
deployment.
