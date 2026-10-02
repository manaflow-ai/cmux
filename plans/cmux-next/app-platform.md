# App platform: implementation plan

Status: phase 1 design landed, phase 2 in progress, app platform lead, 2026-10-02. The spec is cmux-next-spec `spec/app-platform.md` (draft 1, commit 813a19f); open decisions D40 to D49 are in its decisions.md. This file holds paths, owners, steps, prototypes and status. Binding: OWNERSHIP-PRINCIPLES.md, architecture.md, actions.md, idle-wakeups.md, skills/cmux-next-feature.

## 1. Summary for agents

- The unit is the **app**: `cmux-app.json` + optional ES module `main` + assets, from a GitHub release (spec sections 3, 9).
- Apps contribute sidebar sections (the main sidebar unit, sidebar-sections.md `content: app(...)`), commands, status items, themes; later whole sidebars, pane kinds, skills, MCP servers, agents, automations (spec section 4).
- App JS runs in a QuickJS-ng VM in a Rust app host process per app, supervised by the daemon (spec section 5). The runtime JS is engine-neutral, so the macOS prototype runs it in JavaScriptCore behind the same protocol until the Rust host lands (section 4 below).
- UI is a declarative scene graph (the old JS custom sidebar API: signals, `VStack`, `Text`, `ForEach`, `Reorderable`, modifiers) rendered natively; apps never draw pixels or HTML in the sidebar (spec section 7).
- Apps call cmux through a generated `cmux` global (`cmux.workspace.list()`, `cmux.actions.run()`, `cmux.live()`, `cmux.storage`, `cmux.net.fetch`), one op per catalog entry, gated by scopes derived from catalog `risk` (spec section 6).

## 2. Paths

| Path | What | Owner |
| --- | --- | --- |
| `cmux-tui/crates/cmux-app-host/js/` | engine-neutral runtime (reactive core, view builders, scene ops, `cmux` global proxy, compat module for old sidebars), bun tests, built `dist/cmux-app-runtime.js` (IIFE, checked in) | app platform lead |
| `cmux-tui/crates/cmux-app-host/schema/cmux-app.schema.json` | manifest JSON Schema 2020-12 (source of truth for every validator) | app platform lead |
| `cmux-tui/crates/cmux-app-host/tools/` | `gen-cmux-global.ts` (reads `cmux-tui/spec/resource-operations-v2.json`, `backend/catalog/cloud-operations.json`, `plans/cmux-next/action-surfaces.json`; writes `generated/`), `validate-manifest.ts` (`cmux apps validate` logic until the Rust CLI verb exists) | app platform lead |
| `cmux-tui/crates/cmux-app-host/generated/` | `cmux-app.d.ts`, `cmux-global.js`, `scopes.json` (checked in; CI checks they match the catalogs) | generated |
| `cmux-tui/crates/cmux-app-host/src/` (later) | Rust crate: supervisor + QuickJS host (rquickjs), built and tested on the Blacksmith testbox only | app platform lead, with the cmux-tui owners |
| `samples/apps/<name>/` | sample apps: `github-prs` (section), `running-agents` (section), `agent-status` (status item) | app platform lead |
| `Packages/macOS/CmuxNext/Sources/CmuxNextApps/` | Swift: manifest model, installed-app registry (mirror), scene store + native renderer, prototype JSC engine, App Store window, section provider for the sidebar | app platform lead |
| `backend/packages/protocol/src/ops-apps.ts`, `backend/apps/api/src/domains/app.ts`, `backend/db/migrations/0002_app_store.sql`, dashboard `routes/apps*.tsx` | store backend (spec section 11) and web store | app platform lead, reviewed by the backend lead |

The Swift module syncs the runtime and generated files from `cmux-tui/crates/cmux-app-host/` into its resources with `scripts/cmux-next/sync-app-runtime.sh` (`--check` in the gate).

## 3. Surfaces

