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

Picked (Lawrence, 2026-10-02): cards. `apps.store.layout` defaults to `grid` and `apps.section.look` to `card`; the other variants stay as Debug Settings variants.

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

## 10. Tiers, sandboxing and grants (Lawrence, 2026-10-02)

- Three tiers: **first-party** (publisher `cmux`), **Verified** (publisher identity verified, signed bundle, review for execute/external scopes), **unverified third-party** (everything else, including sideloads; never in search until a tier is set). There is no fourth tier.
- Security is central. Scopes are enforced by the host and the op owners, never by app code. Any app can be run **fully sandboxed** by the user: no network (`net:` and `integration:` calls refused), no file system, no cmux ops beyond its explicit grants. Per-tier defaults: first-party runs with its granted scopes; Verified with its granted scopes, network limited to declared hosts; unverified third-party starts fully sandboxed with only read scopes granted, and the user widens grants one by one.
- Grants are always visible and revocable: the App Store Installed tab and Settings > Apps list each app's granted scopes with the reason the app gave, and each scope has a revoke control; revocation takes effect immediately (the host refuses the next call) without reinstalling.

## 11. Stable surface for first-party apps

Superseded by platform v2 (section 12): the manifest, ABI and global change once more, together with the first-party apps lead, then freeze. Until then the files below are the contract.

First-party apps (search, inbox, notes, a coderouter app, a usage and limits menu-bar app) are built on this platform by another lead. The following are the stable contract; changes need a version bump and a note to that lead:
- Manifest: `cmux-tui/crates/cmux-app-host/schema/cmux-app.schema.json` (`manifestVersion: 1`); new fields are additive.
- Runtime ABI: `cmux-tui/crates/cmux-app-host/js/ABI.md` (runtime 1.0.0): host functions, entry points, scene ops, props and tokens.
- The `cmux` global and view builders: `generated/cmux-app.d.ts` (API 1.0.0); op names are catalog names and stay stable; scopes come from `generated/scopes.json`.
- Samples in `samples/apps/` are the reference for structure, packing (`tools/pack.ts`) and validation (`tools/validate-manifest.ts`).
- A menu-bar app is a `statusItems` contribution; a needed placement (`menuBar`) is added to the schema on request.

## 11a. Install states (Lawrence, 2026-10-02)

Subsumed by V9 in section 12 (adds `hiddenAccess`).

| State | Runs and answers granted CLI/MCP/automation calls | Sidebar, palette, menus | Change from |
| --- | --- | --- | --- |
| installed | yes | yes | App Store, web store |
| installed + hidden | yes | no | App Store, Settings > Apps, palette ("Unhide <App>"), CLI `cmux apps hide|unhide` |
| disabled | no | no (listed in Installed only) | App Store, Settings, CLI `cmux apps enable|disable` |
| removed | no; storage and grants deleted | no | App Store, web store, CLI `cmux apps remove` |

Hidden is per user and synced: a field of the user's install record in `UserDO` (ops `app.hide`, `app.unhide`, risk mutate-own, user origin not required because hiding grants nothing). First-party apps are installed by default; sample apps are opt-in (App Store, or DEV builds); `local/` development apps start sandboxed with read scopes. The macOS prototype registry carries `hidden` and the opt-in default until the cloud install record replaces it.

## 12. Platform v2: the converged plan (app platform lead + first-party apps lead, 2026-10-02)

Inputs: the app platform lead's critique (previous revision of this section, accepted as the direction) and the first-party apps lead's critique (`app-platform-critique.md` on branch feat-cmux-next-app-platform-critique, 9d0629dd4e9, items C1 to C10). This section replaces both; the app platform lead owns it. Verdict shared by both: today's platform is a good sidebar-widget system; the apps asked for (editors, Diffs, Finder with SSH, mail, git, logs, DB and HTTP clients, usage, Caffeinate) need documents, interfaces between apps, handles, rich panes and owners outside the Mac app.

### 12.1 The model

