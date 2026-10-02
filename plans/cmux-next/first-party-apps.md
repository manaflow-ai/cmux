# First-party cmux apps, app tiers and the app sandbox

Status: proposal 2, lane 3 lead, 2026-10-02. Inputs (binding): cmux-next-spec `spec/app-platform.md` (draft 1), decisions D50 (first-party apps), D51 (three tiers), D52 (security and complete sandboxing), P5 (no studied-product names in public repos), `spec/identity-and-permissions.md` (grants, approval modes), plans/cmux-next/app-platform.md (implementation plan), OWNERSHIP-PRINCIPLES.md, skills/cmux-next-feature. Only the coordinator writes the spec; this file is the lane 3 proposal ("spec proposal: first-party apps").

## 1. Summary for agents

- Five first-party apps run on the app platform and use only the public app API (the generated `cmux` global, the view builders, the manifest): **search**, **inbox**, **notes**, **coderouter** (UI and onboarding for CodeRouter) and **usage** (plan usage and limits in the macOS menu bar). They are the platform's proof: anything they cannot do with the public API is a platform gap (section 3), never a private hook.
- Sources live in `first-party-apps/<name>/` (manifest `cmux-app.json`, `src/main.ts`, built `dist/main.js`, bun tests, preview fixtures, README). App ids are `cmux/<name>`. `bun first-party-apps/build.ts [--check]` packs and validates all of them.
- Each app has two or three design variants, selected by the app setting `variant` (marked `x-cmux-devOnly`, a DEV/NIGHTLY switch) and the palette command "Next <App> Variant". Lawrence picks after dogfood.
- Three tiers (D51): first-party, Verified, unverified (section 4). One sandbox model for all tiers, with a "complete sandbox" switch any user can turn on for any app (D52, section 5).
- Operations that do not exist yet are called with `cmux.call("<family>.<verb>")` and listed per app as "Proposed operations"; they answer `operation.unsupported` until an owner implements them, and the apps show what is missing.

## 2. The apps

| App | What it does | Contributions | Core scopes | Recommended variant |
| --- | --- | --- | --- | --- |
| search | finds workspaces, tabs, terminal text, browser pages, notes, inbox items and files, and opens the result | command `search` (palette, MCP), sidebar section, pane kind | `workspace:read`, `terminal:read`, `browser:read`, proposed `history:read`, `fs:read` (granted roots) | `grouped` (section 8) |
| inbox | a view on the feed (N10: notifications and agent requests are one system owned by a per-user Durable Object): triage, open, answer requests, done, snooze; it keeps no item model of its own | sidebar section, status item (count), commands, pane kind | `notification:read`, `notification:write`, `agent:read`, `workspace:write` (open), `integration:github:read` | `grouped` (section 8) |
| notes | markdown notes, global and per workspace; quick capture; agents read and append through MCP tools | sidebar section, commands (MCP), pane kind, search provider | storage (proposed documents store), `workspace:read` | `scratchpad` (section 8) |
| coderouter | CodeRouter status, provider accounts, keys, usage, routing, test request; first-run onboarding | sidebar section, status item, commands, pane kinds (dashboard, onboarding) | proposed `coderouter:read`, `coderouter:write`, restricted `coderouter:keys` | `checklist` (section 8) |
| usage | per provider and account: session and weekly windows, percent used, reset time, pace, warnings | status item (menu bar), sidebar section, commands (MCP) | proposed `usage:read`, `notification:write` | `menuPercent` (section 8) |

## 3. Platform API gaps (what these five apps need)

Priority: P0 = an app cannot do its core job without it; P1 = the app works but worse; P2 = later. "Owner" is who must build it (OWNERSHIP-PRINCIPLES: the owner of the data serves the op and checks the grant).

### 3.1 Surfaces and contributions

| # | Gap | Needed by | Proposal | Owner | Pri |
| --- | --- | --- | --- | --- | --- |
| S1 | Pane kinds are phase 2 and not mounted | search, inbox, notes, coderouter | mount `paneKinds[].render` as a tab kind `app:<app>#<pane>` (layout record in the workspace store, scene from the app host); pull forward to phase 1 for first-party apps | app platform lead + tabs | P0 |
| S2 | No macOS menu-bar placement for status items | usage | `statusItems[].placement = "menuBar"`: one NSStatusItem per contribution, title scene of one row (text, symbol, tiny meters), click opens the contribution's `menu` export as a popover; user can hide it; at most 2 per app | app platform lead | P0 |
| S3 | No way to present a popover, sheet or panel from a scene | usage, coderouter, inbox | `cmux.ui.present(export, {as: "popover"\|"sheet"\|"panel", anchor?})` returning a mount; dismissed by the client; origin user only | app platform lead | P1 |
| S4 | `searchProviders` is phase 3 | search, notes, inbox | `contributes.searchProviders[{id, title, query: <export>}]`: the host fans a query out to providers with a deadline and merges typed results `{id, title, subtitle, symbol, source, score, open: {action, args}}`; apps never call each other directly | app platform lead | P0 for search |
| S5 | Commands exposed to agents | notes, inbox, search, usage | implement the generated MCP tool per command for apps holding `mcp:expose` (spec 6.5), with the command's `arguments` schema; agent calls run with the intersection of agent and app grants | app platform lead + MCP owner | P0 |
| S6 | Onboarding contribution | coderouter | `contributes.onboarding[{id, title, render, after?}]`: a step the first-run flow and Settings > Accounts can show; progress stored by the app | onboarding owner | P1 |
| S7 | Badges on a section header, the Dock and the status item | inbox, usage | scene prop `badge` on the contribution root, read by the section header; `notification.badge` is not an app op | sidebar sections lead | P1 |
| S8 | Keyboard shortcuts for app commands | search, notes | app commands appear in KeyboardShortcutSettings and `cmux.json` keymaps under their global id | actions lead | P1 |
| S9 | Mount context lacks the client's current workspace | notes (scratchpad), search (scope) | mount `ctx.workspace`, `ctx.window` and a `client.current` read (per-client view record, published by the client, OWNERSHIP-PRINCIPLES) | app platform lead | P1 |