| Action / op | Palette | CLI | Right-click | MCP | Notes |
| --- | --- | --- | --- | --- | --- |
| `appStore.show` | App Store | `cmux apps store` exempt `guiOnly` | sidebar background > Options | follows CLI (exempt) | opens the App Store window (tab kind `app_store` later) |
| `appStore.showInstalled` | Installed Apps | exempt `guiOnly` | — | — | App Store window, Installed tab |
| `app.search`, `app.info`, `app.list` | via App Store page | `cmux apps search|info|list --json` | — | default | cloud reads (spec section 11) |
| `app.install`, `app.update`, `app.remove` | App Store buttons | `cmux apps install|update|remove [--wait]` | Installed row menu | default (approval when the actor is an agent) | cloud mutations; the local supervisor follows |
| `app.reload`, `app.disable`, `app.enable`, `app.logs` | per app ("Reload GitHub PRs") | `cmux apps reload|disable|enable|logs` | Installed row, app section header | default (logs) / opt_in | local supervisor |
| `app.dev`, `app.validate`, `app.init`, `app.pack`, `app.publish` | — | `cmux apps dev|validate|init|pack|publish` | — | validate only | author tools |
| app commands `app:<id>#<cmd>` | listed under the app's name | `cmux apps run <id>#<cmd>` | placements declared by `contexts` | generated tool per command when the app holds `mcp:expose` | registered at runtime; check-action-surfaces exempts the dynamic family with `appContribution` |
| `sidebar.section.addApp` | Add <App> Section | `cmux sidebar section add --app <id>#<section>` | sidebar background > Add | yes | requested from the sections agent |

