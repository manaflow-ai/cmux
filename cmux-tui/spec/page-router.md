# Daemon page router (`page-router-v1`)

The daemon is the one data path of every cmux page (React pages in the Swift app, cmux-browser,
GPUI, a plain browser). A page reaches it with `cmux.protocol/2` requests on its host's page
relay (Unix socket) or on its own WebSocket. This file defines what a page may call. The table is
[`page-router.json`](page-router.json); it is the only list. The daemon embeds it, and
`bindings/codegen/page_router.py` generates the page clients' copy
(`webviews/src/pages/shared/generated/pageRouter.ts`).

## Page identity

A connection serves at most one page, fixed before its first request:

- Page relay (Unix): the host names the page in `client-hello {role: "page_relay", page}`. The page
  never names it. A host opens one relay connection per page id. The reply carries
  `page_operations: {read, gesture, confirm}` from the table, so the host knows which calls need
  a gesture or a sheet.
- WebSocket: the page id comes from the handshake Origin `cmux-page://cmux.<page>` (the web view
  sets it, page script cannot). The listener's Origin rule (`--ws-allow-origin`) still admits or
  refuses the connection first. A WebSocket whose Origin names no page (a plain browser tab on
  `http://127.0.0.1:<port>/pages/<page>/`, a CLI client) has no page id and keeps the rules it had
  before `page-router-v1`.

A page id is 1 to 64 characters of `a-z 0-9 -` and starts with a letter. A page with no table
entry may call nothing.

## Allow list

For a connection with a page id, every `cmux.protocol/2` operation goes through its page's entry:

- `read`: allowed.
- `gesture`: allowed only with the person's gesture, which the host proves with a confirmation for
  exactly this request: `origin: {claim: "user", confirmation}` from `origin.confirmation.issue`
  (the verified app mints it for this operation, these params and this relay connection, after a
  real key or pointer event in the page's view or a native sheet). Without it the request is
  `origin.forbidden {reason: "gesture_required", required: "user"}`.
- `confirm`: the same confirmation, but the host mints it only after the person approved the call
  on a native sheet, never on a click alone (an App Store change can turn off an app's sandbox).
  Without it: `origin.forbidden {reason: "confirmation_required", required: "user"}`.
- not listed: `origin.forbidden {reason: "page_not_allowed"}`.

One key or pointer event backs at most one `gesture` call: the host spends it.

The hard page classes in `request_origin/page_access.rs` (terminal input, screen reads, attach,
renderer grants, the file system) stay refused whatever the table names. A page relay without a
page id may call nothing (default deny, as before). Gate A2 (`apps.install`, ...) still needs
origin `user` on top of the table.

hq-99's rule (cmux#13742): `history.*` reads only for page `history`; a History delete needs page
`history` and the person's gesture.

Page `home-channels` may call `workspace.open_url` (cx-ebm.59.3) only on the person's gesture: the
host proves a click on a web link in the Chief chat with a confirmation for that request on the
page relay, and the link opens on the right side of the home workspace. The page's own WebSocket
has no confirmation, so the call is refused there (`gesture_required`).

With `chief-profile-ws-v1`, page `home-channels` also manages the person's Chiefs: it may call
`chief.profile.list`, `chief.profile.get`, `chief.profile.avatar.get`, `chief.profile.avatar.set`
and `chief.profile.update`, and `chief.profile.create` and `chief.profile.delete` only on the
person's gesture. An update that names instructions, personality or a grant field (`tools`,
`harnesses`, `harness`, `model`, `effort`, `self_edit`) needs the gesture too
(`request_origin/page_access.rs`): without it the page changes only display_name, role and the
avatar. Chief messages render links and rich text in this page, so injected content must not plant
behavior a Chief acts on, widen its grant or delete it without the person's click. The page may call nothing else of the catalog.

## Events (`page-events-v1`)

A page entry's `events` names the subscribe events (events.md) that page hears. A page relay's
`client-hello` reply carries them as `page_events`. A page relay whose page names events may send
`{cmd: "subscribe"}` (only `tree_events` besides `id`): the daemon delivers only those events on
it, with no pairing requests and no tree, terminal or conversation events. A `surface` output
stream is a screen read and stays refused, and a relay whose page names no event gets
`origin.forbidden {reason: "page_events"}`. The host forwards each event as the daemon sent it:
page stream `cmux.<ns>.<event>` is daemon event `<ns>-<event>` (`cmux.history.changed` is
`history-changed`). After a reconnect or an `overflow` the host tells the page to re-read.

`history-changed` names the Closed kind when a commit changed the closed-history store (a closed
workspace, tab or group, or a deleted one), so an open History page shows a closed workspace at once.

A page WebSocket keeps the raw `subscribe` rules of its authenticated connection.

## Routed namespaces

Some page operations belong to an owner outside the operation catalog. The table's `namespaces`
map each one to its owner, so the same v2 envelope works on every host:

| namespace | owner | read | mutation |
| --- | --- | --- | --- |
| `agent_session` | `agent_session.trust` (the folder trust of a chat of this machine, `agent-session-trust` in commands.md; Unix socket only) | `agent_session.trust.get` | `agent_session.trust.set` (page `agent`: `gesture`) |
| `apps` | `apps.store` (the app supervisor's App Store, raw `apps-store {op, args}`) | `apps.catalog.list`, `apps.catalog.get`, `apps.installed.list`, `apps.grants.get`, `apps.logs`, `apps.asset.get` | `apps.set`, `apps.install`, `apps.uninstall`, `apps.grant.set` (page `apps`: `confirm`); `apps.hidden.set`, `apps.grant.revoke` (page `apps`: `gesture`) |

The installed-app panels (cx-hnmbt.13): `apps.grants.get {app}` answers `{app, sandboxed, scopes:
[{scope, reason, risk, optional, granted}]}` for an installed app (`apps.not_installed` otherwise);
`apps.logs {app, limit?}` the last lines of the app's log ring (`{app, lines: [{level, message,
ts_ms}]}`, at most 500, no stream: the page reads again); `apps.asset.get {app, path}` an image file
of the package as `{app, path, data_url}` (png, jpeg, gif, webp or svg, at most 512 KiB, never a
path outside the package). `apps.hidden.set {app, hidden}` is Hide/Show and `apps.grant.revoke {app,
scope}` revokes a scope: neither widens what an app may do, so the Apps page needs only the
person's gesture. `apps.grant.set {app, scope, granted}` sets a scope and needs the native sheet (a
host shows it for an allow; a page revokes with `apps.grant.revoke`). Opening an app is a host verb (the page runs the host action `app.open`), never a
daemon operation.

A routed request is `{protocol, type: "request", id, operation, params, idempotency_key?,
origin?}`; the response is the normal `cmux.protocol/2` response. The origin rules are the
catalog's (the claim may only narrow; the page's allow list; default deny for a page relay without
a page). A mutation needs origin `user` and an `idempotency_key`; origin `user` on the connection
itself (not a page relay's confirmed request) also needs a connection that is not bound to an
agent, as on the raw `apps-store` door. The request envelope refuses unknown and duplicate members
like the catalog parse. `machine` and `session` in params
must be `current` (the owner is this daemon's). The transport is the Unix socket or an
authenticated WebSocket. An owner error comes back as `operation.failed` with the owner's code in
`details.extra.code`; malformed params are `validation.invalid`.

## Next slices

- The host-verb catalog (`host-verbs.json`, ~40 verbs including `transport.gesture` tickets for
  WebSocket pages).
- `git.*` and `newTab.*` operations for the agent-pane pages (cx-jlzsf).
- One origin per daemon-served page (`<page>.localhost` Host names), so a plain browser tab gets a
  page id the browser enforces.
- History and Apps pages on their own WebSocket (no Swift relay).