### 3.2 Scene nodes (renderer)

| # | Gap | Needed by | Proposal | Pri |
| --- | --- | --- | --- | --- |
| N1 | No multi-line editor | notes | `TextEditor(value, {placeholder, onEdit, onSubmit?, syntax: "plain"\|"markdown"})`; text, selection, undo and IME stay in the client; the app gets debounced `edit {text, revision}` | P0 |
| N2 | No rich text | search (match highlight), notes (preview) | `Text` accepts `runs: [{text, weight?, color?, monospaced?, highlight?}]`; and a read-only `Markdown(text)` node (no HTML, no remote images) | P0 for search |
| N3 | No meter or gauge | usage, coderouter | `Meter({value, limit?, tick?, tone})`: a thin bar with an optional pace tick; stacked variant for the menu bar | P0 for usage |
| N4 | No toggle, picker, segmented control | all | `Toggle`, `Picker(options)`, `Segmented(options)` with `onChange` | P1 |
| N5 | No list selection or keyboard navigation | search, inbox | `List({items, selection, onSelect, onActivate})`: arrow keys, Return, type-to-select owned by the client | P0 for search |
| N6 | No host-owned secret field | coderouter | `SecureField({target: {op, param}})`: the client sends the typed value straight to the op through the host; the VM never sees it (section 5.6) | P0 for coderouter |
| N7 | No sparkline or small chart | usage, coderouter | `Sparkline(values)` | P2 |
| N8 | No table or grid | coderouter, usage | `Grid(columns, rows)` | P2 |

### 3.3 Data and operations

| # | Gap | Needed by | Proposal (smallest primitive) | Owner | Risk / scope | Pri |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | Change events with payloads | inbox, search, usage | `notification.changed`, `agent.changed`, `workspace.changed`, `tab.changed` streams with typed payloads and `invalidated_by` catalog metadata so `cmux.live` refreshes without polling | daemon (D7 catalog) | read | P0 |
| D2 | Terminal text search | search | `terminal.search {query, regex?, case_sensitive?, terminals?, limit}` -> `[{terminal, tab, line, column, preview}]`, cancellable, capped | session host (transcripts) | read, `terminal:read` | P0 |
| D3 | Browser history search | search | `browser.history.search {query, limit}` | browser history store | read, new `history:read` | P1 |
| D4 | File search and read in granted roots | search, notes (folder option) | `fs.search {root, query, include?, exclude?, limit}`, `fs.read {path}`, `fs.write {path, text, expected_revision}`; roots are workspace folders or user-picked folders bound to the grant (section 5.3) | session host on the machine that has the files | read / mutate-own, `fs:read`, `fs:write` | P0 for search |
| D5 | Document storage larger than KV | notes | `app.documents.list/get/put/delete {id, body, expected_revision}`: per-app documents, 50 MiB local, synced through `UserDO` with per-document revisions (compare-and-set, conflict copy) | app supervisor (local) + `UserDO` (sync) | mutate-own, own data | P0 for notes |
| D6 | Provider usage without credentials | usage, coderouter | `usage.list {provider?}` -> `[{provider, account, plan, windows: [{kind, label, percent, used?, limit?, resets_at, pace}], fetched_at, stale, error}]`, `usage.refresh`, event `usage.changed`; the owner reads credentials, fetches with backoff and stops while no subscriber is visible | native usage service (in the app, later the daemon) | read, `usage:read` | P0 for usage |
| D7 | CodeRouter control plane | coderouter | `coderouter.status`, `coderouter.accounts.list/connect/remove/share`, `coderouter.keys.list/create/revoke`, `coderouter.usage.get`, `coderouter.route.test`; cloud catalog entries; `connect` and `keys.create` take or return opaque handles only | CodeRouter control plane (cloud) + native accounts service (detection) | read / mutate-own / mutate-shared; `coderouter:read`, `coderouter:write`, restricted `coderouter:keys` | P0 for coderouter |
| D8 | Integration gateway not implemented in the host | inbox, search | implement `integration.request` through `ConnectionDO` (D39); today the host answers `operation.unsupported` | integrations lead | read / send-external | P0 for inbox |
| D9 | Current client view | notes, search | `client.current` -> `{window, workspace, tab}` from the client's own published record | client | read, `workspace:read` | P1 |

