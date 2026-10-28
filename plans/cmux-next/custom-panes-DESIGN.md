# Custom panes and the reviewed App Store (issue 26579)

Status: MVP in the PR that fixes https://github.com/manaflow-ai/cmux/issues/26579.
Builds on the app platform (app-platform.md: manifest v2, the app supervisor, grants,
local apps) and the React App Store (apps-web-DESIGN.md). Nothing here adds a second
manifest, a second grant system or a second store.

Goal: a person describes a pane to Chief, Chief writes it, the pane opens in cmux and
reloads on every save, the person iterates, then submits it. A reviewer approves or
rejects it, and approved versions are listed in the App Store for everyone.

## 1. Manifest

A custom pane is an app whose `cmux.pane/1` implementation is a web page. Manifest v2
already holds every field (`schema/v2/cmux-app.schema.json`, `implementation.web`,
`runtime.web`); the validator already requires `runtime.web` for a web implementation
(`runtime.web.required`).

```json
{
  "manifestVersion": 2,
  "id": "local/workspace-board",
  "name": "Workspace Board",
  "version": "0.1.0",
  "description": "Every workspace and its terminals; send a command to one.",
  "engines": {"cmux": "^2.0"},
  "icon": {"symbol": "square.grid.2x2"},
  "runtime": {"web": {"root": "web/"}},
  "implements": {"cmux.pane/1": {"web": "web/index.html", "title": "Workspace Board"}},
  "scopes": {
    "workspace:read": "List your workspaces.",
    "terminal:read": "List the terminals of each workspace."
  },
  "optionalScopes": {"terminal:execute": "Send a command you type to a terminal."},
  "files": ["web/"]
}
```

- `id` is `local/<name>` while it is developed. Publishing maps it to
  `<publisher>/<name>` (section 6).
- The entry and every file it loads live under `runtime.web.root`.
- `runtime.web.csp` is optional and can only narrow the host policy (section 2). It may
  use fetch directives, `base-uri`, `form-action` and `sandbox` only; `report-uri`,
  `report-to`, `navigate-to` or any other directive that could name a URL to send to is
  refused by the daemon's manifest rules, the registry and the pane host.
- Permissions are the ordinary scopes. The pane asks for nothing else.

## 2. Sandbox (the web pane host, macOS)

`CmuxNextApps/WebPane` hosts the pane in its own `WKWebView`:

| Rule | How |
| --- | --- |
| Own origin per app | Scheme `cmux-app`, host = the app's namespace (`local/workspace-board` -> `local.workspace_board`, the one id mapping of app-platform.md 18, `app_namespace`). Never `cmux-page://`, so the daemon's page router and the first-party page bridge never see it. |
| Only its own files | `AppWebPaneSchemeHandler` answers GET for files under `<bundle_dir>/<runtime.web.root>`; `.`/`..` components, a symlink out of the root, another host or another method fail the request. |
| Host CSP floor | Every response carries `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; media-src 'self' blob:; frame-src 'none'; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'none'`. A manifest `runtime.web.csp` is sent as a second policy in the same header; the browser enforces both, so it can only narrow. No inline script, no eval, no network: the network is `net.fetch` through the bridge, under the `net:` scope and the egress gate. |
| No peer connections, no preconnect | The pane's WebKit preferences turn WebRTC off, so ICE cannot reach a STUN or TURN host unseen by the content policy and egress gate. A document-start script in every frame also removes `RTCPeerConnection` and its kin, since a same-origin `about:blank` child frame is a fresh realm that `frame-src` does not stop. The pane's configuration allows no network host (`_allowedNetworkHosts`, empty): WebKit refuses every HTTP and WebSocket load and preconnect, including the preconnect a clicked link makes before the navigation policy runs. The pane's own scheme is not a network load. A content rule list also blocks every request outside `cmux-app:` (and the local `about:`, `data:`, `blob:`), which covers `<link rel=preconnect>` and `rel=dns-prefetch` on WebKit that checks rule lists there. The page never loads before both are in place; on a WebKit without the allowed-host setting or a rule list that fails to compile, the pane stays blank. |
| Crash loop | A page whose process crashes reloads at most three times until the next file change. |
| No navigation away | The navigation delegate allows only the pane's own origin; `window.open` and links elsewhere are cancelled. |
| No shared state | `WKWebsiteDataStore.nonPersistent()` per pane: no cookies or storage shared with the browser, other panes or cmux pages. Persistent data goes through `app.storage.*` (the supervisor's per-app store). |
| One door to cmux | A single script message handler, `cmuxApp`, answers only the pane's main frame at its own origin. |

## 3. Permission-gated bridge

The page sees one frozen global:

```js
const { value } = await cmux.call("workspace.list", {})  // any catalog op the app holds a scope for
await cmux.call("app.storage.set", {key, value})
cmux.app                                                   // the app id
```

`cmux.call` posts `{kind: "call", op, params}` to the host; the host sends daemon
command `apps-web-call {app, op, args}`. It resolves to the supervisor's whole ok
body (`{value}` for a read, the mutation's result for a write) and rejects with an
`Error` whose `code` is the refusal's (`scope.missing`, `operation.unsupported`,
`gesture.required`, `bridge.invalid` for params that are not an object). The supervisor decides the call exactly as it
decides a call from the app's QuickJS host (`apps/web_calls.rs`, sharing
`apps/calls.rs`):