CLI verbs go to the Rust CLI owner (#16174 session) as a request; the Swift CLI is frozen.

## 4. Prototype engine (JavaScriptCore, DEV/NIGHTLY)

The Rust app host needs the testbox for every build and a daemon supervisor, so phase 2 starts with `AppEngine` in Swift: one `JSContext` per app on a private serial executor (never the main thread), the same `dist/cmux-app-runtime.js`, the same `__cmuxAppNative` ABI implemented in Swift (calls go through `ActionRegistry` and the daemon client with origin `script`), the old lane's 250 ms watchdog. It is a stand-in: in-process, Apple only, no OS sandbox, so it loads only first-party and `local/` apps and is labeled "Prototype engine" in the App Store window. Debug Settings `apps.engine` = `javascriptcore` (default until the host lands) | `quickjsHost`.

## 5. Prototypes for Lawrence (Debug Settings > Apps)

- `apps.store.layout` = `grid` (cards) | `list` (dense rows) | `split` (list + detail side by side).
- `apps.section.look` = `native` (app sections use built-in row metrics) | `card` (app section in a subtle inset card with the app icon in the header) | `minimal` (no header icon, title only).
- `apps.consent.style` = `sheet` (scopes as a list with reasons) | `inline` (scopes expand inside the listing page).
Screenshots of each come from a throwaway demo executable that links CmuxNextApps with the mock registry.

## 6. Steps

| # | Step | State |
| --- | --- | --- |
| 1 | Spec + this plan | landed (spec 813a19f) |
| 2 | Manifest schema + TS validator + fixtures (valid/invalid) | landed |
| 3 | Runtime JS (reactive core, views, scene ops, `cmux` global proxy) + generator (`cmux-app.d.ts`, `scopes.json`, `ops.json`) + bun tests (`scripts/cmux-next/check-app-platform.sh`) | landed |
| 4 | Samples: github-prs, running-agents, agent-status (ids `cmux/…`) | landed |
| 5 | Swift `CmuxNextApps`: manifest model, scene renderer, JSC prototype engine, section provider protocol, mock registry | landed (see 6a) |
| 6 | App Store window + `appStore.show` (Cmd-Shift-P), three layout prototypes | landed (see 6a) |
| 7 | Store backend: `ops-apps.ts`, `AppDO`, installs in `UserDO`/`TeamDO`, `0002_app_store.sql`, projections, tests | in progress |
| 8 | Web store pages in the dashboard (`/apps`, `/apps/$publisher/$name`) | in progress |
| 9 | CLI/MCP verbs (Rust CLI request to the #16174 owner) | requested |

Sidebar: the sections lead accepted app sections: `SectionContent.app` + `LayoutSection.contribution`, `SidebarAppSectionProvider` (title, makeView, preferredHeight) set as `SidebarView.appSections`, action `sidebar.section.addApp` with CLI `cmux sidebar add-app-section` (CLI names are noun + verb).
| 10 | Rust app host (rquickjs) + supervisor in the daemon, OS sandbox, owner-side app grant checks | next |
| 11 | Web panes, whole sidebars, skills, MCP servers | later |

## 6a. Swift lane status (CmuxNextApps, 2026-10-02)

Landed: `scripts/cmux-next/sync-app-runtime.sh` (`--check` in check-app-platform.sh); `AppManifest` (validator with JSON Pointer issues, tested on the shared fixtures); `AppScene` reducer + `AppSceneView` renderer (Row uses the built-in sidebar item metrics; colors resolved in the host view's theme scope, no blue); `AppEngine` (JavaScriptCore, one VM per app on its own executor, scope check per call against scopes.json, 250 ms watchdog, injected one-shot clock) and `AppHost`; `AppGrants` (tiers, per-scope revoke, Run sandboxed, read per call); prototype `AppRegistry` (`<apps dir>/registry.json`, a stand-in for UserDO installs); the App Store window (Discover grid/list/split, listing with live preview, Installed with grants and logs); `appStore.show [app]` and `appStore.showInstalled`; the App sink `AppOperationRouter` (action.run through the control router with the op's origin, reads from ControlSnapshot, notification ledger, per-app storage file, net.fetch with credentials stripped; everything else `operation.unsupported`).

Not built yet: `apps.consent.style` (consent happens through the per-scope switches for now), `apps.engine` (only the JSC engine exists), a cloud `AppStoreCatalog` client, app commands in the palette (`app:<id>#<cmd>`), `integration.request`, app settings in Settings > Apps.

TODO (step 7 of the Swift lane): the sidebar has no `SectionContent.app` / `SidebarAppSectionProvider` on feat-cmux-next yet. `CmuxNextApps.AppSectionProvider` already has the agreed shape (`title(for:)`, `makeView(for:)`, `preferredHeight(for:width:)`, plus `release(_:)`); when the sections lead lands the protocol, the App conforms it (`AppsService`) and sets `SidebarView.appSections`. CmuxNextSidebar was not edited.

## 7. Ownership of new state

| State | Owner | Role |
| --- | --- | --- |
| Installs and app grants | `UserDO` / `TeamDO` | owner; the local supervisor and the app are projections |
| Listings and versions | `AppDO` | owner |
| Downloaded bundles | app supervisor (content-addressed cache) | cache, never authoritative |
| App local storage | app supervisor (per machine) | owner of that app's local KV |
| Scene graph of a mounted contribution | the app host (VM) | owner; clients mirror scene ops; per-client hover/drag stays client |
| Placement of an app section | workspace store (sidebar layout document) | owner (sidebar-sections.md) |
| App settings values | config layer (cmux.json `apps."<id>".settings`) | owner |
| Prototype engine state (JSC) | the macOS app, DEV only | temporary owner until the Rust host lands |

## 8. Decided

- 2026-10-02 (Lawrence via the coordinator): agent-initiated app installs are blocked until the owner stamps the actor; users install only from the app's App Store/palette and the web store (`app.install`, scope-growing `app.update` and `app.approval.decide` need origin `user`; not MCP tools). New apps start `unverified` and stay out of search until staff set a tier.
- The spec repo is written only by the coordinator; this file is the app platform proposal.

## 9. Open items

- Catalog fields needed from the D7 generator owners: `scope_family`, `invalidated_by`, `since`, event payload schemas.
- Sections agent: `content: app(contribution)` in the layout document and placeholder rows.
- Backend lead: review of `AppDO` and `0002_app_store.sql`; migration label `backend:apply-migrations`.
- Rust CLI owner: `cmux apps …` verbs (accepted: noun `apps`, because `cmux app` is the running app's scope; exit 0 ok, 2 usage, 3 denied, 4 expired; verbs generated from the cloud catalog). Implementation is a cli/ module PR after #16174 merges.

## 11a. Install states (Lawrence, 2026-10-02)

| State | Runs and answers granted CLI/MCP/automation calls | Sidebar, palette, menus | Change from |
| --- | --- | --- | --- |
| installed | yes | yes | App Store, web store |
| installed + hidden | yes | no | App Store, Settings > Apps, palette ("Unhide <App>"), CLI `cmux apps hide|unhide` |
| disabled | no | no (listed in Installed only) | App Store, Settings, CLI `cmux apps enable|disable` |
| removed | no; storage and grants deleted | no | App Store, web store, CLI `cmux apps remove` |

Hidden is per user and synced: a field of the user's install record in `UserDO` (ops `app.hide`, `app.unhide`, risk mutate-own, user origin not required because hiding grants nothing). First-party apps are installed by default; sample apps are opt-in (App Store, or DEV builds); `local/` development apps start sandboxed with read scopes. The macOS prototype registry carries `hidden` and the opt-in default until the cloud install record replaces it.

## 12. Critique: what the app platform lead would change if starting today (2026-10-02)

Input for the merge with the first-party apps lead's critique (`app-platform-critique.md`). Strongest first.

1. **An app is a catalog fragment plus an optional implementation.** Today `commands`, `paletteScopes`, `mcpServers`, `automationTriggers` and the server `catalog` are five parallel ways to declare "things you can invoke". Replace them with one: the app ships `catalog.json` in the operation-catalog format (ops with owner `app:<id>`, class, risk, input/output schema, surfaces: palette, CLI, MCP, menus, keyboard), implemented by its JS (`run` exports) or its server. CLI verbs, MCP tools, palette entries, menu placements and automation triggers then come from the same generators as cmux's own ops, and app ops get scopes by the same rule. `contributes` keeps only UI surfaces (sections, status items, panes, palette views, themes).
2. **Owners in the daemon, not in the Mac app.** The JavaScriptCore engine, `AppRegistry`, `AppGrants` and `AppOperationRouter` live in the macOS client. They are owner logic (installs, grants, op routing, scope checks) in a client, which the ownership rules forbid and which the TUI, iOS and the web store cannot share. Build the Rust supervisor + QuickJS host now; the Mac app only renders scene streams and sends events. Delete the in-app engine, registry and grants when the host lands; add nothing more to them.
3. **One validator.** The manifest is validated by a TypeScript tool and a hand-written Swift copy that already drifted once. Keep one validator in Rust (CLI, supervisor; WASM for the registry and the web), generated from the schema; Swift decodes only what it renders.
4. **Semantic components first, layout primitives second.** The scene API exposes stacks, frames and colors, so each app invents its own row, spacing and keyboard behavior. Make the default vocabulary semantic: `List`/`Section`/`Row`, `Detail` with metadata, `Form`, `ActionPanel` (actions with shortcuts, shared by rows, palette and menus), `Empty`, `Meter`, `Editor` (multi-line, rich text), `Popover`, all keyboard-navigable and rendered identically by macOS, iOS, web and TUI. Stacks stay as an escape hatch inside a component. Rewrite the three samples on it.
5. **Typed subscriptions instead of refetch-on-guess.** `cmux.live` re-reads on `<family>.changed`, an event name the catalog does not define. Use catalog stream ops (`*.watch` with typed deltas) and bind signals to streams; add `invalidated_by` only where a stream is impractical.
6. **Explicit user-gesture capability.** User origin is lost at the first `await`. Give every user-event handler a `ctx.gesture` token that the app passes to focus-changing ops; the owner accepts it once, for a short window, for that app only. No ambient origin.
7. **Errors and ids.** Unknown op = `operation.unsupported`, known but not granted = `scope.missing` (host passes both lists). One id grammar `cmux/<name>` for first-party (Tasks = `cmux/tasks`); `client_id = app:<id>` on every app call.
8. **Credentials by handle.** First-party and Verified apps get host-owned credential flows (OAuth, SSH keys, tokens) and receive opaque handles usable only in host ops (`net.fetch {credential}`, `ssh.connect {credential}`); the secret never enters the VM. This replaces "no credentials for apps" (spec 6.5) for those tiers.
9. **Servers are implementations of the app's catalog.** `server` gains tenancy (`team | user | machine`), data classes (durable/ephemeral/synced), its own principal with declared scopes, lifecycle (start on demand, idle stop, upgrade with schema migration), per-platform binaries for first-party native servers, and JS servers for third parties later. Catalog-only apps (no UI) are valid.
10. **Capability scopes for new domains.** The Finder-with-SSH app needs `fs:read:<root>`, `fs:write:<root>`, `ssh:connect:<host pattern>`, streaming listings and drag-and-drop contracts (typed pasteboard items both ways). Scopes become `<domain>:<level>[:<resource pattern>]`, resource patterns checked by the owner.

Accepted as the plan direction by the coordinator (2026-10-02); converging with the first-party apps lead's critique.

Tech debt to remove regardless: the in-app prototype engine path (after 2), the Swift validator (after 3), the `compat-sidebar-data` shim once old sidebars are imported by a one-time converter, sample apps rewritten on 4.

## 13. Platform primitives so first-party and third-party apps fit together (2026-10-02)

Apps coming: Notes, Finder with SSH, Feed email, Integrations, Tasks, Diffs, two editor apps (Monaco-based and CodeMirror-based, separate apps), a usage app for all agent accounts, then likely a git client, PR review, logs viewer, DB client, HTTP client, markdown preview, image viewer, calendar, contacts. Each would otherwise invent files, buffers, embedding, streaming and credentials. The platform owns these once; apps declare and use them.

### 13.1 Resources and URIs
Every addressable thing is a typed resource with a URI: `file://<host>/<path>` (host = machine id; SSH hosts are machines), `git://<repo>@<rev>/<path>`, `buffer://<id>`, `diff://<id>`, `cmux://tab/<id>`, `app://<app id>/<resource>` for app-owned things (a note, a task, an email). One resolver op (`resource.resolve`) returns kind, mime type, owner, capabilities (read, write, watch, stream). Scopes take resource patterns: `fs:read:file://*/Users/me/src/**`, `fs:write:…`, `ssh:connect:<host pattern>`.

### 13.2 Documents and buffers (shared document model)
- A **document** is a resource opened for editing; a **buffer** is its in-memory text or bytes. Owner: the workspace store holds the document record (URI, open views, dirty flag, revision, save state); the session host of the resource's machine holds the bytes and the file watcher (single writer per document).
- Ops: `document.open {uri}`, `document.edit {doc, changes, base_revision}` (text deltas; operational order by revision, rejects stale bases), `document.save {doc}`, `document.revert`, `document.close`, events `document.changed {revision, changes}`, `document.saved`, `document.conflicted {disk_revision}` (file changed on disk while dirty: views show compare / keep mine / take disk).
- Several views (an editor app, a markdown preview, Diffs) attach to one document and see one dirty state; closing the last view of a dirty document asks once.
- **Open-with**: apps declare `contributes.openers: [{id, title, mimeTypes, extensions, uriSchemes, render | paneKind, rank}]`. The user picks a default per type in Settings and in the "Open With" menu; `cmux open <uri> [--with <app>#<opener>]`; drag a file onto a pane uses the same resolver.

### 13.3 Composition (embed contract)
- An app may expose an **embeddable view**: `contributes.embeds: [{id, accepts: {kind: "document" | "diff" | ..., mimeTypes}, props schema, events schema}]`. Diffs embeds "an editor for document X at range R" by asking the platform for the user's default `editor` embed (Monaco app or CodeMirror app); the host mounts the editor app's view inside the Diffs pane with only the props in the contract and a capability for that one document. Neither app sees the other's code or grants.
- Typed contracts ship in the catalog (`embed.editor.v1`, `embed.diff.v1`, `embed.preview.v1`, `embed.terminal.v1`), versioned like ops. A host renders an embed natively (scene), as a web view (web panes), or as a native view (first-party).

### 13.4 Diffs as data
`diff` is a resource: `diff.create {left: uri|rev, right: uri|rev|buffer}` returns `diff://<id>` with hunks; sources are git (working tree, index, commits, branches), agents (an ACP agent's proposed edit set), automations (a run's changes) and two arbitrary documents. Hunk actions (`diff.hunk.accept|reject|stage`) are ops owned by the source (git for staging, the agent session for proposals). The Diffs app, PR review and the git client are three views over the same resources.

### 13.5 Streams, tables and credentials
- **Streams**: logs viewer, Finder listings, HTTP responses, DB results and agent output use one `stream` op class (cursor, backpressure, resume) bound to signals in the runtime; large results page instead of materializing.
- **Tabular data**: a `Table` component with column schema, sorting and virtualized rows (DB client, logs, usage app, Finder list view).
- **Credentials by handle** (section 12.8): SSH keys, OAuth tokens (Integrations, calendar, contacts, email), DB passwords and HTTP auth live in the host vault; apps hold handles usable only in host ops (`ssh.connect`, `net.fetch {credential}`, `db.query {credential}`).
- **Accounts**: the usage app reads `account.list` and `account.usage` ops owned by the accounts and coderouter owners; apps never see provider tokens.
- **Pasteboard and drag-and-drop**: typed items (`uri`, `text`, `diff hunk`, `task ref`) in both directions through host ops, so dragging a file from Finder into an editor or a task works between apps.

### 13.6 What this changes in the manifest
`contributes` gains `openers`, `embeds`, `searchProviders`, `paletteScopes`, `statusItems.placement: menuBar`; the catalog fragment (section 12.1) carries the app's ops, events and embed contracts. These land with the merged critique, not piecemeal.