### 3.4 Runtime

| # | Gap | Needed by | Proposal | Pri |
| --- | --- | --- | --- | --- |
| R1 | No app localization | all | `l10n/<lang>.json` in the bundle, `t(key, fallback, args)` in the runtime, `cmux.app.locale`; the validator checks every key has en and ja | P0 (cmux rule: all strings localized) |
| R2 | Dev-only settings | all (variants) | settings schema key `x-cmux-devOnly: true`: shown and honored only in DEV and NIGHTLY builds | P1 |
| R3 | Visibility | inbox, usage, search | `ctx.visible()` signal per mount; `cmux.timer.every` pauses while no mount of the app is visible (spec 5.2 says so; the prototype engine does not do it yet) | P1 |
| R4 | Background work without a mount | inbox (snooze wake-up), usage (threshold warnings) | declarative `contributes.notificationRules` evaluated by the host on events (no app code running), else `activation: ["onEvent:<stream>"]` that starts the app for one handler turn with a budget | P1 |
| R5 | Secret handles | coderouter | opaque `secret_…` handles: created by host UI or ops, usable only as a param of ops that declare `accepts_secret_handle`, displayable only by host UI (`ui.secret.reveal`, `clipboard.writeSecret`), never readable by the VM | P0 for coderouter |
| R6 | Approval prompts from the host | coderouter, inbox (agent reply) | per-scope approval modes from grants (`none`, `per_session`, `per_call`); the host shows the prompt and the call waits (deadline 2 min) | P1 |

### 3.5 Found while building the prototypes

| # | Gap or bug | Found by | Proposal | Owner | Pri |
| --- | --- | --- | --- | --- | --- |
| B1 | Runtime bug: removing a rebuilt subtree lowers the scene node count by 1 and keeps the child handlers, so a long-lived mount that rebuilds lists reaches `app.limit` (4096 nodes) although few nodes are live (a 9-node child rebuilt 600 times is enough) | search, usage | count and release the whole subtree in `materialize.ts`; add a churn test | app platform lead | P0 |
| B2 | The user origin of a tap ends at the first `await` in the handler; commands run from the palette or a keybinding carry origin `script`, so they cannot move focus | inbox, coderouter | the gesture token covers the handler's promise chain until it settles (bounded, for example 2 s), and commands invoked by a user gesture run with origin `user` | app platform lead | P0 |
| B3 | Unknown ops are refused locally as `scope.missing` without naming a scope | coderouter, usage | answer `operation.unsupported` for ops not in the scope table; `scope.missing` always names the scope | app platform lead | P1 |
| B4 | The manifest scope grammar rejects `storage:local` (which `scopes.json` uses) and has no restricted level (`coderouter:keys` was renamed `coderouter:control` to validate) | coderouter, notes, search | accept `storage:local`; add a restricted marker in `scopes.json` (`restricted: true`) instead of a name level | app platform lead | P1 |
| B5 | Apps cannot write their own settings, so "Next <App> Variant" keeps its value in app storage | all | `app.settings.set {key, value}` (config layer, mutate-own, own app only) | config layer | P1 |
| B6 | Every command becomes an MCP tool | notes, usage, inbox | command flag `mcp: false` | app platform lead | P1 |
| B7 | No unmount hook (`onCleanup`), no way to query granted scopes, `untrack` and the `CmuxError` constructor are missing from `cmux-app.d.ts` | inbox, coderouter, usage, search | add `onCleanup`, `cmux.app.scopes()`, typings | app platform lead | P1 |
| B8 | No container width in the render context, no stack alignment, no menu item checked state, no relative-time text node (countdowns wake the app once per minute) | usage, search, inbox | `ctx.width()` signal, `alignment` prop, `checked` menu prop, `RelativeTime(date)` node rendered by the client | app platform lead | P1 |
| B9 | Scopes take no parameters (file roots), no app op opens its own pane or reveals its section, no section header badge, no `notification.create` dedupe key across machines | search, inbox, usage | `fs:read` roots as grant selectors (5.3), `app.pane.open` / `sidebar.section.reveal` (origin user), `app.badge.set`, `dedupe_key` on `notification.create` | app platform lead, sections lead, daemon | P1 |
| B10 | `notification.ack` client id for apps | inbox | the host sets `client_id = app:<id>` for app calls so read state is shared across clients through the daemon ledger | session host | P1 |
| B11 | Spec 6.5 forbids account and credential ops for all apps; the CodeRouter app needs a carve-out for first-party and reviewed apps, through host-owned flows only | coderouter | restricted scopes (section 4) may hold credential flows that take or return secret handles; the raw "never" list stays | spec (coordinator) | P0 for coderouter |

## 3.6 Store layout (Lawrence, 2026-10-02)