- the app must be installed and enabled;
- the grant is the install record's grants, never more than the current manifest asks
  for (`grant_for`), and a sandboxed app gets no `net:` or `integration:` call;
- `operation.unsupported` for an unknown op, `scope.missing` for an ungranted one;
- view-state ops (focus, select, scroll) and actions that need a gesture answer
  `gesture.required`: a web page cannot prove a gesture, so automation in a pane never
  moves what the user sees; `focus: true` is stripped;
- mutation idempotency keys are namespaced `app:<id>:web:...`;
- ops owned by the Mac app's provider (not the daemon) answer `operation.unsupported`
  from a web pane in this MVP.

Only the verified cmux app connection that is not bound to an agent may send
`apps-web-call` and `apps-web-log` (`hosting_app_connection`); an agent or a page
cannot act as an app by sending it.

The page's `console.error/warn/info/log`, `window.onerror` and unhandled rejections go
to the app's log ring (`apps-web-log`, capped per page load and per line), the same ring
`apps-logs` reads, so Chief sees the pane's errors without a screenshot.

## 4. Chief skill flow

The shipped Chief skill `cmux-custom-pane` (`Native/OptChat/optchat-chief/skills/`):

1. Find the local apps folder: `cmux raw command --request-json '{"cmd":"apps-list"}'`,
   field `local_dir` (`<daemon state>/apps/local`).
2. Scaffold `<local_dir>/<name>/` from the template in the skill: `cmux-app.v2.json`,
   `web/index.html`, `web/app.js`, `web/style.css`. No inline script (the CSP refuses it).
3. Check it loaded: `apps-list` shows `local/<name>`; a rejected package is a `warn`
   line in `apps-logs` of `cmux/supervisor` with the validator's path and code.
4. The person installs it once from the App Store (`cmux app store --app local/<name>`
   opens its listing): the native sheet lists its scopes. An agent cannot install an app
   (app-platform.md 8), and the skill says so instead of trying.
5. Open it beside the chat: `cmux app open local/<name>`.
6. Iterate: every save in the folder reloads the pane (the supervisor's FSEvents watch
   emits `apps-changed {app, transaction: "local-reload"}`; the pane reloads on it; no
   polling). After each change read the log:
   `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/<name>"}'` and fix
   what it shows.
7. When the person is happy, they submit it from the App Store (section 6).

## 5. Example pane

`samples/apps/workspace-board`: lists workspaces and their terminals with
`workspace.list` and `terminal.list`, and sends a typed command to a terminal with
`terminal.input.write` when the optional `terminal:execute` scope is granted. It shows the
`scope.missing` error inline when it is not, which is how the person sees what the
permission does.

## 6. Publishing, review and the store (MVP)

### 6.1 Owner and storage

The Cloud Worker (`backend/apps/api`) owns the registry: one `AppRegistryDO`
(SQLite, `idFromName("global")`), routes in `app-registry-routes.ts`. Tables:
`publishers (publisher, user, created_at)`, `submissions (id, app, version, status,
sha256, size, manifest, notes, submitter, submitted_at, decided_by, decided_at,
reason)`, `files (submission, path, bytes)`, `audit (at, actor, action, submission,
detail)`.

### 6.2 Bundle hash

`sha256` over every file in ascending byte order of its path, each as
`path || 0x00 || decimal byte length || 0x00 || bytes`. The Worker computes it on
submit; the daemon recomputes it before it writes a downloaded bundle and refuses a
mismatch.

### 6.3 HTTP API (base: the Cloud API origin)

| Route | Who | What |
| --- | --- | --- |
| `GET /v1/apps/registry/listings?query=&cursor=` | anyone | approved apps, each with its latest approved version: `{listings: [{app, name, description, publisher, version, sha256, size, approved_at, manifest}], cursor?}` |
| `GET /v1/apps/registry/apps/:publisher/:name` | anyone | `{app, latest, versions: [{version, sha256, size, approved_at, notes}]}`, approved versions only |
| `GET /v1/apps/registry/apps/:publisher/:name/versions/:version/bundle` | anyone | approved version only: `{app, version, sha256, files: {path: base64}}` |
| `GET /v1/apps/registry/me` | person | `{user, reviewer, publishers: [..]}` |
| `POST /v1/apps/registry/submissions` | person | `{manifest, files: {path: base64}, notes?}` -> `{submission}` with `status: "pending"` |
| `GET /v1/apps/registry/submissions` | person | the caller's submissions with status and reason |
| `GET /v1/apps/registry/review/queue` | reviewer | pending submissions with submitter, manifest, file list, notes |
| `GET /v1/apps/registry/review/submissions/:id/files?path=` | reviewer | `{path, base64}`: read the code before deciding |
| `POST /v1/apps/registry/review/submissions/:id` | reviewer | `{decision: "approve" or "reject", reason}` -> the decided submission |