| # | Decision | Replaces |
| --- | --- | --- |
| V1 | **An app = manifest + catalog fragment + implementations.** The catalog fragment (operation-catalog format, owner `app:<id>`) declares the app's ops, events and their surfaces (palette, CLI `cmux apps run`, MCP, menus, keyboard, automation triggers); cmux's generators produce every surface. Implementations are exports of the app's JS, its web pane, or its server. | `commands`, `mcpServers`, `automationTriggers`, `paletteScopes` as separate manifest kinds |
| V2 | **Typed interfaces between apps and the shell** (`implements` / `consumes`, versioned schemas in `cmux-tui/crates/cmux-app-host/interfaces/<name>/<major>.json`, generated into `cmux-app.d.ts`, Swift and Rust). First five: `cmux.editor/1`, `cmux.viewer/1`, `cmux.diff.renderer/1`, `cmux.fs.provider/1`, `cmux.search.provider/1`; then `cmux.diff.source/1`, `cmux.feed.source/1`, `cmux.opener/1`, `cmux.credential.provider/1`, `cmux.contact.provider/1`. Places are interfaces too: the sidebar consumes `cmux.section/1`, the menu bar `cmux.status/1`, the palette `cmux.palette.scope/1`. | per-place contribution kinds (`sidebarSections`, `statusItems`, `paneKinds`) |
| V3 | **Documents** (`doc_…`): one owner per document, the document host on the machine that owns the bytes (session host for files through `cmux.fs.provider/1`, the notes server for notes, an app server for app documents). It owns the buffer, dirty state, revision, unsaved-buffer journal, file watching (events, no polling), atomic save and conflicts. Views send `document.edit {doc, base_revision, edits}`; a stale base is rejected and the view rebases (intent log). Open-with per type in the config layer (`openWith."<type>"`), shown in Settings and the Open With menu, `cmux open --with`. | the earlier split (store holds the record, session host the bytes) |
| V4 | **Embeds**: `cmux.ui.embed(interface, input, options)` mounts another app's implementation inside a pane or scene as its own mount (own VM, own grant), connected only through the interface's typed props and events. Diffs embeds the user's default `cmux.editor/1`. | none (new) |
| V5 | **Diffs are resources** (`diff_…`) owned by their producer: git ops on the session host (`git.status/diff/show/log`, `git.stage/apply` with origin user), agents (`diff.propose` creates a review item in the feed), automations (`diff.publish`), two documents. Hunk actions are ops on the producer. | none (new) |
| V6 | **Handles, not strings**: roots (`root_…`), host connections (`host_…`), credentials (`cred_…`), documents, diffs are opaque handles created by the user or the shell (file panel, connect sheet, credential provider, drag and drop, open-with). Scopes stay the coarse consent; handles are the fine grant. Secrets never enter app code. | `fs:read:<pattern>` resource scopes and `net:<host>` for SSH (net: stays for HTTP egress) |
| V7 | **Three renderers, all first class**: scene (native, every client: sections, status items, forms, lists, small panes; grows semantic components `List`, `Section`, `Row`, `Detail`, `Form`, `ActionPanel`, `Table`, `Meter`, rich text runs, keyboard selection); web pane (sandboxed web view, `cmux-app://` scheme, `cmux` global injected with the same grant, one WebContent process per window per app, suspended when hidden; Monaco, CodeMirror, Diffs, charts) in phase 1; native pane (first-party only). | web panes as a phase 2 escape hatch; layout primitives as the main vocabulary |
| V8 | **Owners outside the client**: the Rust app supervisor in the cmux daemon (installs mirror, grants, op routing, scope checks, QuickJS host per app with OS sandbox, storage); `UserDO`/`TeamDO` own install, enable, hide and grants. The Mac app renders scene streams, hosts web panes and native panes, and sends events. | in-app JavaScriptCore engine, `AppRegistry`, `AppGrants`, `AppOperationRouter` |
| V9 | **Install / enable / hide** per (user, app), owner `UserDO` (team installs in `TeamDO`, the member's enable/hide overlay in `UserDO`): `installed` (source default, user, team), `enabled`, `hidden`, `hiddenAccess {cli, mcp, automations}` (default all true). Invariants: hidden implies installed; disabled overrides all; uninstall clears enable, hide, storage and grant in one commit; hide never touches grants, storage or layout records. One central filter drops hidden apps from palette, menus, sidebar, menu bar and open-with; "Show Hidden Apps" always exists. First-party apps default-installed; samples opt-in. | section 11a (now subsumed) |
| V10 | **Owner taxonomy for app data**: view state in the client; app-local data in the supervisor; personal synced data in the app's server (`instances: user`) or `UserDO` KV; team data in the app's server (`instances: team`, single writer); per-machine data in `instances: machine`; documents in the document host. No app keeps a copy of another owner's data. | ad hoc app models |
| V11 | **Runtime contract fixes**: explicit gesture tokens (`ctx.gesture`, passed to focus-changing ops, accepted once in a short window); unknown op = `operation.unsupported`, ungranted = `scope.missing`; typed streams (`*.watch`) instead of guessed `<family>.changed`; `onCleanup`; `cmux.app.settings.set`; app l10n (`strings/<lang>.json`, `cmux.t(key)`); `x-cmux-devOnly`; `variants` block for DEV/NIGHTLY prototypes; host capability ops for system features (first: `power.assertion.*` for Caffeinate). | runtime gaps listed by the first-party apps lead |
| V12 | **Store follows the model**: listings show implemented interfaces, handles the app asks for, server and where it runs, tier and sandbox profile; search by interface; installing an implementation for a type with no default asks "Use for .ts files?". | category-only listings |

### 12.2 Disagreements and recommendations (for the coordinator)

1. **Resource-pattern scopes vs handles only.** The app platform lead proposed `fs:read:<pattern>`; the first-party lead proposed handles only. Recommendation: handles only for files, hosts and credentials (V6); patterns are not needed because standing access (an automation) is also a handle the user creates once. Agreed by the app platform lead.
2. **Document record owner.** Earlier proposal: workspace store holds the record, session host the bytes; the first-party lead: one document host owns both. Recommendation: one owner (V3); two owners for one document would break the single-writer rule for dirty state.
3. **`hiddenAccess` per app.** Recommendation: keep it (V9) but default all true and show it only in Settings > Apps, so the common case stays one switch.
4. **Places as interfaces now or later.** Recommendation: define `cmux.section/1` and `cmux.status/1` now (they are what sections and status items already do) so the manifest has one mechanism from the start; no compatibility layer for the old kinds (not live).
5. **Web panes in phase 1.** Recommendation: yes (V7); editors and Diffs are the first apps Lawrence asked for.

### 12.3 Order of work (each step lands with tests; failing test first for fixes)

1. Runtime contract (V11 subset): `operation.unsupported`, gesture tokens, `onCleanup`, `settings.set`, l10n, `x-cmux-devOnly`. JS runtime and ABI, bun tests. *(in progress)*
2. Manifest v2 schema: `implements`/`consumes`, catalog fragment, places as interfaces, `variants`, server tenancy (`instances`), data classes, per-platform binaries; one Rust validator (Blacksmith testbox) replacing the TS and Swift copies; samples rewritten.
3. Rust app supervisor + QuickJS host + install/enable/hide mirror (V8, V9); the Mac app switches to scene streams; delete the in-app engine, registry and grants.
4. Documents + open-with (V3) with the session host owner; web panes (V7) with the document bridge.
5. Interfaces + embeds (V2, V4); Diffs resources and git ops (V5).
6. Handles with the transport (V6): roots, hosts, credentials; Finder with SSH.
7. Store v2 listings (V12).

Debt removed on the way: in-app JSC engine (after 3), `registry.json` (after 3), Swift and TS validators (after 2), `compat-sidebar-data` (one-time importer instead), the three samples (rewritten in 2).

### 12.4 Primitives per upcoming app

| App | Primitives |
| --- | --- |
| Diffs | `cmux.diff.renderer/1`, embed `cmux.editor/1`, diff resources, git ops, web pane |
| Monaco editor, CodeMirror editor | `cmux.editor/1`, documents, web pane, open-with, language ids, decorations |
| Notes | native pane (first-party), documents owned by the notes server (`instances: user`) |
| Finder with SSH | `cmux.fs.provider/1`, root/host/credential handles, streaming listings, `cmux.viewer/1` previews, typed drag and drop |
| Feed email, Integrations | email is a feed source, not a separate inbox: threads are feed items through `cmux.feed.source/1`, a reply is a feed response kind, sending is a `send-external` op that needs approval for agents; bodies render through `cmux.viewer/1`; mailbox access is an integration connection with a credential handle (Gmail read through the browser until CASA completes) |
| Tasks | team server (`instances: team`), catalog fragment, native pane |
| Usage (all agent accounts) | per-machine server, `account.list`/`account.usage` ops, status item, pane |
| Caffeinate | host capability `power.assertion.create/release/list` (IOKit, no process spawn, bound to a terminal or task handle), status item |
| Git client, PR review | git ops, Diffs embed, documents, integrations |
| Logs viewer | streams (append-only documents), `Table`, search provider |
| DB client, HTTP client | credential and host handles, `Table`, documents for queries and requests |
| Markdown preview, image viewer | `cmux.viewer/1`, documents (binary chunks for images) |
| Calendar, contacts | app servers, integration connections, `cmux.contact.provider/1` |
| Remote desktop | host handles, a native streaming surface, input with origin user only, visible control indicator |

Drag and drop: typed items `{kind: file|doc|diff|text|url|task, handle|value, display}`; targets declare accepted kinds; drops between hosts copy or move through `fs.copy` on the owners.

### 12.5 Manifest v2 extensions (2026-10-03, names approved by the coordinator)

The first-party apps found seven things v2 could not hold (`first-party-apps/*/README.md`, "Manifest v2"). The schema, the validator (`cmux-app-manifest`) and the fixtures now hold them; lane 3 restores the dropped behavior in each app.

| Field | Shape | Validator rule |
| --- | --- | --- |
| Scopes | verbs `answer`, `control`, `input`, `keys` join `<family>:read|write|execute|external` (`feed:answer`, `host:control`, `terminal:input`, `coderouter:keys` for creating and revoking credentials of the family); fixed `embed:run`; server-only `process:spawn:<binary>` and `op:<op name>` in `server.scopes` | every scope has a risk class from `schema/v2/scope-classes.json` (standard, sensitive, restricted); server-only scopes outside `server.scopes` are errors; `process:spawn` needs a native server; restricted scopes in a non-first-party manifest are warnings (a Verified review must cover them) |
| Restricted scopes | `feed:answer`, `terminal:input`, `fs:write`, `clipboard:write`, `mcp:expose`, `usage:read`, any `<family>:answer|input|keys`, `process:spawn:*` (Swift reads the same table: `AppScopeClassTable` over the bundled `scope-classes.json`; unknown scopes count as restricted) | sensitive: every write, execute, external and control verb, `actions:run`, `net:*`, `integration:*`, `op:*`; standard: every read verb, `storage:*`, `embed:run` |
| Catalog op surfaces | `keyboard: [{key: "cmd+s", when}]`, `gesture: "required"|"optional"`, `palette: {title, when?, presets?: [{id, title, args, when?}]}` | `schema/v2/cmux-app-catalog.schema.json`; op owner is `app:<id>`, names are in the fragment's family, names and preset ids unique, `export` needs `runtime.main`, a shortcut bound twice for the same condition warns |
| `requires` | `{hostCapabilities: ["power.assertion/1"], platforms: ["macos", "linux", "ios"]}` | unknown host capability is an error; the supervisor refuses to enable the app elsewhere |
| `lifecycle` | `{onDisable, onUninstall}`: `release-owned` (default) or `keep` | the host releases resources the app owns (power assertions, watches, panes) |
| `handles` | kinds `root`, `connection`, `credential`, `document`, `diff`, `image`, `terminal`, `task`; value is a reason or `{reason, max?, rights?: [read, write], kinds?}` | `host` is gone (14.1). There is no credential-connection kind: an app asks for a `connection` handle with `kinds` (for example `ssh`, `cloud-vm`) and, only when it needs the secret itself, a separate `credential` handle |
| `documents` | `[{id, title, types?, extensions?, symbol?}]`, one owner per type | |
| `openWith` | `[{interface, types, default: ask|never}]` | the interface must be in `implements` |
| `notices` | `[{path, title?}]` | the file exists in the package and is in `files` |
| `drag` / `drop` | `{provides: [kind]}` / `{accepts: [kind]}`; kinds `file`, `directory`, `text`, `url`, `image`, `document`, `diff`, `terminal`, `task`, `connection` | |
| `consumes` | `{interfaces, ops, events, handles}` (the array form is removed) | interfaces must be known |
| `implements.<interface>.server: true` | the app's top-level server block (native or js) implements the interface's methods over the provider channel, for example `{"cmux.fs.provider/1": {"server": true, "schemes": ["cloud-vm"]}}` (Cloud app lead, approved 2026-10-04) | exactly one of export, web, native, server; `implements.serverMissing` without a top-level server |
| Terminal backends | `cmux.terminal.backend/1` (bytes mode: open, resume, write, resize, signal, close; events output, exit, lost) and `cmux.terminal.connector/1` (host mode: the far end runs a session host, the local host relays the viewer protocol); both take `options.kinds` (1-16 unique ids, default deny; registry ids `app:<app>/<kind>`); scope `terminal:backend` is restricted | shapes chosen by the ghostty-next lead (cloud-app.md); interface files are drafts until the Cloud and sample backends prove them |
| Interface options | each interface file has an `options` JSON Schema (section: `defaultRegion`, `maxRows`; status: `placement`; editor: `capabilities`, `paneCommands`; diff renderer: `inputs`) | options on an interface without an options schema are errors |
| Servers | unchanged | `cmux-notes` and `cmux-usage` declarations wait for the binaries; their scopes fit the grammar above |

`validate_package_file(dir, "cmux-app.v2.json")` validates a package that still ships a v1 `cmux-app.json`, the catalog fragment included; a test runs it over every first-party app.

## 13. Step 3 contract: the Rust app host (2026-10-02)

Coordinator answers applied: default first-party apps come from a deployment list and get their required scopes without a consent sheet (visible and revocable in Settings); cards are the default store layout and section look; agents may hide and unhide apps, never install them until the actor stamp lands.

### 13.1 Processes and owners
- **App supervisor**: a module of the cmux daemon (`cmux-tui-core::apps`, new files only), capability `apps-v1`. Owns, per machine: the install mirror (local `apps.json` in the daemon state dir until the `UserDO` install record syncs down; same fields as V9), grants, scope checks against `scopes.json`, the app bundle cache, per-app KV storage (SQLite, one table per app), the egress gate for `net.fetch`, and the app host processes. It routes app calls to the daemon's own op dispatcher with `actor = app:<id>`, `on_behalf_of = <user>`, origin `script` (or `user` when a live gesture token is presented by a mutation).
- **App host**: crate `cmux-app-host` (`cmux-tui/crates/cmux-app-host`, binary `cmux-app-host`), one process per running app, QuickJS-ng through rquickjs, embeds `js/dist/cmux-app-runtime.js`, implements the runtime ABI (`js/ABI.md`) natively. Spawned by the supervisor with one end of a socketpair (fd 3); JSON lines both ways; memory limit 32 MiB, interrupt deadline 250 ms per entry, at most 64 pending calls, drains the job queue after every entry point. macOS: `sandbox_init` profile denying network, exec and file reads outside the bundle; Linux: seccomp + Landlock. Idle stop after the last mount closes plus a one-shot timer (setting `apps.idleStopSeconds`, default 60).
- **Clients** (macOS app, TUI later, iOS via relay): mirror installs and scene streams; render scenes natively and web panes; send user events. No engine, no registry, no grants in the client.

### 13.2 Daemon commands (capability `apps-v1`)
| cmd | params | result / events |
| --- | --- | --- |
| `apps-list` | `{}` | `{apps: [{id, version, tier, installed, enabled, hidden, hidden_access, source: default|user|bundled|local, grants: [scope], sandboxed, manifest}]}` |
| `apps-set` | `{idempotency_key, app, installed?, enabled?, hidden?, sandboxed?, grant?: {scope, granted}}` | updated app; every change (including `hidden`) needs a verified cmux app connection (origin `user`) until P8 adds the verified-app path; agents must not change what the user sees (D55 as amended, request-origin.md) |
| `apps-mount` | `{app, interface, mount_id, context}` | starts the host if needed; events `apps-scene {mount_id, ops}` then deltas; `apps-mount-failed {mount_id, reason}` |
| `apps-unmount` | `{mount_id}` | — |
| `apps-dispatch` | `{mount_id, node, event, payload}` | the supervisor mints the gesture token for user events from clients with origin `user` |
| `apps-run` | `{app, op, args, idempotency_key}` | runs a catalog op of the app (palette, CLI `cmux apps run`, MCP); waits for the result |
| `apps-logs` | `{app, follow?}` | log lines; follow streams `apps-log` events |
| events | `apps-changed {revision}` (install mirror), `apps-host {app, state: running|stopped|crashed, reason?}` | |

Every mutation carries an idempotency key and ends with `request-settled` like other daemon ops (OWNERSHIP-PRINCIPLES).

### 13.3 What is deleted in the same step
Swift: `AppEngine`, `AppGrants`, `AppRegistry`/`AppRegistryFile`, `AppOperationRouter` and the deferred sink, `AppManifestValidator*`, the JavaScriptCore watchdog; CmuxNextApps keeps the scene model and renderer, the App Store UI (over an `apps-v1` client), and the section provider. TypeScript: `tools/validate-manifest.ts`, `tools/json-schema.ts` (the Rust crate validates samples in its tests); the v1 schema and fixtures. Samples are rewritten on manifest v2 (`implements` `cmux.section/1`, `cmux.status/1`).

## 14. Folded in: first-party apps round 2 and the file browser proposal (2026-10-02)

Inputs: `first-party-apps.md` section 12 (open points against v2) and `finder.md` (what a third-party file browser needs). Coordinator answers: daemon requests get an actor field; the first-party apps lead moves `first-party-apps/` to manifest v2; the Rust lane's lifecycle choices are accepted; `cmux-app-host` packaging goes to the pin owner and PRs 16871 + 16872 merge together once the binary ships.

### 14.1 Decided now (in the schema on this branch)
- Connection handles are `conn_…`, not `host_…` (`host_…` is the public enrolled-host id, enumerable, not a capability; plain SSH targets have none). V6 handle kinds: `root`, `connection`, `credential`, `document`, `diff`, `image`.
- Scope grammar: superseded by 12.5 (`<family>:answer|control|input`, `embed:run`; `power:read|write` and `account:read` are ordinary family scopes).
- `untrack` is declared in `cmux-app.d.ts`; `files` is a category.

### 14.2 Added to the order of work
| Item | Owner | Step |
| --- | --- | --- |
| **Actor field on daemon requests**: every request carries `actor` (`user`, `app:<id>`, `agent:<id>`) stamped by the connection owner, never by the caller; the owner records it in the replay record; the supervisor stamps `app:<id>` on app calls | daemon (cmux-tui) + supervisor | 3b |
| Gesture tokens for palette and keybinding invocations of app ops: the client mints the token for the user action and `apps-run` carries it, so user-only ops (export, import, answer) work from the palette | supervisor + Mac app | 3b |
| Scene: `ScrollView`, semantic `List` with selection, focus, keyboard commands and `onVisibleRange`, `Table` with sortable and resizable columns, `Embed` node (embeds from scenes, not only web panes), `drag` / `drop` props with typed items, `tap {count, modifiers}`, `TextField` styles (`search`, `bordered`), `Image` accepting `img_…` handles | runtime + all renderers | 4 |
| Pane plumbing: `app.pane.open {kind, input}` with a gesture, `ctx.size` + resize events, the terminal theme in the pane init, pane-routed commands (Cmd-S goes to the focused editor pane's `requestSave`) | supervisor + Mac app | 4 |
| Web pane CSP default allows `style-src 'self' 'unsafe-inline'` (editors need it); scripts stay `'self'` | Mac app web pane host | 4 |
| File system ops: `fs.roots.list/pick/release/watch`, `fs.list` with cursor batches and a window, `fs.watch` with revisions, `fs.stat/read`, `fs.mkdir/rename/copy/move/trash/delete/undo`, jobs (`fs.job.*`) with conflict answers, `fs.thumbnail` returning `img_…` | file system owner (session host; `cmux link` SFTP for SSH) | 6 |
| Connections and credentials: `host.list/connect/disconnect/forget/watch` returning `conn_…`, host key verification sheet, `credential.request/release` returning `cred_…` | transport (lane 12) + credential broker | 6 |
| Drag and drop targets: `terminal.drop` (local path or remote-safe reference), `agent.attach` (handle into the agent context, intersected with the dragger's grant), cross-host copy through `fs.copy` | session host, ACP owner, shell drag session | 6 |
| One hunk-decide op for every diff producer (`diff.hunk.decide {diff, hunk, decision}` routed by the diff's producer) | diff producers | 5 |
| `open.with.list` for the Open With menu | config layer | 4 |

### 14.3 Open
- Who builds `cmux link` SFTP and the host key sheet (transport lead, lane 12): questions in `finder.md` section 11 go there through the coordinator.

### 14.4 Host capabilities (system features through host ops, never through app code)
Apps reach system features only through ops owned by the native host of the machine; app code never spawns processes or calls system APIs.

| Capability | Ops | Owner | Rules | Users |
| --- | --- | --- | --- | --- |
| Power assertions | `power.assertion.create {kinds: display|idle|disk|system|user, reason, until: {pid|terminal|task|deadline}}` -> `pwr_…`, `power.assertion.release {assertion|all}`, `power.assertion.list`, stream `power.assertion.watch` | the native host on that machine (IOKit power assertions; no process spawn) | scope `power:write` (list: `power:read`); an agent may bind an assertion only to its own terminal and for at most 4 h; `until-stopped` and releasing another actor's assertion need origin user; every assertion ends with its binding (pid exit, terminal idle, task done, deadline) | Caffeinate app (PR 16998), cmux server health, CLI `cmux power keep-awake\|list\|stop\|watch` (accepted by the Rust CLI owner: global `--session` routing, `$CMUX_TUI_TERMINAL_ID`, verbs generated from the catalog, `watch` CLI only, host checks origin user) |

The app supervisor lane adds the power ops after PR 16872 lands; the catalog generates the CLI verbs and MCP tools.

## 15. App Store backend: `cmux.apps.*` (R62 UI-STACK, 2026-10-04)

The App Store page moves to React (webviews) with a Rust backend; the Swift App Store UI is deleted after parity and gets no new features. The app supervisor (apps-v1) owns these ops; they are Rust types with `schemars` in `cmux-tui-core/src/apps/store.rs` and enter the one IR through emit-ir (pane-protocol.md; one catalog for panes and apps, full names canonical, old wire names as `aliases`). The page, the CLI and MCP use the generated client.

| Op | Scope | Rule |
| --- | --- | --- |
| `cmux.apps.catalog.list {query?, category?, tier?, cursor?, limit?}` | apps:read | bundled, sample, local and registry apps in one list, with install state and mirror revision |
| `cmux.apps.catalog.get {app, version?}` | apps:read | detail: scopes with risk class (scope-classes.json) and reason, handles, notices, versions, interfaces |
| `cmux.apps.asset.get {app, path}` | apps:read | only paths the manifest names (icon, screenshots, notices), as a byte stream; the page never reads bundle folders |
| `cmux.apps.installed.list` | apps:read | installed, enabled, hidden, sandboxed, source (default, user, bundled, local), version, update, grants |
| `cmux.apps.install {app, version?, grant_optional}` / `cmux.apps.uninstall {app}` | apps:write | origin user with a gesture; agents refused until the actor stamp |
| `cmux.apps.set {app, enabled?, hidden?, sandboxed?}` | apps:write | origin user for every field, hidden included, until P8 adds the verified-app path (D55 as amended: agents must not change what the user sees); replaces the `app.hide`/`app.unhide` actions |
| `cmux.apps.grants.get {app}` / `cmux.apps.grant.set {app, scope, granted}` | apps:read / apps:write | grant changes origin user with a gesture |
| `cmux.apps.updates.list` / `cmux.apps.update {app}` | apps:read / apps:write | an update that adds scopes asks first; update origin user |
| `cmux.apps.local.add {path}` / `cmux.apps.local.remove {app}` | apps:write | dev apps start sandboxed; origin user |
| `cmux.apps.validate {path}` | apps:read | `cmux-app-manifest` issues |
| `cmux.apps.logs {app, follow?}` | apps:read | stream of log lines |
| `cmux.apps.watch` | apps:read | typed stream `{revision, app?}` so the page never polls |
| `cmux.apps.open {app, as?: "screen"\|"tab", target?, command?, focus?}` | apps:write | `as` defaults to `presentation.screen` (section 16); `as: "screen"` calls the layout owner's `workspace.ensure_app {app, kind}`; `as: "tab"` opens a page tab, `target` = a tab drop zone; replaces the `app.open` action |

Confirmation (coordinator decision, React UIs plan): install, uninstall, update and grant.set always show a native Swift confirmation sheet (app name, scopes with their risk class). Only that sheet stamps origin user; user activation in page JavaScript is not proof of a gesture. The supervisor asks the client that shows the page for the sheet and runs the op only after the user confirms there; a refusal answers `apps.confirmation_declined`.

Icons: cmux never ships SF Symbols as web SVGs (Apple license). `cmux.apps.asset.get` renders a manifest symbol name to a PNG on a Mac host; other clients show a generic glyph. The validator warns (`icon.noImage`) when a manifest has no image icon.

The CodeRouter entry needs no op of its own: a first-party listing plus `cmux.apps.open`. Third-party namespaces are `<publisher>.<name>` ('-' becomes '_'); the store registry (AppDO) keeps publisher ids unique.

## 16. App screens: `presentation` for every app (R63/R64, spec app-screens.md 4)

Every app, built-in or third-party, says how it appears with one manifest v2 block. Home, App Store and CodeRouter use the same fields (`first-party-apps/home`, `app-store`, `coderouter`); no code path reads them specially. A Gmail web app is a manifest with a top sidebar item, `screen: "app"`, a web URL and an icon (`schema/v2/fixtures/valid/gmail.json`).

```json
"presentation": {
  "sidebarItem": {"section": "top", "title": "Gmail", "icon": "icon.png", "order": 130},
  "screen": "app",
  "tab": true,
  "primaryInput": "div[role=search] input",
  "web": {"url": "https://mail.google.com/mail/u/0/", "profile": "app", "origins": ["https://accounts.google.com"]}
}
```

| Field | Meaning | Validator |
| --- | --- | --- |
| `sidebarItem {section, title?, icon?, order?}` | a sidebar item that opens the app; title and icon default to the app's; the user may hide or move it (R53) | `order` 0-99 is first-party only (`presentation.orderReserved`), so no app sits above Home (Home 0, App Store 10, CodeRouter 20) |
| `screen` | `app` (the app fills the screen) or `appColumn` (a docked app column next to the normal columns, like Home) | |
| `tab` | the app may also open as a page tab (Open as Tab, drag into a workspace) | |
| `primaryInput` | where typing goes when nothing has focus: a CSS selector in a web page, or a scene node id | |
| `web {url, profile?, origins?}` | a web app shown in the browser engine with its own profile (`app`: cookies stay per app) and the browser's network policy; the native install confirmation lists `url` and `origins` | `https` only; a sidebar item, screen or tab needs content: `implements["cmux.pane/1"]` or `web` (`presentation.noContent`); not both (`presentation.twoContents`) |

A sidebar item and a screen need no scope. Owners: the layout lead implements the screen kinds from `screen`; the sidebar lead builds the top band from `sidebarItem` of the installed, visible apps (replacing the hard-coded default items); the App Store confirmation shows the web URL list.

## 17. Toolbar items: `contributes.toolbarItems` (R69, spec titlebar-area.md 3)

Apps add buttons, menu buttons and small views to the top-left toolbar band, and may offer an alternative behavior for a built-in item. Built-in items (`sidebar.toggle`, `nav.back`, `nav.forward`) are ordinary catalog entries.

```json
"contributes": {"toolbarItems": [
  {"id": "compose", "kind": "button", "title": "Compose", "icon": {"symbol": "square.and.pencil"}, "action": {"op": "mail.compose"}, "order": 10},
  {"id": "more", "kind": "menu", "title": "More", "items": [{"title": "Refresh", "action": {"op": "mail.refresh"}}]},
  {"id": "meter", "kind": "view", "title": "Usage", "width": 120},
  {"id": "back", "kind": "button", "title": "Back in Mail", "action": {"op": "mail.back"}, "overrides": "nav.back"}
]}
```

| Rule | Where |
| --- | --- |
| `kind` button needs `action` (one of the app's catalog ops or a catalog action id, with `args`); menu needs `items` (at most 16); view needs `width` (16-160 pt) and `runtime.web` (the slot is rendered by `cmux-page://<app>/toolbar/<id>`) | schema; `toolbar.viewNeedsWeb` |
| At most 4 items per app; the shell shows `TOOLBAR_VISIBLE_APP_ITEMS` (3) app items and puts the rest in the overflow menu | schema `maxItems`; shell |
| No position field: app items always follow the built-in items, so none sits left of the sidebar toggle; `order` sorts app items only | schema (unknown keys refused) |
| `overrides` names `nav.back` or `nav.forward` and only on a button; the user picks the alternative in Settings, never applied silently; `sidebar.toggle` cannot be overridden or removed | `toolbar.toggleFixed`, `toolbar.overrideUnknown`, `toolbar.overrideKind` |
| An action op in the app's own catalog family must exist in its fragment; ids are unique | `toolbar.unknownOp`, `toolbar.duplicate` |

Swift: `AppManifest.toolbarItems` (`AppToolbarItem`: kind, title, icon, action, menu items, width, order, when, overrides), read from first-party v2 manifests. Owners: the sidebar lead renders the band, the slots and the Settings rows; the app platform lead owns the fields and the validator.

## 18. Third-party servers, elevated scopes, one id mapping (2026-10-04, approved by the coordinator)

Gaps found by the Cloud lead's third-party SSH sample (manaflow-ai/ssh-terminal).

- **Server kinds.** `server.kind` is `native`, `js` or `external`. First-party native servers ship inside cmux (`binaries`). A third-party native server is a signed download (`artifacts` per platform `{url, sha256, signature}`): the store listing pins the sha256, the registry checks the signature against the publisher key, and it runs only for Verified apps (`tier.nativeReview` warns), under the same OS sandbox as the app host, reached only over the provider channel. Unverified apps use `js` (QuickJS) or `external`: a process the user starts that connects to the router with an app credential the user approves in the native sheet, local only, with only its grants (pane protocol R60). Strongest objection to third-party native code: a signature proves who built it, not that it is harmless; hence Verified review, pinned hashes and the sandbox.
- **Elevated scopes.** A fourth class next to standard, sensitive and restricted: never granted at install, never checked by default; any tier gets it only by an explicit user grant in the native confirmation sheet, with a warning, origin user (the A2 gate). `terminal:backend` is elevated, so an unverified app can bring a terminal backend only when the user grants it. Manifests declare elevated scopes in `optionalScopes` (`scope.elevatedOptional`).
- **Namespaced families (coordinator decision from hq-48's IR work).** A third-party app's catalog family is its namespace, so its ops are `<namespace>.<verb>` and their scopes `<namespace>:<verb>` (`octo.ssh_terminal:read`); the validator refuses any other family (`catalog.namespace`, local dev apps included: `local.<name>`). Bare families (`git`, `fs`, `router`, `apps`, `cmux`, ...) are first-party only. Scope patterns accept dotted families, and `scope-classes.json` classes them by verb. Requesting another owner's scope (`git:read` to call cmux git ops) stays allowed; only defining a family is restricted.
- **One id mapping.** A manifest app id `<publisher>/<name>` maps to exactly one pane-protocol namespace: `<publisher>.<name>` with `-` replaced by `_` (`octo/ssh-terminal` -> `octo.ssh_terminal`, `cmux/*` -> `cmux.*`). There is no other mapping; the registry keeps publisher ids unique, and the router refuses ops outside the namespace.
- **Supervisor follow-ups (apps-v1, after the window).** Enforce elevated (no install grant; user grant only through the sheet) and `external` (credential admission); start an app's native server when the app is enabled (`server.lifecycle.start`), first user the cmux Cloud app's `cmux-cloud` server; verify the hosting app connection by its peer code signature (shared task, cmux-tui reviewer).