Cards: the App Store uses cards by default (`apps.store.layout = grid`), and app sidebar sections use the card look by default (`apps.section.look = card`). The list and split store layouts and the native and minimal section looks stay behind the DEV/NIGHTLY switch until they are removed.

## 3.7 Install defaults and hiding (Lawrence, 2026-10-02)

- First-party apps are installed by default; sample apps are opt-in.
- A user can install an app and hide it: no presence in the sidebar, palette, menus or menu bar, while CLI, MCP and automations can still run it when the user allows that. Hide is distinct from disable and uninstall, per user and synced. State model, ops, surfaces and tests: plans/cmux-next/app-platform-critique.md C7.

## 4. Tiers (D51)

| | first-party | Verified | unverified |
| --- | --- | --- | --- |
| Who | publisher `cmux` (also `manaflow-ai`), built from this repo | a publisher whose GitHub owner identity cmux verified | anyone: attested store release, direct repo install, or `local/` development app |
| Review | cmux code review (this repo's merge gate) and the release signature | identity + Sigstore attestation bound to repo, workflow and commit + automated scan (manifest, scopes, bundle) + human review of the code for every version that adds `execute`, `external` or restricted scopes | attestation if present, automated checks only |
| Store | featured, bundled with cmux (runs offline, updated with cmux or the store) | listed, searchable, badge "Verified" | hidden from search until staff set a tier (D45); install by id or URL after a warning |
| Default grant at install | required scopes granted without a sheet, listed in Settings > Apps; optional scopes ask when first used | consent sheet listing every scope with its reason; `execute` and `external` scopes unchecked by default | consent sheet; read scopes only by default; `execute`, `external` and `net:` scopes each need an explicit toggle and default to approval `per_session` |
| Restricted scopes (`coderouter:keys`, `usage:read`, `fs:write`, `mcp:expose`, `clipboard:write`) | allowed | only those the human review approved for that version | never |
| Default sandbox (section 5) | Standard | Standard | Contained (and the store offers "Install sandboxed") |
| Updates (D49 `sameScopes`) | with cmux or automatically | automatic only when the scope set is unchanged AND the version is reviewed when it needs review; otherwise the old version keeps running | automatic only when scopes and code hash allowlist are unchanged; otherwise ask |
| Limits per VM | 64 MiB, 250 ms per evaluation, 64 pending calls | 32 MiB, 250 ms, 64 | 16 MiB, 100 ms, 16, net calls rate-limited to 1/s burst 10 |
| Team policy (`apps.allowedTiers`, allowlist, forced sandbox) | can be disabled per app, never forced on | allowed by default | off by default for teams that set a policy |

Rules that hold for every tier:
- No tier gets a private API. First-party apps use the same generated `cmux` global and the same scope checks; the only difference is which scopes a tier may hold and the defaults.
- `money`, `destructive`, grant, install, policy, account and credential ops are never callable by any app (spec 6.5 "never").
- The tier is a property of the listing version (owner `AppDO`), shown everywhere the app appears (store, Settings > Apps, consent, the permissions sheet), and copied into the install record so a revoked Verified status takes effect at the next grant check.

## 5. The app sandbox (D52)

### 5.1 Model

An app's reach is one **grant** (identity-and-permissions.md section 4, grantee `app:<id>`, issuer the user or a team admin) plus one **sandbox profile**. The grant lists scopes with an approval mode each and optional resource selectors. The profile caps what the grant can contain and sets the OS-level containment of the app host. Effective reach = grant ∩ profile ∩ installing user's own rights ∩ team policy ∩ (for an agent calling the app's MCP tools) the agent's grant.

| Axis | What an app can reach | How it is granted | Enforced by |
| --- | --- | --- | --- |
| cmux operations | catalog ops whose scope it holds (`workspace:read`, `terminal:execute`, ...); resource selectors narrow them (only these workspaces, only this space, only this machine) | consent sheet, Settings > Apps > Permissions | the owner of each op (authoritative); the supervisor and runtime filter early |
| Network | only `net:<host>` hosts it holds, HTTPS only, through the supervisor; no cookies, no user credentials, `Authorization` stripped unless the host is granted; credentialed calls only through `cmux.integrations.*` (token stays in the gateway) | per host, listed with the reason | supervisor egress gate; OS sandbox denies all sockets in the app host |
| Files | none by default. The bundle (read-only, implicit). The app's own storage and documents through ops (no paths). Granted roots: a workspace folder (`fs:read:workspace`) or a folder the user picks in a host file panel (`fs:read:<bookmark>`, `fs:write:<bookmark>`) | the host file panel (powerbox style: the app asks, the user picks, the app never names a path it was not given) | the session host serving `fs.*` (realpath inside the root, no symlink escape, size caps); OS sandbox denies file reads outside the bundle cache |
| Processes | never spawns anything. Commands run only through cmux ops that run in a visible terminal (`workspace.run`, `pane.run`, `terminal.input.*`, risk `execute`) | explicit toggle, strong warning, approval `per_session` default | the session host; OS sandbox denies `process-exec` and `fork` |
| Secrets | never inside the VM (section 5.6) | n/a | the host and the gateway |
| Clipboard | write only, `clipboard:write`; never read | toggle | the client |
| Notifications | `notification:write` (posts carry the app as source and can be muted per app) | toggle | daemon notification ledger |
| Agents | `mcp:expose` offers the app's commands as MCP tools | toggle | MCP server: agent grant ∩ app grant |
| UI | only where the user placed a contribution; never focus, selection or scroll changes outside a user tap turn (origin rule) | placement | client + origin check |
| Resources | memory, evaluation time, pending calls, timers, scene nodes, storage quota per tier | fixed per tier, Debug tunables | app host |

### 5.2 Profiles

| Profile | Network | Files | cmux ops | Storage | Agents (MCP) | Default for |
| --- | --- | --- | --- | --- | --- | --- |
| Standard | granted `net:` hosts | granted roots | granted scopes | local + synced | if granted | first-party, Verified |
| Contained | granted `net:` hosts, each with approval `per_session` | none | read scopes; write needs a toggle; `execute` and `external` approval `per_call` | local only | off | unverified |
| Complete sandbox | none | none (bundle only) | only the scopes the user turns on by hand in the permissions sheet (all off at first) | local only | off | user choice for any app ("Run sandboxed"); team policy may force it for tiers |

"Complete sandbox" is the D52 option: no network, no file system, no cmux ops beyond granted scopes. It is a per-app switch any user can set at install ("Install sandboxed") or later (Settings > Apps > <app> > "Run sandboxed"). The app keeps running; every refused call returns `scope.missing` and the app must show what it cannot do (first-party apps do this in every variant, which the bun tests check). Switching the profile is a grant change (user origin only) and applies live.

### 5.3 File roots

A root is a grant resource selector `{kind: "workspaceFolder", workspace}` or `{kind: "bookmark", id}` (a security-scoped bookmark held by the host, never shown to the app as a path; the app sees an opaque root id and relative paths). `fs.*` ops run in the session host of the machine that has the files, so a remote workspace's folder is read on that machine. Writes need `fs:write` on that root (restricted scope). Hidden and VCS internals (`.git/`, `.env*`, `*.pem`, `id_*`) are excluded from `fs.search` and `fs.read` by default; a root may opt in per pattern only through the user.

### 5.4 Grant and revoke (user-visible)

- Install: consent sheet (tier badge, publisher, scopes grouped by axis with the manifest reasons, risk tone per scope with no blue: neutral for read, warning for write and network, danger for execute and external), profile picker (Standard / Contained / Complete sandbox, default by tier), Install.
- Settings > Apps > <app> > Permissions: every scope with its reason and a toggle, approval mode per scope (Always / Ask once per session / Ask every time), resource selectors (workspaces, spaces, machines), network hosts, file roots (add with the file panel, remove), profile switch, "Revoke all and disable", "Remove app data". The same data as JSON: `cmux apps permissions <id> --json` (read for agents; changes are user-origin only, never MCP).
- First use of an optional scope: an inline prompt in the app's own surface (the host renders it, the app cannot draw a fake one) with Allow once / Allow / Deny.
- Activity: a per-app log of op calls by scope (op, origin, result, time; never params with content), kept 7 days locally, shown under Permissions and by `cmux apps logs <id> --calls`.
- Revocation is immediate: the grant revision increments; owners check the revision on every op; the supervisor cancels in-flight calls and closes subscriptions under the revoked scope; mounted surfaces re-render with `scope.missing`. Storage is kept unless the user removes app data; uninstall removes storage and the grant in one op (spec section 8).

### 5.5 Enforcement layers

1. Owners (authoritative): every op owner checks `actor = app:<id>@<version>` against the grant revision (spec 10). Until owner-side checks land, only first-party and `local/` apps run (spec 14), and only on the prototype engine.
2. Supervisor: egress gate, file roots, approvals, rate limits, activity log, secret handles.
3. OS sandbox of the app host process (Rust host, phase 10): a seatbelt profile generated from the profile (deny network, deny `process-exec`/`fork`, deny file reads outside the bundle cache and the runtime, deny mach lookups except none, no IOKit); Linux: seccomp + Landlock. The JavaScriptCore prototype engine runs in-process and has no OS layer, which is why it never loads Verified or unverified apps.
4. Runtime: the `ops` list at init (courtesy only).

### 5.6 Secrets (no secret in the VM)

- Input: `SecureField({target})` (N6) or an op that opens a host sheet (`accounts.connect`); the value goes from the client to the owner op; the VM gets a `secret_…` handle or nothing.
- Output: ops that create secrets (CodeRouter keys) return a handle plus a redacted label (`crk_…a1b2`); only host UI shows the value once (`ui.secret.reveal {handle}`, user origin) or copies it (`clipboard.writeSecret {handle}`, user origin, clears after 60 s).
- Credentialed HTTP: `cmux.integrations.<provider>.request` (gateway); `cmux.net.fetch` never attaches user credentials.

## 6. How prototypes are built and shown

- App code: `first-party-apps/<name>/src/*.ts`, pure model functions tested with bun (`bun test first-party-apps/<name>/test`), render tests with the runtime's FakeHost.
- Screenshots: a private harness renders one contribution with the real native renderer (CmuxNextApps scene renderer, JavaScriptCore prototype engine) offscreen from fixture-backed operations and writes PNGs; it never shows a window or takes focus. Screens are kept in hq scratch, not in this repo.
- In the tagged app: the prototype registry loads bundled samples only; first-party apps reach a tagged build when `scripts/cmux-next/sync-app-runtime.sh` also copies `first-party-apps/*` (request to the app platform lead) and pane kinds mount (S1). Until then the in-app path is UNVERIFIED.

## 7. Decisions for Lawrence (through the coordinator)

See the lane 3 report; each has a recommendation.

## 8. Per-app results

Screenshots are in the private hq scratch (`.cmux-scratch/nx-apps/screens/<app>/`), dark and light per variant plus empty, error and unsupported states. All prototypes ran in the offscreen preview harness and the bun FakeHost only; none ran in a tagged app (app sections and pane kinds are not mounted yet).

| App | PR | Variants (recommended first) | Strongest objection to the recommendation | Tests |
| --- | --- | --- | --- | --- |
| search | https://github.com/manaflow-ai/cmux/pull/16792 | `grouped` (native rows grouped by source, "N more", a footer that names sources it could not search); `preview` (chips, list + preview with the match highlighted); `palette` (one ranked list as a palette page) | the match shows in one subtitle line without highlight | 41 bun |
| inbox | https://github.com/manaflow-ai/cmux/pull/16795 | a view on the feed (proposed `feed.*` ops, mock owner in tests): `grouped` (rows under source, workspace or thread headers); `focus` (filter chips, list, detail with the request form); `card` (one item at a time: Open, Done, Snooze, Skip, answer) | Done and Snooze are only in the context menu, and text requests cannot be answered in `grouped` | 18 bun |
| notes | https://github.com/manaflow-ai/cmux/pull/16791 | `scratchpad` (the current workspace's scratchpad on top, other notes below); `list` (all notes, the selected one inline); `split` (list then editor; two columns as a pane) | the API has only a session-wide `focused` flag, so with two windows the current workspace can be wrong (D9) | 38 bun |
| coderouter | https://github.com/manaflow-ai/cmux/pull/16798 | `checklist` (setup as five expandable rows in the section, one-page dashboard); `wizard` (one step per screen in a pane); `tabs` (dashboard with Overview, Accounts, Keys, Usage, Routing, Setup) | uses much sidebar height, and a 300 pt column cuts long emails | 30 bun |
| usage | https://github.com/manaflow-ai/cmux/pull/16794 | `menuPercent` (gauge glyph and the tightest limit as a percent, dropdown with every window); `menuMeters` (two stacked meters, cards with pace ticks); `sidebarOnly` (status item empty until a threshold) | one bare percent does not say which limit it is | 22 bun |

| diffs, codemirror, monaco | https://github.com/manaflow-ai/cmux/pull/16850 | diffs: `split`, `stream`, `review` (auto for feed review items); editors: `statusLine`, `header`, `bare`; CodeMirror is the recommended default editor, Monaco opt-in | split: a narrow pane clips the side-by-side diff (no scroll view in the scene); Monaco has richer editing | 32 + 38 + 38 bun |
| usage (all router accounts) | https://github.com/manaflow-ai/cmux/pull/16853 | `rows` (menu bar "Cl ×1.00 · Cx ×1.40", native rows pane), `meters`, `quiet` | the menu bar text is about 16 characters for two providers, and the ratio appears only 30 min after the first reading | 24 bun |
| finder | https://github.com/manaflow-ai/cmux/pull/16868 | `listPreview`, `columns`, `dualPane` | the scene has no scroll, keyboard selection or multi-select, so the list pages 22 rows | 61 bun |
| notes (server + native editor) and inbox (real feed API) | https://github.com/manaflow-ai/cmux/pull/16870 | notes: `scratchpad`, `list`, `editor`; inbox: unchanged variants | palette commands carry no gesture token, so Export/Import work only from the section menu | 26 + 29 bun |
| install / enable / hide (Platform v2 V9 reference model) | https://github.com/manaflow-ai/cmux/pull/16838 | Installed list `cards` (default, Lawrence's store pick), `rows`; "Show Hidden Apps" sheet; "While Hidden" access in the permissions pane | cards use about 20% more height than rows | 42 Swift Testing (reducer, filter, wire codec, two-client convergence) |
| permissions (sandbox UI and model) | https://github.com/manaflow-ai/cmux/pull/16806 | `grouped` (scopes grouped by axis with risk tones and reasons); `flat` (one list under a "Run sandboxed" master switch); `matrix` (scope by approval mode, reasons on hover) | the tallest variant (the Settings pane is 982 pt), and its profile switch is weaker than the master switch of `flat` | 24 Swift Testing (property tests, 300 seeds) |

The permissions prototype is the Swift module `CmuxNextAppPermissions`: the pure model (`AppTier`, `AppSandboxProfile`, `AppGrant`, `AppPermissionPolicy.effectiveDecision`, `admit` for calls queued before a narrowing, `AppGrantReducer` where only the user widens and a team admin only narrows) and the three surfaces (install consent, Settings > Apps > Permissions, first-use prompt), with the DEV switch `apps.permissions.style`. Invariants checked by property tests: Complete sandbox never allows `net.*`, `fs.*` or a scope not turned on by hand; unverified never holds a restricted scope; no tier reaches an op outside the public scope table or on the never list; a narrowing never widens and voids older pending calls and session approvals; grant ∩ profile ⊆ grant. The app platform lead wires it: AppHost calls `effectiveDecision` before `AppScopeTable.refusal`, the App Store window shows the consent surface, Settings shows the permissions surface, Debug Settings gets `apps.permissions.style`.

## 9. Inbox and the feed

The inbox is a view on the feed (plans/cmux-next/feed.md, owner FeedDO). It uses the feed's real API: `feed.answer` and decline through `feed.cancel` (origin user, gesture token), the triage verbs `feed.read`, `feed.archive`, `feed.unarchive`, `feed.snooze`, `feed.openItem` for every open target (sign-in and passkey too), item ids `fi_…`, scopes `feed:read`, `feed:write`, `feed:answer`, and changes derived from the feed's op events on the client. An open request cannot be archived or snoozed. The inbox exposes no MCP tools; agents use the feed's own tools. Remaining feed gaps are listed in `first-party-apps/inbox/README.md` ("Requirements for the feed").

## 10. App servers and native panes (N13; coordinator decision 2026-10-02)

Shape (decided, first example Tasks in plans/cmux-next/tasks.md section 13): `server: {kind: "native", binary, args, catalog, hosts: ["team-vm", "cmux-server", "local"], data: "durable"}`; exactly one host per team runs an app's server (single writer); catalog entries are owned by `app:<id>` and `owner_for` routes them to that host; `contributes.paneKinds[].renderer = "native"` for first-party and Verified apps only. The inbox stays a view on the feed and has no server.

### 10.1 The first-party apps on this shape

| App | Server | Catalog entries (owner) | Native pane | Why |
| --- | --- | --- | --- | --- |
| search | none in phase 1 | none of its own: `terminal.search` and `fs.search` (session host), `browser.history.search` (history store), `search.providers.query` (app supervisor) | no (scene pane) | the data lives on each machine and already has owners; a per-machine indexer (`cmux-search serve`) comes only if `terminal.search` is too slow, and needs per-machine instances (10.2) |
| notes | `{kind: "native", binary: "cmux-notes", args: ["serve"], catalog: "catalog/notes-catalog.json", hosts: ["cmux-server", "team-vm", "local"], data: "durable"}` | `note.list/get/create/update/append/delete/pin/search`, event `note.changed` (owner `app:cmux/notes`); MCP group `note` | yes: the editor (`renderer: "native"`, NSTextView with markdown-lite); list and section stay scene trees | personal documents need one writer, revisions and sync; replaces the generic document store D5 for notes |
| coderouter | none (the server is the existing CodeRouter control plane) | `coderouter.*` owned by `cloud:coderouter` (status, accounts, keys, usage, route), `coderouter.detect` and the secret handle ops (`ui.secret.reveal`, `clipboard.writeSecret`) owned by the client | no | the control plane already exists and is shared; the app needs a catalog without a server (10.2) |
| usage | `{kind: "native", binary: "cmux-usage", args: ["serve"], catalog: "catalog/usage-catalog.json", hosts: ["local"], data: "cache"}` | `usage.get`, `usage.refresh`, event `usage.changed` (owner `app:cmux/usage` on each machine) | no | provider credentials stay on the user's Mac; the server reads them, fetches with backoff, stops while no subscriber is visible, and returns numbers only |

### 10.2 Fields the shape lacks

- **Tenancy.** "One host per team" fits team data (Tasks). Notes are per user and usage is per machine. Proposal: `server.instances: "team" | "user" | "machine"` (default `team`); `user` runs one writer per user (on the user's cmux server, else their primary Mac), `machine` runs one per enrolled machine that has the app.
- **Catalog-only apps.** search and coderouter own no server but declare or depend on catalog entries owned elsewhere. Proposal: top-level `catalog` without `server`, and `requires: ["terminal.search", ...]` so the store hides the app where the owner op is missing.
- **Data classes.** `data: "durable"` only. usage needs `cache` (lossy, never synced, deleted on uninstall); notes needs `durable` plus sync to the user's devices. Proposal: `data: "durable" | "cache" | "none"`, `sync: "none" | "user" | "team"`.
- **Server principal and scopes.** The server needs its own principal (`app:<id>/server` on behalf of the user or team) and its own scopes (egress hosts, integrations, local files such as provider credential paths for usage). Proposal: `server.scopes` with reasons, shown in consent next to the client scopes; local file reads of the server are listed paths (`fs:read:~/.codex/auth.json`), which the OS sandbox of the server process enforces.
- **Lifecycle.** Start on demand vs always on, idle stop, resource limits per tier, logs, health. Proposal: `server.activation: "always" | "onDemand"`, `server.limits` capped by tier.
- **Platform per binary.** A native binary needs a build per OS and architecture and its own signature; `binary` needs a map `{"macos-arm64": ..., "linux-x86_64": ...}` and an attestation per artifact (spec 9).
- **Id grammar.** Tasks uses `dev.cmux.tasks`; the manifest id grammar is `<publisher>/<name>` (`cmux/tasks`). One of them must change; this proposal uses `cmux/<name>`.
- **Who may use `server` and `renderer: native`.** A native binary or a native pane is third-party native code, which spec section 1 excludes. Proposal: first-party only for `server.kind = native` until a WASM or sandboxed-process server kind exists; Verified apps get `paneKinds.renderer = native` only as a reviewed web pane (no native code from Verified publishers).

### 10.3 What native panes change for the gap list

A native pane removes the editor gap (N1) for notes and the keyboard list gap (N5) for search panes, but only for first-party apps; the scene API still needs them for everyone else and for the sidebar sections. The prototypes keep their scene-tree panes so the public API stays proven; a native notes editor is the one exception recommended now.

## 11. Email as a feed source (Lawrence 2026-10-02: email is mostly part of the feed)

There is no mail store and no mail app with its own model. Mail reaches the user as feed items, owned by the feed (lane 9); this section is the lane 3 proposal to the feed lead.

- Source: a mail connection in the one integration model (`ConnectionDO`, provider Gmail or IMAP/JMAP; credentials stay in the gateway). A feed source (`cmux.feed.source/1`, run by the integrations side or an app server with `instances: user`) receives provider push (Gmail watch, JMAP push, IMAP IDLE in the server; never polling from a client) and posts one feed item per thread.
- Storage rule (spec integrations.md S2: email is never stored): the feed item holds ids only (`connection`, `thread_id`, last `message_id`, `history_id`, received time) plus the triage state. Subject, participants and snippet are fetched through `mail.get` when a client renders the item and are held only in that client's memory; a feed item for mail therefore has a display resolver (the mail source) instead of stored title and body. Question for the feed lead: support resolver-backed items whose display fields are never persisted.
- Item kind: `notify mail.thread` for threads that need no answer, `request reply` when the user's rules or an agent mark the thread as needing a reply. Display fields resolved on render (never stored): `thread {subject, participants (display names; addresses only on open), message_count, last_message_at, labels}`, a snippet, attachments as handles, and `unsubscribe` metadata.
- Thread updates replace the item's content and bump its revision (one item per thread, `thread` group key = provider thread id), so the feed never shows one row per message.
- Triage actions are feed actions mapped to provider ops by the source: done (archive), snooze (the feed owner wakes it; the source only mirrors the label), mark read (provider seen flag), label, mute thread, unsubscribe.
- Reply: `feed.respond {item, value: {body, reply_all?, attachments?: handles}}`, origin user; the source sends through the gateway (`send-external`, never an agent tool without approval). Agents may draft: `feed.draft {item, body}` creates a draft visible in the item, which the user edits and sends.
- Reading a message body: `cmux.viewer/1` for `message/rfc822` (sanitized HTML in a sandboxed web view with remote images blocked until the user allows them per sender) opened from the item.
- Search: the mail source implements `cmux.search.provider/1` against the provider's search API.
- Questions for the feed lead: (1) does the feed item support a replaceable body and a per-thread group key with revision bumps; (2) does `feed.respond` carry rich values (body + attachment handles); (3) who owns drafts (feed owner vs mail source); (4) per-source triage action mapping (done = archive) declared by the source; (5) privacy: addresses and bodies fetched on open only, not stored in the feed.

## 12. Open points against Platform v2 (app-platform.md section 12)

The apps follow v2. Points where building them found a gap or a naming problem:
- Connection handle name: v2 V6 says `host_…`, but `host_…` is already the public registry id of an enrolled host (listable, so not a grant), and plain SSH hosts have none. Proposal: `conn_…` for the connection handle an app holds (plans/cmux-next/finder.md).
- Gesture tokens (V11) are explicit, which is right, but palette and keybinding invocations of app commands must carry one too; today they do not, so user-only ops (export, import, answer) fail from the palette.
- Scope grammar: `feed:answer`, `ui:embed`, `account:*` and `power:*` must be accepted by the manifest validator (the prototypes fell back to other names).
- Missing from v2: an `Embed` scene node (embedding from a scene, not only from a web pane), a scroll view, drag and drop props on scene nodes, pane-routed commands (Cmd-S to the focused editor pane), the terminal theme in the pane init, a hunk-decide op that works for every diff producer, `fs.thumbnail`/image handles, and `app.pane.open` with a gesture.
- Web pane CSP: editors need `style-src 'unsafe-inline'` (scripts stay `'self'`).
