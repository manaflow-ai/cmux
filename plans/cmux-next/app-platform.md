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
| Feed email, Integrations | `cmux.feed.source/1`, integration connections, credential handles, `cmux.viewer/1` for bodies |
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
