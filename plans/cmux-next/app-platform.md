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
