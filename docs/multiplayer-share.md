# Multiplayer workspace sharing

Share your cmux workspaces at a URL. Guests see your workspaces live in the
browser (terminals, layout, cursors), talk in a session chat, and — with the
editing role — type into your terminals. One Cloudflare Durable Object per
session fans everything out; the host Mac stays the only authority for input.

## Using it

Cmd+Shift+P → **Share Workspaces…** copies `cmux.com/share/<code>` to the
clipboard and opens the floating session chat. All workspaces are shared by
default; uncheck workspaces in the chat panel to narrow the set. Guests open
the link, sign in with their cmux account, and request access; the request
appears in your chat with **Allow editing / View only / Deny**. Stop sharing
from the chat header; the link dies with the session (host gone for 2 minutes
also ends it) and is never reusable.

Guests navigate shared workspaces independently via the web sidebar (presence
dots show who is where), or click a participant to follow them. Everyone's
cursor renders as a colored kite with a name chip, on the web viewer and as an
overlay in the Mac app. Press `/` over the workspace to chat in a bubble at
your cursor; bubbles also land in the chat panel (bottom-right on web,
floating panel on the Mac).

Editors can type into terminals (viewer role can't), co-edit the agent-chat
composer with visible carets, and (slice 3) drive browser panes. Browser and
agent panes stream as video (H.264 via VideoToolbox/WebCodecs, WebP still
fallback); terminals stream as render-grid data and re-render crisply at any
viewer scale.

## Architecture

```
Mac host ──ws──▶ ShareSession DO (workers/share) ◀──ws── guest browsers
                 one per code · participants/roles/chat · fan-out
```

- **Worker/DO** `workers/share/`: session lifecycle, roles (`editor`/`viewer`),
  per-session approvals keyed by Stack user id, chat history, binary frame
  fan-out to per-pane subscribers. Wire spec: `workers/share/PROTOCOL.md`.
- **Auth**: the web API mints short-TTL Ed25519 JWTs bound to the share code
  (`web/services/share/token.ts`, same model as the iroh relay tokens); the
  worker verifies offline. Host-claim tokens only work for the session
  creator, enforced in the DO.
- **Web viewer** `web/app/[locale]/share/[code]/`: Stack-gated page,
  cmux-shaped shell, canvas grid renderer, WebCodecs pixel panes, cursor
  layer, chat, shared composer.
- **Mac host** `Sources/Share/`: palette command, session controller,
  layout serialization from the bonsplit pane tree, per-pane render-grid
  streaming gated on guest subscriptions (reusing the iOS mirror pipeline),
  guest-input application through the shared terminal input path with
  host-side role and shared-workspace enforcement, guest cursor overlay,
  floating session chat.

Trust model: the DO is transport plus bookkeeping; every guest input message
is re-validated on the host against the sender's role and the shared-workspace
set. Input for unshared workspaces is dropped at both layers.