- A person is a Stack session, never an install or an agent token, with a verified
  email. A reviewer is a person on `APP_REVIEWERS` (comma-separated user ids), the same
  shape as `CLOUD_ADMIN_USERS`. Without `APP_REVIEWERS` the review routes answer 404.
- Submit rules: `id` is `<publisher>/<name>` with the manifest's patterns; `cmux`,
  `manaflow-ai` and `local` are reserved; a publisher belongs to the first person who
  submits under it; `repository` is `https://github.com/<publisher>/...` (the daemon's
  manifest rule for store apps, so an approved bundle always installs); the version is semver and greater than every pending or approved
  version of the app (a rejected version may be submitted again); one pending
  submission per app; at most 200 files, 2 MiB decoded in total, safe relative paths;
  the package's manifest file is one of the files and equals `manifest`.
- The review queue lists each submission with `files: [{path, size}]`; the Mac shows
  the submitter as `{user}`.
- Review rules: only `pending` is decided; a reviewer never decides their own
  submission; reject needs a reason (8 to 500 characters); every decision is audited.
- An approved version is immutable. Versions accumulate; listings show the latest.

### 6.4 Client

- App Store page (React, `webviews/src/pages/apps`): a Community section in Discover
  (registry listings, Get), a Submit for Review action on an installed `local/` app, a
  My Submissions list with status and the reviewer's reason, and a Review tab shown only
  when `cmux.registry.me` says `reviewer` (queue, file viewer, Approve, Reject with a
  reason).
- Page ops `cmux.registry.*`, answered by the Mac (`AppRegistryPageProvider`) over
  the signed-in Cloud session: `listings`, `me`, `submissions`, `submit {app,
  publisher, notes?}`, `review.queue`, `review.file {id, path}`, `review.decide {id,
  decision, reason, app?, version?}` (app and version name the sheet), `get {app,
  version}`. `submit` and `review.decide` show a native sheet first (publishing and
  deciding are outward-facing); page JavaScript is not a gesture.
- Submit packs the local app on the Mac (`AppRegistrySubmission`): `local/<name>`
  becomes `<publisher>/<name>`, every package file except hidden files, symlinks and
  `node_modules` is sent, and the publisher, repository owner and limits are checked
  before anything is sent.
- Get: the Mac reads the version's hash from the app's listing
  (`GET apps/<publisher>/<name>`), downloads the approved bundle and hands both to the
  daemon: `apps-store {op: "apps.registry.put", args: {app, version, sha256, files}}` (the
  verified app only). A bundle holds one manifest file (`cmux-app.json` or
  `cmux-app.v2.json`), so the reviewer approves the manifest that installs. Puts run one
  at a time, and a put fails when another copy of the app id shadows the registry copy.
  The supervisor checks the files against the listing's hash, validates the package, writes it
  atomically to `<state>/apps/registry/<namespace>/` (`octo.board`) and reloads its
  catalog.
  The page then calls `cmux.apps.install`, which shows the existing native scopes sheet.
  Registry apps are tier `unverified` with source `registry`: they start sandboxed with
  read scopes, like every third-party app (app-platform.md 10).

## 7. Not in this MVP

Gesture tokens for web panes; provider-owned ops from a web pane; a Chromium engine
host for panes; signed bundles and the Verified tier; paid listings; screenshots in
listings; update prompts for installed registry apps (the page shows the newer
version, the person gets it again); search ranking; reports and takedown (a reviewer
can reject only pending versions; removal of an approved version is a follow-up);
proof that a publisher owns the GitHub account its name matches (in this MVP the
first person to submit under a name holds it, and the reviewer checks the repository);
an event stream into web panes (a pane reads again on a timer).

## 8. Tests

- Rust (cmux-tui-core, Testbox): `apps-web-call` grant decisions (ungranted,
  sandboxed `net.fetch`, view op, not installed, granted read through the daemon
  router), `apps-web-*` refused from a connection that is not the hosting app,
  `apps.registry.put` (hash mismatch, bad package, written and listed), `local_dir` in
  `apps-list`.
- Swift (CmuxNextAppsTests, real WebKit): the pane loads its files with both CSP
  policies, cannot load `..` or another host, cannot run inline script, `cmux.call`
  reaches the transport and returns its answer or its error code, a frame of another
  origin cannot post to the bridge, console errors reach the log, a local-reload event
  reloads the pane.
- Backend (vitest, workers pool): submit, publisher claim, version order, one pending,
  size caps, reviewer gate, own-submission refusal, approve lists it, reject with
  reason, bundle download only when approved, hash.
- Webviews (bun): the Community, Submit, My Submissions and Review states with
  fixtures, plus gallery entries.
- Chief: the skill ships to every Chief and names the commands it relies on.
