# cmux-next spec coverage audit

Audit date: 2026-10-03. Spec: manaflow-ai/cmux-next-spec origin/main 7863ac035f96 (decisions.md, spec/*.md, every plan-*.md). Code: feat-cmux-next at fc7e9f19bfe. Owners: the worker lane state (lanes L1 to L21, with agent ids) and the "Active streams" section of COORDINATION.md (coordinator leads, no agent id here).

This file answers one question: does every spec item that is not done have an owner? Each row is one spec item: a feature, a decision with a build consequence, or a plan step.

## Status rules

- DONE: code on feat-cmux-next proves it (a short sha or a file path that was checked). A plan or a prototype counts only for a "write the plan" or "build a prototype" item.
- IN PROGRESS: an owner exists (a worker lane with its agent id, or a coordinator lead) and work remains. Work on an unlanded branch is IN PROGRESS, not DONE.
- NO OWNER: nothing landed and no lane or lead clearly owns it. "Unverified" in a note means the auditor could not prove the status.
- "Coordinator: X lead" means the coordinator assigned that stream. This audit did not check that the lead agent is running.
- Every lane was unparked at 2026-10-03 02:10Z, so a parked lane with open work counts as an owner.

## Totals

| Area | DONE | IN PROGRESS | NO OWNER |
| --- | --- | --- | --- |
| App shell and UI | 34 | 36 | 8 |
| Platform core | 39 | 36 | 19 |
| Backend, Home, iOS, ghostty-next | 38 | 36 | 22 |
| App platform, first-party apps, Finder, feed | 25 | 63 | 15 |
| Browser, passkeys, computer use, agent pane, remote desktop | 18 | 44 | 21 |
| VM image, server, transport, release, fleet | 24 | 30 | 15 |
| Cloud, automations, team VM, network policy, egress | 28 | 16 | 49 |
| Enterprise, integrations, Tasks | 30 | 37 | 19 |
| Total rows | 236 | 298 | 168 |

Some items appear in two areas (for example TeamVmDO, P10 and git actions), so the totals count a few items twice. The NO OWNER work packages at the end remove the duplicates: 168 NO OWNER rows fold into 26 work packages plus one decision batch for Lawrence.

## Findings that need action now (not NO OWNER rows)

1. Mac Home is not reachable in the app. The overlay was removed in 73dc69fc6f0, HomeHostView is never created, and the sidebar Home item sends `home.show`, which no longer exists. CmuxNextHome does not use CmuxHomeCore or CmuxHomeRender. Owner: coordinator Home lead (with L16). Lawrence asked that Mac Home "work for real" (IOS2).
2. Home ops are not routed in the API Worker (ownerRoute has no Conversation, Mux or Address owner). This blocks iOS CloudHomeSource (L14), Mac cloud Home, sends, and every NO OWNER Home package. Owner: coordinator backend lead.
3. Per-user tunnel and firewall ops live in UserDO (b8093c65137). The spec puts team network policy in TeamDO. Expect a conflict with the unlanded network-policy branch. Owner: L12 and backend lead.
4. The CodeRouter plan lets VM tokens manage the account pool. The spec denies account rights to automation VM tokens. Owner: none (package 20).
5. SV-R4 is not applied: cmux-server-core still sets 0700 on the user-mode root. Owner: L10.
6. Effect is pinned to 4.0.0-rc.117, not the 4.0.0 release (D25 wants exact pins of the release). Owner: backend lead.
7. The bottom band default has an extra icon-only Customize item between Settings and the account icon (56f2f5c247c). S11 says only Settings and the account icon. Lawrence must confirm.
8. S7 asks for the license to be recorded in the copy commit of the reference code. No license record was found. Owner: ACP/agent pane lead.
9. The agent pane calls `file.search`, but no Rust handler serves it (package 7).

## App shell and UI

Source: spec/sidebar-sections.md, spec/visuals/**, spec/plan-tab-search.md, spec/plan-palette-scopes.md, decisions S10-S22, U0-U10, L1-L3, W2, PA1-PA3, B11, P2, S6, D59.

### Sidebar sections

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Document model, reducer, invariants L1-L6 (s4, phase 1) | DONE | 9c2d458fb75, 96e8343fec6 | Pure Swift reducer with tests. |
| Three regions, pinned bands, looks (s1, phase 2) | DONE | 9ef77a69a9b, 3c7de1001eb | - |
| Name "sections", quiet default, other looks selectable (S10) | DONE | 4cf5428b947, f9373809a84 | - |
| Bottom band on one line: Settings left, account icon right (S11) | SUPERSEDED | f9373809a84 | Leo 2026-10-03: the rail is on by default; the bottom band holds only the account, and Settings and Customize Appearance sit under the rail's More menu (sidebar-sections.md 11). The old layout is `SidebarLayoutDocument.preRailDefaults`. |
| Per-section arrangement list, inline, grid; pinned tiles (S12) | DONE | f9373809a84, d7160cb104b | - |
| Band caps 1/3 and 1/4, customizable (S13) | DONE | f9373809a84 | - |
| Custom icons: emoji, SF Symbol, image for workspaces and Home (S14) | IN PROGRESS | coordinator: sidebar sections lead | Emoji (3861b421977) and symbol landed. Image icons and the Home icon remain. |
| Home is a workspace, kind home (S15) | IN PROGRESS | coordinator: Home lead | Rust kind landed (f735b1d338e). Swift lacks hidden tab bar, not-closable rule and conversation tab. |
| App Store under Home; Remove from Sidebar / Section; Hide (S21) | DONE | 66f56024be6, cc5f77639e4 | Rust CLI verbs are a separate row. |
| Card look for App Store and app sections (D59) | DONE | cdd35a1bc8b | - |
| Spaces scope per section (s3) | DONE | 0ca817a795c | - |
| Registry actions, palette targets, SidebarLayoutService (s6) | DONE | 0ca817a795c | - |
| Optional titles, edge fades, hover-only room plus | DONE | 4cf5428b947 | - |
| Cmd-1 rule, Home highlight, collapse saved per window, arrow keys across regions | IN PROGRESS | coordinator: sidebar sections lead | `firstTopItem` has no caller. Collapse lives only in SidebarModel. |
| Store `sidebar-layout-v1` in cmux-tui-core, Rust reducer, proptest (phase 4) | IN PROGRESS | coordinator: sidebar sections lead | Client mirror landed (4eacb7d418f). Rust store on unlanded branches. |
| Rust CLI `cmux sidebar` verbs and MCP (S21 CLI parity) | IN PROGRESS | coordinator: sidebar sections lead + Rust CLI owner | Interim path is `cmux action run`. |
| pinToSection, `sidebar layout --json`, import/export | IN PROGRESS | coordinator: sidebar sections lead | Not started. |
| Drag and drop between sections and regions; tab, space, url items | IN PROGRESS | coordinator: sidebar sections lead | No drag code yet. |
| Sort, filter, density, header badges, rename and icon override (U0) | IN PROGRESS | coordinator: sidebar sections lead | Backlog. |
| Window rail as a sections region | DONE | 1280059aae6 | - |
| Open: collapse per window or synced; do sections replace the space bar (s9) | NO OWNER | - | Lawrence has not decided. |
| Agent session list location (S6, open) | NO OWNER | - | Undecided. |

### Windows and Settings

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| W2 spec plans/cmux-next/windows.md | IN PROGRESS | L20 ab4c04f51fc5eb90c | Not on feat-cmux-next yet. |
| W2 WindowKind registry and one factory: traffic lights, theme before content, close semantics | IN PROGRESS | L20 ab4c04f51fc5eb90c | Settings and Debug windows set theme first (99fe2696590). No registry. |
| W2 one shortcut table per key window kind; test over every kind x shortcut | IN PROGRESS | L20 ab4c04f51fc5eb90c | `KeyRouter.KeyWindowKind` exists. No table and no test. |
| W2 `debug.window_snapshot` for every kind | IN PROGRESS | L20 ab4c04f51fc5eb90c | Not landed. Unblocks the visuals recapture. |
| Settings and Debug Settings open as panes (S22) | DONE | 99fe2696590 | Shared InternalPageTabStore. |
| App Store opens as a pane (S22) | IN PROGRESS | coordinator: app platform lead | Branch apps-store-pane f5548642b3f unlanded. Still a window. |
| Standard close button on every remaining window (S22) | IN PROGRESS | L20 ab4c04f51fc5eb90c + coordinator: app platform lead | Settings, Debug, onboarding done. App Store close button still hidden. |
| Cmd-W in a secondary window closes that window's content (S22) | IN PROGRESS | L20 ab4c04f51fc5eb90c | Branch 586af176c23 (17061) unlanded. |
| Debug Settings through the palette, DEV/NIGHTLY (S16) | DONE | 222f8374f36 | - |
| Every default is a setting; MDM can lock it (U0) | DONE | 6aa4a6e1170 | Each new feature must still add its setting. |

### Pane and tab chrome

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| focusIndicator both; unfocused tabs fade 0.35; tonal/quiet in Debug (S16) | DONE | be56dd8f395, 6200ee73090 | - |
| Tab bar background = window, darker optional (S17) | DONE | be56dd8f395 | - |
| `appearance.borders = none` app-wide (S18) | DONE | e81111be7b3, 8d7238e86ee | Checkbox and pill-ring follow-up landed. |
| Focus ring subtle by default, contrast setting (S18) | DONE | 1d7c9a299af | - |

### Status indicators

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| One shared indicator, styles arc/native/dot/none, one setting (U1, U5) | DONE | 6388291c7c3, 03937a5db39 | Sidebar rows, group headers, tabs. |
| Indicator on every surface: browser loading, pane headers, Home, section items, hover card (U1) | IN PROGRESS | coordinator: status indicator lead | Not adopted on these surfaces. |
| A status's `--style` wins, per-source opt-out (U2, U6) | DONE | 2ac67ec79a4 | - |
| Inferred busy after 3 s (U3, U7) | IN PROGRESS | coordinator: status indicator lead | Swift settings landed. Daemon `extra.busy` on unlanded branch status-rust. |
| `status run` notify at 10 s when not visible (U4, U8) | IN PROGRESS | coordinator: status indicator lead | Settings exist. Visibility decision and CLI remain. |
| Daemon `workspace_status.set` fields, TTL/owner clear, CLI `status set/clear/list/run` (U9) | IN PROGRESS | coordinator: status indicator lead | Branch status-rust 896d36f7dbc unlanded. |
| `cmux status wait`, `terminal wait --until idle/prompt` (U9 later) | IN PROGRESS | coordinator: status indicator lead | Not started. |
| Style none hides only loading (U10) | DONE | CmuxNextDesign/StatusIndicator/StatusIndicatorPlan.swift | - |

### Layout model

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Design A frame, TLA+ FRAME config (L3 step 1) | DONE | plans/cmux-next/formal/LayoutRows_frame.cfg | - |
| App four-edge geometry, `layout.frameOrientation`, Docked/Floating (L3 step 4) | DONE | d627a5c06a1, ebd02055eaf | - |
| Reducer Pin/dock ops and proptest (L3 step 2) | IN PROGRESS | coordinator: layout model lead | Branch layoutmodel 3d3ff9ba033 unlanded. |
| Daemon `edge-docks-v1` (L3 step 3) | IN PROGRESS | coordinator: layout model lead | Branch docks 62a636157e9 WIP. |
| Drop edge bands, vertical reveal for top/bottom docks | IN PROGRESS | coordinator: layout model lead | Waits for edge-docks-v1 and rows. |
| Dock surfaces and actions (L3 step 5) | IN PROGRESS | coordinator: layout model lead | Not started. |
| Excellent left/right docked columns (L1) | DONE | 1af7d77913d | dock-columns-v1. |
| Column-major and row-major both exist (L2) | IN PROGRESS | coordinator: rows lead + layout model lead | Orientation landed. rows-v1 and InsertRow unlanded. |

### Search Tabs

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Cmd-Shift-A page: all tab kinds, recently closed, Return reveals, Cmd-W closes row (S19) | DONE | 4893c251a9d | - |
| `recent` default, empty query selects previous tab (PA1) | DONE | 4893c251a9d | - |
| Focus TextBox moves to Cmd-Opt-A (PA1) | DONE | 4893c251a9d | - |
| "Go to Tab..." opens Search Tabs; live closed list; search off main (PA1) | DONE | 55bccfcdb90 | - |
| Socket `tabs.search`, `action.run` focus rule | DONE | 4893c251a9d | - |
| Rust CLI `cmux tab search` and MCP `tab_search` | IN PROGRESS | L2 a296de9f96fe5e5a7 | Not in the Rust CLI yet. |
| Daemon `foreground_process` per terminal (PA1) | IN PROGRESS | L2 a296de9f96fe5e5a7 | Only process-info has the executable. No mirror field. |
| Favicons in rows | NO OWNER | - | Not in the L2 follow-up list. |

### Palette scopes

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Proposal (step 1) | DONE | fdf412bf7a8 | - |
| PaletteNavReducer, descriptor, graph, property tests (step 2) | DONE | fdf412bf7a8 | - |
| Chip UI, scope list, Backspace pops (step 3, PA2) | IN PROGRESS | L11 afb07bff3d5bef67b | Branch 7eff64722bf (16849) unverified and unlanded. |
| Search Tabs as scope `tabs` (step 4, PA2) | IN PROGRESS | L11 afb07bff3d5bef67b | Inside 16849. |
| `palette.open/scopes/query/run` catalog, socket, CLI, MCP (step 5) | IN PROGRESS | L11 afb07bff3d5bef67b | Waits for step 3. |
| Built-in scopes waves 2-3: history, apps, files, feed | IN PROGRESS | L11 afb07bff3d5bef67b | Files needs a daemon index. Feed needs L9. |
| App contributions `contributes.paletteScopes`, Swift bridge, sample (step 6, PA3) | IN PROGRESS | L11 afb07bff3d5bef67b + coordinator: app platform lead | Schema and runtime landed (a835b277bd6). Swift bridge branch 99ad2f1a562 unlanded. |
| `ctx.gesture` keeps user origin across await (s6.7) | IN PROGRESS | L3 a98142a865bc6d642 + coordinator: app platform lead | Waits for 17008. |
| Documents scope, cross-app scope composition, embed slot (s6.8) | NO OWNER | - | Depends on documents and embeds (unverified). |

### Visuals and pixel parity

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Design tokens md/json, component state pages, capture tools | DONE | 6200ee73090 (plans/cmux-next/spec-proposals/visuals) | - |
| `focus.inactiveTabStyle` and `sidebar.sectionLook` as cmux.json keys | DONE | 6200ee73090 | - |
| Recapture stale sidebar and window reference images (P2) | IN PROGRESS | spec visuals a5cb7e0b8ec8bba1e | Parked. Blocked on `debug.window_snapshot` or a Screen Recording grant. |
| Images for unverified states: debug verbs for pressed, hover card, status, palette hover (P2) | NO OWNER | - | Only `debug.drop_highlight` exists. |
| Ports derive tokens from design-tokens.json and pass the oracle (B11) | IN PROGRESS | coordinator: GPUI lane | cmux-theme-tokens does not read the json yet. |
| GPUI and browser ports match every state | IN PROGRESS | coordinator: GPUI lane + browser lead | Other repos. Unverified. |
| Screenshot-diff harness with CI gating and coverage | NO OWNER | - | Plan only. |
| Reduce Transparency fallback for the remaining raw glass panels | NO OWNER | - | Onboarding variants still call `Glass.makePanel`. |
| Non-macOS font choice | NO OWNER | - | Lawrence has not decided. |

## Platform core: components, catalog, identity, sync, mailbox

Source: spec/00-overview.md s4-s13, spec/operation-catalog.md, spec/identity-and-permissions.md, spec/sync-and-transport.md, spec/agent-mailbox.md, decisions U1-U8, D2, D5, D6, D7, D11, D16, D20, D26, S8, T2, T4, P10, D32.

### Components and data model (overview s4, s7)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| One `cmux` binary wraps cmux-tui and acpmux (s4, U7, S8) | DONE | 83f6b66184f | argv[0] dispatch in cmux-tui/src/main.rs. |
| Git service: git.diff, git.status on the session host (S8) | DONE | c055bc1cd1e, 249d833a4fe | Checkpoints too. |
| Git file search, git.commit, git.push, last-turn op (S8) | NO OWNER | - | No op in any catalog. The agent pane @ mentions call a missing handler. |
| Shared DO base (s7.1) | DONE | 0ce9557ca76, 6f92bdf6c2b | owner-do.ts and backend/packages/ownership. |
| TeamDO: membership, host directory, policy, SSO, enrollment | DONE | 0ce9557ca76 | Document directory part missing. |
| UserDO: installs, devices, grants, revocation, inbox | DONE | 0ce9557ca76 (backend/apps/api/src/user-do.ts) | Revoke closes sockets at once. |
| DomainDO | DONE | 49fe00b869a | - |
| HostDO: relay endpoint, cached snapshot and tail, attach admission (s7.1, s7.3) | IN PROGRESS | L12 a00f9f88e497a3922 | Codec landed (fc9cf5a090e). DO class (tag v9) remains. |
| DocDO running the store reducer as WASM (s7.1, D2) | NO OWNER | - | No class. No WASM build of the layout reducer. |
| Document homes in TeamDO, `doc.transfer_home`, `owner_for` (s7.2, D2) | NO OWNER | - | Directory holds hosts only. |
| ConversationDO and MuxDO | DONE | e252c7f8732 | - |
| SchedulerDO plus one Workflow per run (D13) | DONE | 4fe264a3e0e | - |
| ConnectionDO | DONE | e43ae60fd19 | - |
| TeamVmDO | NO OWNER | - | No class. See the team VM table. |
| Outbox to PlanetScale with idempotent upserts | DONE | 0ce9557ca76 (backend/apps/api/src/projection.ts) | - |
| Remote terminal viewing through link and HostDO (s7.3) | IN PROGRESS | L12 a00f9f88e497a3922 | Needs HostDO and the `cmux link` process. |
| U6 session host: smallest viewer wins, kick records the actor | DONE | 92bc1344795 | - |
| U6 clients: presence list and "disconnected by X" in the Mac app | NO OWNER | - | No presence or kicked UI. |
| Browser per Mac: `browser.navigated` and per-install `browser_runtime` (s7.4, U4) | IN PROGRESS | coordinator: browser lead | Not started. |
| Login environment capture: parallel, file watcher, env.refresh, no-shell wait (s7.6, D26) | NO OWNER | - | App capture and acpmux import exist (8e24690780e). The rest is missing. |

### Environments, security, observability, plan changes (overview s9-s12)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| One Worker per env, PR preview Workers, Hyperdrive per env (U8, D8) | DONE | 8dcb2a2ecfe | - |
| Dashboard in a new Vercel project (D1) | DONE | 0752872dda6 | - |
| PlanetScale migration runner, plain SQL in order | DONE | 0ce9557ca76 (backend/db/migrate.ts) | - |
| Audit: replay records projected to PlanetScale (s10) | DONE | c122d5b4488 | Hash chain, on_behalf_of column. |
| Observability: transaction as span attribute, log fields (s11) | IN PROGRESS | coordinator: backend lead | No spans yet. |
| `debug.desync` live invariant checks (s11) | DONE | 2384960322a | - |
| DO admin dump (s7.1, s11) | DONE | 0ce9557ca76 | - |
| Plan changes 1-4 recorded in plans (s12) | DONE | plans/cmux-next/OWNERSHIP-PRINCIPLES.md, ownership.md s8 | - |
| Plan change 5: principal model in the ownership identity step | IN PROGRESS | coordinator: ownership lead | No actor, on_behalf_of or grants in ownership.md. |
| Plan change 6: web projection rule in architecture.md | NO OWNER | - | Not written. |
| Plan change 7a: TLA+ relay (HostDO) and doc.transfer_home | IN PROGRESS | coordinator: ownership lead | Not started. |
| Plan change 7b: TLA+ model of the Tasks cross-team move | IN PROGRESS | coordinator: Tasks lead | No Tasks model. |

### Roadmap (overview s13)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Phase 1 backend skeleton | DONE | 0ce9557ca76 | HostDO under L12. |
| Phase 1 `cmux link` per machine, enrollment, relay | IN PROGRESS | L12 a00f9f88e497a3922 | host.enroll landed. The link process remains. |
| Phase 1 computer use in cmux-next | NO OWNER | - | See the computer use table. Pane model only (bc844f88218). |
| Phase 1 browser: WebKit driver, Rust host, CDP driver | IN PROGRESS | coordinator: browser lead | Host crate landed (a5ed5fdea95). |
| Phase 2 Home: ConversationDO, inbox, push, chief principal, catalog tools | IN PROGRESS | coordinator: Home lead; L15 a5334d64417941feb | Stage A objects landed. Push, grants, tools remain. |
| Phase 2 agent pane parity | IN PROGRESS | coordinator: ACP/agent pane lead | - |
| Phase 3 machine directory, ensureAwake leases, run tokens | NO OWNER | - | See the cloud table. |
| Phase 3 integrations | IN PROGRESS | L3 a98142a865bc6d642; coordinator: backend lead | ConnectionDO landed. Google providers have no owner. |
| Phase 3 remote view | NO OWNER | - | See the remote desktop table. |
| Phase 3b team VM | NO OWNER | - | See the team VM table. |
| Phase 4 Tasks MVP | IN PROGRESS | coordinator: Tasks lead | Team VM hosting remains. |
| Phase 5 own WireGuard overlay control plane | IN PROGRESS | L12 a00f9f88e497a3922 | Peer map push remains. |

### Operation catalog (D7)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Entry metadata on cloud ops: owner, risk, remote_relay, mcp, queue_offline | DONE | 0ce9557ca76 (backend/catalog/cloud-operations.json) | 75 ops. |
| Same metadata on local ops | IN PROGRESS | coordinator: #16174 Rust CLI owner | resource-operations-v2.json lacks owner, risk, remote_relay. |
| Cloud export plus CI diff check | DONE | 0ce9557ca76 | `catalog:check`. |
| One merged, checked-in catalog (D7) | IN PROGRESS | coordinator: #16174 Rust CLI owner | Five separate catalog files today. |
| App actions marked `cli` exported to clients | DONE | bce44facce6 | - |
| Rust generator: Rust client and CLI grammar | IN PROGRESS | coordinator: #16174 Rust CLI owner | Python codegen emits the Rust SDK. CLI reads the catalog at runtime. |
| Swift Codable types and async client generator | IN PROGRESS | coordinator: #16174 Rust CLI owner | Not started. |
| TypeScript client and chief code-mode API | IN PROGRESS | coordinator: #16174 Rust CLI owner | Interim types (63e8e3d3c86), executor (7565416f624). |
| MCP tools from the catalog, stdio, off by default (U7) | DONE | bce44facce6, 70704a99055 | Cloud ops not exposed. |
| OpenAPI 3.1 for cloud ops | DONE | 0ce9557ca76 | Served by the API. Not from the Rust generator. |
| MCP exposure groups default versus opt-in | IN PROGRESS | coordinator: #16174 Rust CLI owner | No group gating. |
| Grants, revocation and policy ops never exposed to agents | DONE | 0ce9557ca76 | `mcp.expose: never`. |
| Routing by owner, including cloud ops | IN PROGRESS | coordinator: #16174 Rust CLI owner | No `owner_for`. |
| App platform fields `scope_family` and `invalidated_by` | IN PROGRESS | coordinator: app platform lead | In no catalog. |
| HTTP MCP with scoped revocable tokens (phase 2) | NO OWNER | - | stdio only. |

### Identity and permissions (D5, D6, D16, D20)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Principal ids user, team, dev, inst, host | DONE | 0ce9557ca76 | agent_ and run_ not minted. |
| Local mode: Unix socket, same uid (D5) | DONE | CmuxNextControl/ControlAuthorizer.swift | - |
| Tailnet mode: peer identity against a local allow list (D5) | NO OWNER | - | Not built. |
| Install keypair, signed challenge, JWT with grant id, revocation (D5) | DONE | 0ce9557ca76 | JWT lacks the class and actor claims. |
| iPhone install principal with Secure Enclave key | DONE | ef523900760 | - |
| Install keys for Mac app, CLI, Linux daemons, VMs | IN PROGRESS | L10 a07ed15c10e36f8c8 | Server pairing only (23dd7e308b9). Mac app and CLI installs have no owner. |
| Device flow (RFC 8628) | IN PROGRESS | coordinator: backend lead | Not started. |
| No unauthenticated localhost HTTP: per-launch secret plus Origin/Host checks (D5) | NO OWNER | - | acpmux WebSocket token is optional. No Origin check. |
| Local launch credential: HMAC per terminal and ACP session | NO OWNER | - | Not built. |
| Grants owned server-side, checked on every op | IN PROGRESS | coordinator: backend lead | Op classes exist. Selectors and approval policy remain. |
| Agent classes chief, agent, run; delegation; class-aware relay (D20) | IN PROGRESS | coordinator: backend lead | Not in code. |
| Approvals delivered as notifications and Home parts | IN PROGRESS | L9 af42b2275d7d69f73 | feed.post and feed.answer landed (b0df7315edd). |
| Cloud replay record with actor and origin (D6) | DONE | 0ce9557ca76 | - |
| Actor stamp on local agent requests (D16) | NO OWNER | - | Agent calls still look like plain CLI. Needs launch credentials. |
| Control socket default `automation` (D16) | DONE | 18e7b27d555 | - |

### Sync and transport wire (U1, U2, U5, T4)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| cmux.wire/1 core frames on cloud owners | DONE | 0ce9557ca76 | - |
| presence.set, kick, channel.*, owner.status, catalog.changed frames (T4) | IN PROGRESS | L12 a00f9f88e497a3922 | Plan only (35ee6e64163). |
| Client state machine: refuse offline, resend pending, decided keys (U5) | DONE | backend/packages/ownership/src/client.ts | App offline refusal unverified. |
| Ledger retention 7 days, intent TTL 24 h | DONE | backend/packages/ownership/src/engine.ts | - |
| Binary channels with credit flow control and overflow policy | IN PROGRESS | L12 a00f9f88e497a3922 | Codec only. |
| UserDO gateway per install, channel tickets to HostDO | IN PROGRESS | coordinator: backend lead | Per-owner endpoints only. |
| Account directory with local fallback (U2) | IN PROGRESS | coordinator: backend lead | Client use unverified. |
| Phase 1 overlay from TeamDO policy (D3) | IN PROGRESS | L12 a00f9f88e497a3922 | See the network policy table. |
| Path type and RTT exposed to clients | IN PROGRESS | L12 a00f9f88e497a3922 | Classifier exists. Publishing remains. |
| request-settled and seq in the daemon (cmux.protocol/2) | IN PROGRESS | coordinator: ownership lead | App intent log landed. Daemon echo remains. |
| DO base property tests | DONE | 0ce9557ca76 | - |
| cmux.wire/1 conformance suite: Rust daemon, DO base, mock | NO OWNER | - | Relay vectors only. |

### Other decisions and the agent mailbox

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| U3: an emptied workspace closes in the TUI too | IN PROGRESS | coordinator: ownership lead | workspace-lifecycle-v1 not landed. |
| D11: machine records stay in the old backend | DONE | 50eb18daa53 | Port comes later. |
| T2: each app uses its own cmux-tui session by default | DONE | CmuxNextDaemon/Launch/DaemonLauncher.swift | - |
| T2: new window or workspace on a different session | IN PROGRESS | coordinator: federation daemon branch | Not built. |
| P10: daemon capability gate | NO OWNER | - | See the release table. |
| Mailbox on cmux-lawrence with ACK log and watcher | DONE | hq 9d626a0041 | Operational, not repo code. |
| Mailbox membership through the ACL | DONE | hq 9d626a0041 | - |
| D32: public SSH path through our own gate on Fly.io | NO OWNER | - | See the team VM table. |

## Backend, Home, iOS, ghostty-next

Source: spec/backend.md, spec/home-and-agents.md, spec/plan-ios-rewrite.md, spec/plan-ghostty-next.md, decisions D1, D4, D8, D9, D10, D23, D25, N1, IOS1-IOS5, B10, H1-H14, L14-1, L14-2, LK-R1.

### Backend

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| API Worker with Effect HttpApi (B10) | DONE | 0ce9557ca76 (backend/apps/api) | Deploy state unverified. |
| Dashboard on TanStack Start, own Vercel project (D1, B10) | DONE | 0752872dda6 (backend/apps/dashboard) | Vercel deploy unverified. |
| Desktop web app on Vite+ with TanStack Router, bundled in the app (B10) | NO OWNER | - | No backend/apps/desktop. webviews/ may be it (unverified). |
| Every DO class in one Worker | IN PROGRESS | coordinator: backend lead; L12 a00f9f88e497a3922 | 11 classes bound. HostDO, DocDO, TeamVmDO missing. |
| Workflows, Queues, R2, Cron bindings | IN PROGRESS | coordinator: backend lead | Only the automation Workflow is bound. |
| Effect 4 with exact pins (D25) | DONE | backend/packages/protocol/src/api.ts | Pinned to 4.0.0-rc.117. Move to stable. |
| Postgres through pg over Hyperdrive | DONE | backend/apps/api/src/projection.ts | One Hyperdrive id per env. |
| Shared DO base: ledger, seq, outbox, migrations, admin dump | DONE | backend/apps/api/src/owner-do.ts, do-outbox.ts | On the ownership engine. |
| Wire conventions: idempotency, request-settled, revisions | DONE | backend/packages/ownership/src/engine.ts | - |
| Client gateway on UserDO plus HostDO channels | IN PROGRESS | coordinator: backend lead | /v1/wire serves user, team and feed only. |
| PlanetScale cmux-next with Hyperdrive per env (D8) | DONE | backend/apps/api/wrangler.jsonc, backend/db/migrate.ts | Branch state unverified. |
| SQL migration runner | DONE | backend/db/migrate.ts, .github/workflows/backend-migrations.yml | 0001-0006. Prod state unverified. |
| Keep Stack as auth provider (D4) | DONE | backend/apps/api/src/stack-server.ts | - |
| Mirror users and teams from Stack webhooks | IN PROGRESS | coordinator: backend lead | Only personal teams. No team webhook. |
| Read entitlements through the old backend API | NO OWNER | - | L5 wrote a plan only. |
| Environments plus a Worker per PR preview | DONE | backend/scripts/deploy-worker.sh | Live deploys unverified. |
| Generate TS, Swift, Rust and MCP clients from the catalog (D7) | IN PROGRESS | coordinator: backend lead | Only the TS client exists. |
| Absorb the old Home staging Worker | IN PROGRESS | coordinator: backend lead | ConversationDO and MuxDO on the shared base (e252c7f8732). No code-mode loader. |
| Fold the presence and old relay Workers into TeamDO/UserDO (D8c) | NO OWNER | - | D8c timing open. |
| Observability: Sentry, OTel spans, log fields | IN PROGRESS | coordinator: backend lead | Nothing landed. |
| Backend lands and deploys before the Home UI depends on it (B10) | IN PROGRESS | coordinator: backend lead | Home ops not routed. Deploys unverified. |

### Home and agents

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Cloud owners ConversationDO, UserDO inbox, MuxDO, AddressDO (H1) | DONE | e252c7f8732 | Tests in backend/apps/api/test/home-objects.test.ts. |
| Postgres projections with hash-partitioned search (H1) | DONE | fc7e9f19bfe (0006_home.sql) | Prod state unverified. |
| OwnerEngine row mode (H1) | DONE | 0ab05830e92 | - |
| TS home-core reducers and conformance corpus (H2) | DONE | ef041de7374, d8b671ca249, 3a3a6254caa | - |
| Public routing of Home ops and conversation streams | IN PROGRESS | coordinator: backend lead | ownerRoute has no Conversation, Mux or Address owner. Clients cannot reach Home owners. |
| MuxDO caller-kind lookup | IN PROGRESS | L15 a5334d64417941feb | Until it lands, apps cannot approve text confirmations. |
| Self-hosted Home owner on cmux server and team VM (B10, H2, H4) | NO OWNER | - | Only the Worker imports home-core. |
| Local conversation owner in cmux (D10, H8) | DONE | 0a45fb284f0 (cmux-tui/crates/cmux-conversation) | Turn budget, actor stamp, search. |
| Home is a workspace with kind home, daemon side | DONE | f735b1d338e, 0011bcfb94c, 0e141653201 | Daemon only. |
| Mac Home wired into the app (IOS2 "Mac Home must work for real") | IN PROGRESS | coordinator: Home lead | BROKEN: overlay removed in 73dc69fc6f0; HomeHostView is never created; sidebar Home sends home.show, which no longer exists. |
| Mac Home on CmuxHomeCore and cloud conversations (IOS2, IOS3) | IN PROGRESS | coordinator: Home lead | CmuxNextHome imports neither CmuxHomeCore nor CmuxHomeRender. |
| Shared render core CmuxHomeRender (IOS3 option B) | DONE | 8118b9a1b34 | - |
| Render core fixes: off-main bitmaps, no sleep, theme bubbles | IN PROGRESS | L16 a968777c61ccf84b7 | Branch 1295d41c129 unlanded. |
| Mac transcript ports the appkit-native MessagesLab view onto the shared core (H14) | IN PROGRESS | L16 a968777c61ccf84b7; coordinator: Home lead | New. Nothing landed. Owner to confirm. |
| Native renderer plus a valid 1M-message low-load bench (D9) | IN PROGRESS | L16 a968777c61ccf84b7 | No valid low-load run recorded. |
| Chief brain as a Rust port on the Mac (H8) | NO OWNER | - | The Mac runs the TS brain through an env var host. |
| Always-on cloud brain on MuxDO with code mode | NO OWNER | - | MuxDO is a wake queue only. |
| Chief tools as a generated code-mode API over the catalog | NO OWNER | - | Not built. |
| Multi-chief rules: wake on mention, turn budget | DONE | 0b298fd832a, cmux-conversation budget.rs | - |
| conversation.promote, local to cloud (D10) | NO OWNER | - | Not in either owner. |
| Data model: deterministic DM ids, reactions, edits, retractions | DONE | backend/packages/home-core/src/conversation/ids.ts | - |
| Attachments: upload intent, then R2 by hash | NO OWNER | - | No R2 binding or upload op. |
| Home push from UserDO per message; approvals always notify | NO OWNER | - | APNs exists only in feed-do.ts. |
| Web dashboard Home | NO OWNER | - | No dashboard Home route. |
| Invite copy A/B, STOP line, single-use 1:1 links, group rules (H4) | DONE | ef041de7374 | Real sends wait for AddressDO stage C. |
| Relationships: Contacts, Grants, Team; compose dropdown; message requests (H3, H5) | NO OWNER | - | Proposal only (home-messaging.md s16). |
| Invite landing /i and OG card, minimal design (H4, H7, H9) | IN PROGRESS | coordinator: backend lead; L15 a5334d64417941feb | Routes exist. Worker preview endpoint missing. Main PR 16836 waits for prod. |
| Provider sends: email and SMS (IOS2) | IN PROGRESS | coordinator: backend lead | Providers in home-core. No Worker send path. |
| Contact card before the first text (H6, H7) | IN PROGRESS | coordinator: backend lead | Send plan in d8b671ca249. Staging script only. |
| Text Chief inbound webhook (H6, H9) | IN PROGRESS | L15 a5334d64417941feb | Pure parser only. No Worker route. |
| Phone link through a single-use sign-in link (H9) | IN PROGRESS | L15 a5334d64417941feb | Pure logic only. No website route or app UI. |
| Confirmation levels wired for actions requested by text (H10, H11) | IN PROGRESS | L15 a5334d64417941feb | Pure logic landed. UserDO does not host the ops. |
| Lowering the level: Face ID device proof, notify every device (H13) | IN PROGRESS | L15 a5334d64417941feb | Pure logic and workerd fix landed. Not wired. No client key. |
| Team or MDM lock sets only a minimum level (LK-R1) | DONE | 00e2ce2082a | - |
| Team roles: guests free, billing audit scope, only owners remove admins (H12) | NO OWNER | - | No roles in the team domain. |
| Home ownership and old staging resource handover (D23) | IN PROGRESS | coordinator: Home lead | Teardown unverified. Needs the user. |
| Chief memory in the team VM | NO OWNER | - | The brain uses a local file store. |

### iOS rewrite

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Same bundle ids, new target tree (IOS1; step 2) | DONE | e46f74f9651 (ios/CmuxiOS) | - |
| Kept sign-in adapted into CmuxiOSAuth | DONE | ios/CmuxiOS/Sources/CmuxiOSAuth | Debt: 2 files over the god-file limit, one sleep-based timeout. |
| CmuxHomeCore: mirror, intent log, mock (step 1) | DONE | e46f74f9651 (Packages/Shared/CmuxHomeCore) | - |
| Home UI: list, Chief pinned, transcript, composer, search (IOS2) | DONE | ios/CmuxiOS/Sources/CmuxHomeUI | Mock source only. |
| Invite button top right; compose by email or phone (IOS2) | DONE | CmuxHomeUI/Public/HomeViewController.swift | UI only. |
| Dogfood readiness app-receipt | DONE | CmuxiOSAuth/DogfoodReadinessReceipt.swift | - |
| Install on the phone, sign in, screenshots | IN PROGRESS | L14 a137f79e0edfeef9c | The phone never connected. |
| Delete the old iOS code (IOS1; step 3) | IN PROGRESS | L14 a137f79e0edfeef9c | Branch 01bf7e0fc8c waits for the phone gate. |
| Density and compose prototypes behind a DEV switch (step 4) | DONE | CmuxiOSApp/DevOptions.swift | Lawrence's pick pending. |
| CloudHomeSource over cmux.wire/1 (step 5) | IN PROGRESS | L14 a137f79e0edfeef9c | Blocked: Home ops not routed. |
| Mac local conversations on iOS while the Mac is reachable (D10) | IN PROGRESS | L14 a137f79e0edfeef9c | Needs transport. |
| Transcript on CmuxHomeRender (IOS3) | IN PROGRESS | L14 a137f79e0edfeef9c | Interim view today. |
| GhosttyNextKit terminal (step 6) | IN PROGRESS | L14 a137f79e0edfeef9c | Branch 35160105ac1 (17035) unlanded. |
| Push: register, Reply and Mark Read actions (step 7) | IN PROGRESS | L14 a137f79e0edfeef9c | 17039 unlanded. |
| On-device cache and offline read-only mode | IN PROGRESS | L14 a137f79e0edfeef9c | Banner exists. Cache does not. |
| Accessibility audit and perf budgets on device | IN PROGRESS | L14 a137f79e0edfeef9c | No device runs. |
| Narrow the phone install grant (L14-1) | IN PROGRESS | L14 a137f79e0edfeef9c | Not landed. |
| Sign-out revokes the install; server removes push targets (L14-2) | IN PROGRESS | L14 a137f79e0edfeef9c; coordinator: backend lead | Not landed. |
| No old relay in the new app (T1) | DONE | ios/CmuxiOS | grep is clean. |
| "Chief" in product copy (IOS4) | DONE | CmuxHomeUI/Compose/NewChiefSheet.swift | Mac Home has no Chief strings. |
| Allow list for staging invite recipients (IOS5) | DONE | backend/packages/home-core/src/invites/policy.ts | - |

### Ghostty-next (repo manaflow-ai/ghostty-next)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Fork on upstream main plus iOS build patches | DONE | ghostty-next 6ca5aa7b3, e699e418b, 2de3c482b | - |
| Manual-mirror IO, reply suppression, input, threading contract (s3 items 1-3, 7) | DONE | ghostty-next 117c73bbb, 3c6291035, f205473ee, 81d2422e7 | - |
| Committed text input | DONE | ghostty-next c64398194 | - |
| xcframework pipeline: deterministic zip, sums, attestation (s10) | DONE | ghostty-next next/build-xcframework.sh | Zig cache path breaks reproducibility. Push triggers do not run. |
| Module named GhosttyNextKit | DONE | ghostty-next 8562af028 | - |
| iOS layer sizing fix so the renderer draws (v3) | DONE | ghostty-next 7135a4691 | - |
| Host-locked grid `ghostty_surface_set_grid` (s3 item 4) | NO OWNER | - | L13 closed. |
| Snapshot restore `ghostty_surface_restore_snapshot` (s3 item 6) | NO OWNER | - | - |
| Surface calls never block; mailbox coalesces (s3 item 8) | NO OWNER | - | Watchdog-kill risk on iOS. |
| iOS ports: 72 DPI fonts, layer teardown, bounded renderer wait | NO OWNER | - | 96 DPI off macOS today. |
| Host snapshot: terminal-snapshot-v1, terminal.history, read_range, digest (s11) | NO OWNER | - | Request file only (cli-requests/terminal-snapshot-history.md). |
| Sizing rules: visible only, keyboard, previews, grow hysteresis, fixtures (s6) | NO OWNER | - | No fixtures for these cases. |
| Terminal frame fields kind/generation/offset, credit, presence (s11, T4) | NO OWNER | - | Unverified whether any owner took them. |
| iOS on-demand Metal view, key input, pinned binary target | IN PROGRESS | L14 a137f79e0edfeef9c | 35160105ac1 pins v3. Unlanded. |
| update-ghostty-upstream skill warning | DONE | hq skills/build-release/update-ghostty-upstream/SKILL.md | - |
| Fidelity corpus and 100 MB flood test (s12) | NO OWNER | - | - |
| Device dogfood on Lawrence's phone | IN PROGRESS | L14 a137f79e0edfeef9c | The phone never connected. |

## App platform, first-party apps, Finder, feed

Source: spec/app-platform.md, spec/plan-app-platform.md, spec/plan-first-party-apps.md, spec/plan-finder.md, spec/plan-feed.md, decisions D40-D60, APP-V2, APP-R1, APPS, I13, N10-N14, BR-R1, BR-R2, FD-R1, L3-1, L3-2, C1, S21.

### Runtime, host, sandbox

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Manifest v1 schema, validator, fixtures, samples (D41) | DONE | df186bf65c6 | Manifest v2 replaces it. |
| Engine-neutral runtime, ABI, generated `cmux` global, scopes.json | DONE | df186bf65c6, 48c36fe186f | Generator reads three catalogs (no merged catalog yet). |
| Scopes derived from catalog risk (D43) | DONE | cmux-tui/crates/cmux-app-host/generated/scopes.json | No `scope_family` field yet. |
| Runtime contract v1.1 (APP-V2) | DONE | 03461393cb3 | Gesture tokens, onCleanup, settings.set. |
| Scene node budget releases whole subtrees | DONE | c001b515f12 | - |
| Manifest v2, interface contracts, one Rust validator (D54, D57) | IN PROGRESS | coordinator: app platform lead | Schema and crate landed (84706562786). TS and Swift validators not deleted. |
| QuickJS-ng Rust app host, one process per app (D40) | IN PROGRESS | coordinator: app platform lead | Branch apps-rust 72246ecb390 (PR 16872). The app still runs the JavaScriptCore prototype. |
| Daemon app supervisor: install mirror, routing, storage, egress, limits | IN PROGRESS | coordinator: app platform lead | Branch only (16872, 17008). In the cmux-tui landing queue. |
| OS sandbox for the app host (D52) | IN PROGRESS | coordinator: app platform lead | Real code, branch only. |
| Host enforces gesture and origin rules; actor stamp (I13) | IN PROGRESS | coordinator: app platform lead | PR 17008, not landed. |
| Owner-side app grant checks | IN PROGRESS | coordinator: app platform lead | Owners still trust the supervisor. |
| JavaScriptCore prototype engine and AppHost | DONE | 8a0f5f01d9f | DEV stand-in. Deleted after v2 step 3. |
| Tiers, per-scope grants, "Run sandboxed" per call (D51, D52, D56) | DONE | a08032c867e | Prototype engine only. |
| Permissions UI: consent sheet, Settings Apps, first-use prompt (D52) | IN PROGRESS | coordinator: app platform lead | CmuxNextAppPermissions landed (7f5784b37ed) but is not linked. |
| APP-R1 provider channel for Mac-owned and cloud app ops | IN PROGRESS | coordinator: app platform lead | Branch apps-routing f1e01305a98. |
| App local storage and net.fetch without credentials | IN PROGRESS | coordinator: app platform lead | Mac prototype landed (145cdd0c6bb). Supervisor part on a branch. |
| Synced app storage `storage:synced` in UserDO | NO OWNER | - | No plan step or code. |
| `cmux.integrations.*` through the gateway | NO OWNER | - | The host answers operation.unsupported (unverified). |
| Host capability ops power.assertion.* (Caffeinate) | IN PROGRESS | coordinator: app platform lead | Plan only. |
| Catalog metadata (invalidated_by, since, scope_family) and typed watch streams | NO OWNER | - | Requested from the generator owners. |

### Store, distribution, installs

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| App Store window, layout prototypes | DONE | 0ad814b0ec3 | - |
| Card look for the store and app sections (D59) | DONE | cdd35a1bc8b | - |
| App Store as a tab or pane | IN PROGRESS | coordinator: app platform lead | Page view on branch f5548642b3f. |
| App Store under Home; Remove from Sidebar or Section; Hide (S21) | DONE | 66f56024be6 | - |
| Store backend: AppDO, installs and grants in UserDO/TeamDO, migration, search, yank (D46) | IN PROGRESS | coordinator: app platform lead (backend lead review) | Branch only. No AppDO at the audit sha. |
| Web store pages /apps | IN PROGRESS | coordinator: app platform lead | Branch 1abd6e78acc. |
| Publish from a GitHub release with attestation (D44) | IN PROGRESS | coordinator: app platform lead | Submit op on a branch. No attestation check. |
| Client install: sha256, content-addressed cache, no build steps | IN PROGRESS | coordinator: app platform lead | Waits for the supervisor. |
| Verified-tier review pipeline: scan, human review, set_tier (D45, D51) | NO OWNER | - | No process or staff tooling. |
| Auto-update policy `sameScopes` (D49) | NO OWNER | - | No code. |
| Agent installs blocked until the actor stamp (I13, D48, D60) | IN PROGRESS | coordinator: app platform lead | Backend rule and stamp on branches. |
| Install, enable, hide per user, synced (D55, D60) | IN PROGRESS | coordinator: app platform lead | Reducer, actions, filter landed (00951dc6d24, c7d5f222d19, cc5f77639e4). UserDO record on a branch. |
| First-party apps installed by default from a deployment list (D56, D60) | IN PROGRESS | coordinator: app platform lead | Only coderouter bundled. List on a backend branch. |
| `cmux apps` CLI and MCP verbs | IN PROGRESS | coordinator: app platform lead | Nothing landed. |
| Team app policy and kill switches | NO OWNER | - | No plan step. |
| Store v2 listings: interfaces, handles, server, sandbox profile | IN PROGRESS | coordinator: app platform lead | Nothing landed. |
| Import old JS sidebars | NO OWNER | - | No plan step. |
| Chief-written apps stored in code.storage (C1) | NO OWNER | - | code.storage is planned for automations only. |

### UI, palette, sidebar, composition

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Native scene renderer on macOS (D42) | DONE | 2b0f5beb2ab | - |
| App sidebar sections (D47) | IN PROGRESS | coordinator: sidebar sections lead + app platform lead | `content: app` in the layout. No provider wiring. |
| Status items and menu bar placement | IN PROGRESS | coordinator: app platform lead | Contract landed. Not rendered. |
| App pane kinds mounted as tabs | IN PROGRESS | coordinator: app platform lead | Not mounted. |
| Palette scopes in the manifest and runtime | DONE | a835b277bd6 | - |
| Palette scope reducer and chips | IN PROGRESS | L11 afb07bff3d5bef67b | PR 16849 open. |
| App commands in the palette with a gesture | IN PROGRESS | coordinator: app platform lead | Branch 6655a4c5e2e. |
| Semantic scene components: List, Table, ScrollView, Meter, TextEditor, Popover (D57) | IN PROGRESS | coordinator: app platform lead | Nothing landed. No v2 step covers it. |
| Web panes: sandboxed app web view | IN PROGRESS | coordinator: app platform lead | v2 step 4. No host. |
| Native panes for first-party apps | IN PROGRESS | coordinator: app platform lead | Schema only. |
| Documents/buffers primitive and open-with (D58) | IN PROGRESS | coordinator: app platform lead | v2 step 4. |
| Typed interfaces implements/consumes | DONE | 84706562786 | Codegen unverified. |
| Embeds | IN PROGRESS | coordinator: app platform lead | v2 step 5. |
| Diff resources and git ops | IN PROGRESS | coordinator: app platform lead | Daemon git ops exist. diff resources missing. |
| Handles root_, conn_, cred_; secret handles | IN PROGRESS | coordinator: app platform lead | v2 step 6. |
| App servers: server block, instances, supervision (N13) | IN PROGRESS | coordinator: app platform lead | Schema only. |
| `server.scope` device and `fallback_owner` | IN PROGRESS | coordinator: app platform lead | `fallback_owner` missing. |
| MCP tools per app command; skills, MCP servers, agents contributions | IN PROGRESS | coordinator: app platform lead | "Later". |
| Scene renderers for web dashboard, iOS, TUI | NO OWNER | - | macOS only. |

### First-party apps

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Proposal: tiers, sandbox, API gaps (D50-D52) | DONE | a44a6419722 | - |
| search (D50) | DONE | 94aa717e3f6 | Prototype on fixtures. |
| inbox as a view on the feed (D50, N10) | DONE | 84cc33b4e8f, b9de9d172cd | Mock owner. |
| notes (D50, D53) | DONE | 5130bd91670, b9de9d172cd | Prototype. No notes server binary. |
| coderouter app (D50) | DONE | b59c21e6bdb | Bundled. Ops answer unsupported in the app. |
| usage menu bar app (D50, D58) | DONE | 6e22a74b217, d5539670f91 | Fixtures only. |
| Diffs, CodeMirror, Monaco (D58) | DONE | dabcf6b4ff2 | Need a web pane host. |
| Finder with SSH prototype (D53) | DONE | 30e885d6c69 | Fixture ops. |
| Integrations app (D53) | IN PROGRESS | L3 a98142a865bc6d642 | PR 17055 WIP. |
| Caffeinate (APPS) | DONE | bde4ed8acde | Host op missing. |
| Remote desktop app listing (APPS) | NO OWNER | - | L17 stopped. |
| CodeRouter data ops through the redacting route | IN PROGRESS | coordinator: app platform lead | Privacy fix PR 17063 open (L3). |
| First-party apps running in a tagged build | IN PROGRESS | L3 a98142a865bc6d642 + coordinator: app platform lead | Only coderouter bundled. Unverified in the app. |
| notes and inbox switch to ctx.gesture | IN PROGRESS | L3 a98142a865bc6d642 | Waits for 17008. |
| L3-1 wildcard rules never unblock destructive tools | IN PROGRESS | L3 a98142a865bc6d642 | In 17055. |
| L3-2 auth.status keeps the user's own email | IN PROGRESS | L3 a98142a865bc6d642 | In 17063. |
| Usage data owner: usage ops, `cmux-usage serve` | NO OWNER | - | - |
| Notes server: binary and note.* ops (N13) | NO OWNER | - | Catalog declared only. |

### Finder

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Prototype and file platform proposal | DONE | 30e885d6c69 | - |
| Step 1: local fs provider, root_ handles, folder panel | IN PROGRESS | coordinator: app platform lead | Interface contract only. |
| Step 2: file ops, jobs, undo, confirmation sheet | IN PROGRESS | coordinator: app platform lead | Nothing landed. |
| Step 3: scene ScrollView, List, Table, drag and drop | IN PROGRESS | coordinator: app platform lead | Nothing landed. |
| Step 4: conn_ handles, host.* ops, connect sheet, host key UI | IN PROGRESS | coordinator: app platform lead + L12 a00f9f88e497a3922 | conn_ naming open. |
| Step 5a: owner-to-owner bulk copy | IN PROGRESS | L12 a00f9f88e497a3922 | L12-1 accepted. Not built. |
| Step 5b: plain SSH targets through SFTP in cmux link | NO OWNER | - | Transport question unanswered. |
| Step 5c: terminal.drop, agent.attach, ent_ handles | NO OWNER | - | - |
| Step 6: viewer embeds, document.open, open-with, thumbnails | IN PROGRESS | coordinator: app platform lead | Depends on v2 steps 4-5. |
| `cmux fs` and `cmux host` CLI and MCP verbs | IN PROGRESS | L3 a98142a865bc6d642 | Request files only. |

### Feed

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| FeedDO owner, feed.* ops, reducer, kinds, routing (N10, N11, N14) | DONE | b0df7315edd | - |
| Local fallback owner and handoff | IN PROGRESS | L9 af42b2275d7d69f73 | TLA+ and feed.adopt landed. `cmux-feed serve` not built. |
| CmuxNextFeed module: list, inbox, menu bar prototypes | DONE | 53b07a31f3c | Not linked into the app. |
| App wiring: Cmd-I list over FeedDO | IN PROGRESS | L9 af42b2275d7d69f73 | PR 16855 open. |
| Feed CLI and MCP verbs; no answer verb | IN PROGRESS | L9 af42b2275d7d69f73 | Request file only. |
| Harness adapters for the agent CLIs and acpmux (N11) | IN PROGRESS | L9 af42b2275d7d69f73 | One hook on a branch (932451aaae2). |
| Notifications migration steps 1-3 | IN PROGRESS | L9 af42b2275d7d69f73 | Not started. |
| Delivery heuristic and Settings Feed keys | IN PROGRESS | L9 af42b2275d7d69f73 | Not built. |
| Sign-in and passkey through a duplicated tab (N12) | IN PROGRESS | L9 af42b2275d7d69f73 + L19 af3754db6f45c221a | WebKit prototype only. |
| Hide HttpOnly sign-in cookies from agent reads (FD3) | IN PROGRESS | L9 af42b2275d7d69f73 | Not built. |
| BR-R1: no POST re-send on duplicate or wake | IN PROGRESS | L9 af42b2275d7d69f73 | Not built. |
| BR-R2: no form value copy | IN PROGRESS | L9 af42b2275d7d69f73 | Not built. |
| Push: owner deadline and APNs sender | IN PROGRESS | L9 af42b2275d7d69f73 | Sender on branch a7eef127c49. |
| FD-R1: at-most-once push | IN PROGRESS | L9 af42b2275d7d69f73 | On the push branch. |
| iPhone: push targets, banner answers, feed list | IN PROGRESS | L14 a137f79e0edfeef9c | Push target code landed after the audit sha (1ff2f872d7b). No iOS feed list. |
| Email as a feed source: ids only, peek, triage, reply (D53) | IN PROGRESS | L9 af42b2275d7d69f73 | Needs the gateway peek op. |
| Delegation with feed.delegate | IN PROGRESS | L9 af42b2275d7d69f73 | Blocked on the actor stamp. |
| Integration poster: ConnectionDO posts review and check items | NO OWNER | - | - |

## Browser, passkeys, computer use, agent pane, remote desktop

Source: spec/browser-use.md, spec/passkeys.md, spec/computer-use.md, spec/acp-ui.md, spec/plan-remote-desktop.md, decisions D12, D15, D18-D22, S5-S8, S20, B10 (passkeys), B11, BR-R1..R3, U4, APPS.

### Browser

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Rust browser host crate: driver protocol, provider frames, CDP driver | DONE | a5ed5fdea95 (cmux-browser-host/src/cdp/driver.rs) | Chromium test in tests/chromium.rs. |
| Headless Chromium over the debugging pipe, no port | DONE | cmux-browser-host/src/cdp/pipe.rs | Launch and driver only. |
| Host on Cloud VMs (`remote_browser`), one user-data-dir per profile, sandbox on | IN PROGRESS | coordinator: browser lead | Not in the VM image. Sandbox on Freestyle unverified. |
| QuickJS-ng REPL sessions with the native bridge v1 (D12; step b) | IN PROGRESS | coordinator: browser lead | Unlanded branch feat-cmux-next-browser-host-b 3553b986eb7. |
| Domain policy, secret handles, masking in the Rust host below the VM | IN PROGRESS | coordinator: browser lead | Moved into the JS reference host (2ee55afcfac). Rust part on branch -b. |
| Sealed tabs before a secret fill | IN PROGRESS | coordinator: browser lead | Branch -b only. |
| BR-R3: WebSockets blocked while a domain policy is active | IN PROGRESS | coordinator: browser lead | Test and fix on branch -b. |
| Rust snapshot core: stitching, diff, budget, refs, same goldens | IN PROGRESS | coordinator: browser lead | Not started. snapshot.js is still JS. |
| WebKit driver port onto CmuxNextBrowser | DONE | 7f6cdff28fe, ee6495afbf1 (CmuxNextBrowserAutomation/WebKitDriver.swift) | First slice. Two navigation-wait tests fail on macOS 26.3 runners. |
| App provider bridge: WebKit forwarding, CEF CDP relay over the socket (step c) | IN PROGRESS | coordinator: browser lead | Shim has the devtools call. Driver not linked in the app. |
| `browser.repl.*` catalog and MCP tools | IN PROGRESS | coordinator: browser lead | Catalog and MCP tool file landed. Host listener not landed. |
| Discrete `browser.*` runtime ops and generated CLI (step e) | IN PROGRESS | coordinator: browser lead | Not started. |
| Automation lease, "driven by" badge with Stop, pause on user input | IN PROGRESS | coordinator: browser lead | Only password-fill off for agent-driven tabs. No lease or badge. |
| Per-workspace agent profile default; opt-in signed-in profile (D12) | IN PROGRESS | coordinator: browser lead | Not started. |
| Raw `browser.cdp` behind an opt-in grant (D12) | IN PROGRESS | coordinator: browser lead | Not started. |
| Per-session action log in the shared activity schema | IN PROGRESS | coordinator: browser lead | Not started. |
| High-risk writes need app confirmation; refuse file://, internal pages, TLS click-through | IN PROGRESS | coordinator: browser lead | In the plan. Not verified in code. |
| D20 relay: chiefs may drive Mac-hosted tabs, ordinary agents may not | IN PROGRESS | coordinator: browser lead | Not started. Relay analysis missing. |
| PR 15570 re-targets cmux-next: runtime JS, docs, conformance suite (D12) | DONE | b8c82aa2a57 (cmux-browser-host/js/) | MCP server port is a separate row. |
| Conformance suite backends host-headless/cef/webkit; headless leg in hosted Linux CI | IN PROGRESS | coordinator: browser lead | Suite and oracle landed. Backends and CI leg missing. |
| VM egress policy for agent browsing: block metadata IPs and private ranges | NO OWNER | - | Not in code or in the host plan steps. |
| Public task benchmark subset with per-task logs | NO OWNER | - | Not in the host plan steps. |
| BR-R1 / BR-R2: duplicate and wake never re-send POST; no form value copy | IN PROGRESS | L9 af42b2275d7d69f73 | Prototype 0438a9f60aa only. It found that WebKit re-sends a restored POST. |

### Passkeys

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Test RP and reference oracle (s5 step 1) | DONE | 308dcdbe82c (tests/passkeys/run.mjs) | Runs against stock Chromium only. |
| Known-bugs table K1-K18: a regression test per engine (s1; B10) | IN PROGRESS | coordinator: passkeys lead | Not run against any cmux engine. |
| CEF signed-nightly measurement and manual checks (step 2) | IN PROGRESS | coordinator: passkeys lead | Blocked: no signed cmux-next nightly yet (L21). |
| CEF visibility and pending-ceremony guard, K16 (step 3) | IN PROGRESS | coordinator: passkeys lead | Not started. |
| Agent lease `refuse` and `virtual` modes; CEF fork export (step 4) | IN PROGRESS | coordinator: passkeys lead | Not started. Needs a new CEF fork API (L19). |
| WebKit passkey configuration on every config path, K1/K7/K13 (step 5) | IN PROGRESS | coordinator: passkeys lead | Not started. |
| WebKit measurement, then the bridge decision (step 6) | IN PROGRESS | coordinator: passkeys lead | Not started. |
| Settings `browser.passkeys.*`, status op, page-info line (step 7) | IN PROGRESS | coordinator: passkeys lead | Not started. |
| Signing guards: notarized launch smoke, certificate-in-profile check (step 8) | IN PROGRESS | coordinator: passkeys lead | Entitlement asserted in the sign script. No leaf check or launch smoke. |
| Feature matrix in CEF and WebKit: platform, managers, hybrid, security keys, conditional UI, extensions (B10) | IN PROGRESS | coordinator: passkeys lead | No ceremony run in any cmux-next build. |
| Secure sign-in sheet passkey path (s3.5.2) | IN PROGRESS | coordinator: passkeys lead | Not started. Overlaps the feed sign-in handover (L9). |
| Passkey decisions D1-D6 (s6) | IN PROGRESS | coordinator: passkeys lead | Waiting for Lawrence. |
| K14: the RC channel has no passkeys; land #12857 (s6 D6) | NO OWNER | - | The spec says a release lane owns it. No such lane. |
| Parity ports pass the known-bugs table (B10) | IN PROGRESS | coordinator: browser lead + cmux-browser lane | Unverified. |

### Computer use and Agent activity

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| CUA activity core: session reducer, redaction, retention planner (step a) | IN PROGRESS | coordinator: computer use lead | Draft cmux-cua PR 28 only. Lead not in Active streams (liveness unverified). |
| Event log always on, thumbnails, retention 30 d / 7 d (D19; step b) | IN PROGRESS | coordinator: computer use lead | Draft PR 28, not merged. |
| `cua.*` methods, user-only stop/pause/resume, CLI verbs, MCP reads (step c) | IN PROGRESS | coordinator: computer use lead | Activity methods in PR 28. CLI verbs and MCP reads missing. |
| D15 unrestricted by default; denylist only through policy op | IN PROGRESS | coordinator: computer use lead | Policy method in PR 28. |
| Agent activity pane: model, socket source, URL, palette action (D19; steps e, f) | IN PROGRESS | coordinator: computer use lead | Partial: 6353920069e, d7c609149b0, 04b1f9019c4. AppKit rewrite, indicator, Stop All remain. |
| TCC onboarding step for computer use | DONE | 27011acc234 (Onboarding/AppComputerUsePermissionSource.swift) | Menu bar item not done. |
| Launch credentials minted by the session host, `terminal.for_pid`, `credential.verify` (step d) | NO OWNER | - | Not started. |
| Helper app bundled in cmux-next, signed and notarized (steps g, h) | NO OWNER | - | cmux-next does not ship the helper yet. |
| Linux: `cmux-cua serve` under the session host, per-workspace display (step i) | NO OWNER | - | Not started. |
| `cua.*` relay with D20 rules and relay analysis | NO OWNER | - | Not started. |
| Unified timeline: browser host and acpmux write the CUA event schema | NO OWNER | - | No shared schema code. |

### Agent pane

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Web pane over acpmux in a web view (D22) | DONE | CmuxNextAgentPane/AgentPaneView.swift, webviews/src/agent-session/acpmux | About 60 pane PRs landed. |
| S20 base: virtualized transcript, session sidebar, slash menu, queue | DONE | webviews/src/agent-session/acpmux/SessionSidebar.tsx, slashCommands.ts | - |
| Changes pane: scope menu, tree, stacked diffs (S20) | DONE | fabc08bb57e, cbea75e0a34 | Scopes read through git.diff. |
| Turn grouping, edited-files card, timestamps (S20) | DONE | 684abfd7838, 164bb7260e0 | - |
| Approval menu and permission card (S20) | DONE | webviews/src/agent-session/acpmux/PermissionCard.tsx | Grouped permissions PR 16958 open. |
| Effort slider (S20) | DONE | 8a44d9210e3 | - |
| Cmd-K chat search as a catalog action (S20) | DONE | 2680d650442 | - |
| Milkdown composer (S5, S20) | DONE | webviews/src/agent-session/acpmux/MarkdownField.tsx | Version pinned. |
| Diff and tree libraries pinned to exact versions | DONE | webviews/package.json | - |
| New-chat layout, project chooser, folder trust (S20) | IN PROGRESS | coordinator: ACP/agent pane lead | UI landed. No Rust handler for `acp.trust.get/set`. |
| Streaming read-only Milkdown renderer for the transcript (S5) | IN PROGRESS | coordinator: ACP/agent pane lead | Transcript uses its own Markdown renderer. |
| S7: copy reference code into cmux and record the license in the copy commit | IN PROGRESS | coordinator: ACP/agent pane lead | Ports landed. No license record found. |
| acpmux pieces: view rows, hunk records, steering flag, resource blocks, session lock | IN PROGRESS | coordinator: ACP/agent pane lead | Steer, queue, fork exist. The rest is missing. |
| Hunk Keep/Undo | IN PROGRESS | coordinator: ACP/agent pane lead | UI landed. No acpmux decision records. |
| Attachments, steer, @ mentions | IN PROGRESS | coordinator: ACP/agent pane lead | Stack 16557/16583/16584 stale. |
| ACP inspector panel | IN PROGRESS | coordinator: ACP/agent pane lead | Stack 16603/16604/16614 stale. |
| ACP version normalization, subagent trees | IN PROGRESS | coordinator: ACP/agent pane lead | Unverified in acpmux. |
| S8: git.diff, git.status, checkpoints on the session host | DONE | c055bc1cd1e, 249d833a4fe (cmux-tui-core/src/git_ops.rs) | Capability git-checkpoints-v1. |
| S8: file search served by the Rust binary | IN PROGRESS | coordinator: ACP/agent pane lead | The pane calls `file.search`. No Rust handler. |
| Git actions `git.commit`, `git.push` | NO OWNER | - | No op or UI. |
| Markdown files in a Milkdown editor with round-trip corpus (S5) | NO OWNER | - | No editor app. The corpus must land first. |
| S6: where the agent session list lives (open) | NO OWNER | - | Undecided. |

### Remote desktop and remote view

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Step 0: prototype and measurements (s17.0) | DONE | 4f9205a390a, d445a445556 (experiments/remote-desktop/) | Throwaway. L17 stopped. |
| Relay batching, up to 16 KiB of datagrams per relay message | DONE | 376400809dc (cmux-transport/src/relay_frame.rs) | - |
| Overlay datagram service on port 4103, inner MTU, path events | IN PROGRESS | L12 a00f9f88e497a3922 | L12's next item. |
| Phase 1: `cmux-rd-proto` and `cmux-rd-core`, pure with property tests (APPS) | NO OWNER | - | No owner since L17 stopped. |
| Phase 1: Linux virtual X host with damage capture and encoder (D-RD1) | NO OWNER | - | - |
| Phase 1: macOS `remote_view` pane, path badge, RTT, settings | NO OWNER | - | Tab kind not in the workspace store. |
| Phase 1: owner-only access, policy tests, agents refused control, CI bench | NO OWNER | - | Required with the implementation. |
| App manifest `cmux/remote-desktop`, `desktop` host role, TeamDO capabilities (s10) | NO OWNER | - | Lane answers unverified. |
| `rd.*` catalog ops with risk classes (s10.2) | NO OWNER | - | - |
| Phase 2: macOS host in the helper, consent, indicator, grants, audit, clipboard, RFB client | NO OWNER | - | Shares the helper with computer use. |
| Phases 3-4: Wayland, Windows, audio, files, iOS and web clients, AV1, multi-viewer | NO OWNER | - | Later phases. |
| D-RD2: apply now for restricted macOS entitlements | NO OWNER | - | Waiting for Lawrence. |
| Remote Chromium tab view: CDP screencast, relayed input, iOS reuse (U4) | NO OWNER | - | Not in any plan step. |

## VM image, cmux server, transport, release, fleet

Source: spec/plan-vm-image.md, spec/plan-server.md, spec/plan-transport.md, decisions V1-V3, SV1-SV3, SV-R1..R4, T1, T3, T4, L12-1, D3, D37, D38, R1, R2, P3, P10, FL1-FL3, W1.

### VM image

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| VM image plan: three layers, roles, store, bind agent (V2; plan-vm-image s1-s9) | DONE | 5463f137409 (plans/cmux-next/vm-image.md) | This row covers the plan only. |
| V1 package list (plan-vm-image s4.2) | DONE | 5463f137409 (vm-image.md s4.2) | The list is written. Chief is not in the base image. |
| Three-layer image recipe: images/cmux-vm, inputs.lock, dated apt mirror, SBOM, CI bake and smoke (V2; s4.1, s4.10, s4.11, step 1) | NO OWNER | - | There is no images/cmux-vm. L1 did the plan and prototypes only (unverified). |
| Coderouter and curated programs in every VM by default (V1) | NO OWNER | - | Partial: the devbox writes the model-plane env. Store delivery does not exist. |
| `cmux host` bind agent and supervisor: event-driven, reseed, machine-id regen, roles, desktop off (V2; s4.3, s4.4, s6, step 2) | NO OWNER | - | Partial: the clone-identity verifier is on main (c7cdb4c3c4ce). The boot supervisor still polls every 1 s. |
| Store updater, signed channel manifest, KMS key for CI only, files mirror (V2; s4.5, step 3) | NO OWNER | - | Manifest verify exists (cmux-server-core manifest/validate.rs). Updater, CI signing and mirror do not exist. |
| Team role, JuiceFS and automations host in the image (step 4) | NO OWNER | - | Waits for the storage spike and the server design. |
| `vm.image.*` ops and `cloud.machines.*` settings (s10) | NO OWNER | - | No catalog or app entries found. |
| Idle-wakeup fix (host and daemon) on main (V3 precondition) | DONE | bb98521eef0 (main), 51b68635143 (feat) | Terminal host and daemon block on events. |
| Verifier idle-wakeup and clone-identity check (s13.3, s13.6) | DONE | c7cdb4c3c4ce (main) | The promotion gate uses this check. |
| V3 prototype rebake from main (cmuxnp-dev-) | DONE | b8b55a63d897 (vm-image.md s13.10) | All checks pass. The p95 readiness tail is worse (cause unverified). |
| Production promotion plan with rollback (V3; s13) | DONE | 13693f40df43 | The plan is ready. |
| Production snapshot promotion (V3; s13.5-13.8) | IN PROGRESS | L1 a62c42237cb5703d4 | Waits for Lawrence. A 10-clone p95 readiness comparison is the gate. |
| Four review bugs on feat-cmux-next (L1 report) | IN PROGRESS | L1 a62c42237cb5703d4 | The coordinator has the report. |
| Make the new image the cmux-next default (step 5) | NO OWNER | - | Depends on steps 1-4. |
| Idle-wakeups open items: heartbeats, DemandTimer migration, busy-watchdog tab mapping (plans/cmux-next/idle-wakeups.md s8) | NO OWNER | - | App-side list. No lane owns it (unverified). |

### cmux server

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Server plan (plan-server step 1) | DONE | 5bf3ec9bbfb (plans/cmux-next/server.md) | SV-R1..R4 are recorded in the spec. |
| `cmux-server-core` pure crate, 38-op catalog (step 2) | DONE | 2f9adf172c8 | Pure logic, no I/O. |
| Headless Linux prototype: installer, PG17 PITR, headless Chromium, inhibitors (step 3) | DONE | server/prototype/linux | aarch64, macOS and Windows are unverified. |
| CmuxNextServer Swift prototypes (step 4) | DONE | 25d9832f8dd | Only in Debug Settings. |
| `cmux server up` on Linux: I/O crate, roles, supervisor, CLI mount (SV1; step 5) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Branch server-io2 7f76c6ed02b waits for the cmux-tui landing window. |
| SV-R1..R4: baked keys, re-exec upgrade, tar.gz only, 0755/0700 split | IN PROGRESS | L10 a07ed15c10e36f8c8 | R1 is on server-io2. R4 is not applied: core still sets 0700 on the user-mode root. |
| Make This Mac a Server: menu bar and palette, launchd (SV1; step 7) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Branch ea534b58c31 is not landed. No palette action exists. |
| One-command curl install: signed install.sh per release (SV1; s4.1-4.2) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Prototype script only. Release CI publish not started (unverified). |
| Server Postgres per app: unique port, local listener, peer/role auth (SV2; s8) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Plan logic in core (pg/, ports.rs). The runner is on server-io2. |
| Health probes, alerts and feed posts (SV3; s9.2-9.3) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Reducer in core. Probes on server-io2. `feed.notify` not wired. |
| Power assertions and no-sleep (SV3; s9.1; Caffeinate host capability) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Linux logind on server-io2. macOS IOPM and `power.assertion.*` not started. |
| One-click fixes through the privileged helper (SV3; s9.4) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Branch bf1f284d22b, not landed. |
| PairingDO, `server.pair.*`, TeamDO host kind server (step 6) | DONE | 23dd7e308b9 (backend/apps/api/src/pairing-do.ts) | Approve, revoke and revoke_by_team included. |
| Pairing over WireGuard: tunnel config and peer map for the server (SV1; s6.2 steps 4-5) | IN PROGRESS | L12 a00f9f88e497a3922 | PairingDO returns host and token only. Peer map comes with `network.device.join`. |
| Network policy `tag:server` (step 6) | IN PROGRESS | L12 a00f9f88e497a3922 | Comes with the TeamDO policy reconciler. |
| Server approve from iPhone QR scan and web page (s6.2 step 3) | NO OWNER | - | Only the Mac approver prototype exists. |
| App servers: manifest server block, host election, lease fences, durable data, tenancy (N13; s7) | NO OWNER | - | The notes server exists (b9de9d172cd). Lease, election and backups have no owner. |
| Server browser host and `server.software.*` (s10) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Ops in the core catalog. I/O not landed (unverified). |
| Windows installer, service and probes (step 8) | IN PROGRESS | L10 a07ed15c10e36f8c8 | The plan says "later". Not started. |

### Transport

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Transport plan (T3) | DONE | 7601bdd599b (plans/cmux-next/transport.md) | Lane 12 decisions 1-6 and 8 are accepted. |
| `cmux-transport` pure core: classifier, STUN, relay frame, selector (step 1) | DONE | 3e8627a7096 | Property tests and mutants included. |
| `cmux-wg` engine: multipath, pacing, backpressure (D3 phase 2; step 2) | DONE | 99ca23d8102 | The `--full` run was not repeated after the rebase. |
| First-connect watchdog for the idle-tunnel stall (s13.6) | DONE | b1e188d4e49 (cmux-wg/src/watchdog.rs) | Release compile green. |
| 10-minute link TCP user timeout | IN PROGRESS | L12 a00f9f88e497a3922 | Not started. |
| Datagram service and path events (s12a; remote desktop asks) | IN PROGRESS | L12 a00f9f88e497a3922 | Not started. |
| Peer overlay address in WgConfig (s3.1) | IN PROGRESS | L12 a00f9f88e497a3922 | Not started. |
| HostDO rendezvous, datagram relay, placement by probe (T3; step 3) | IN PROGRESS | L12 a00f9f88e497a3922 | Partial: pure codec fc9cf5a090e landed. DO class and migration tag v9 remain. |
| `network.device.join/rotate/revoke`, Freestyle firewall reconciler, peer map push (D3 phase 1; step 4) | IN PROGRESS | L12 a00f9f88e497a3922 | Partial: manual firewall and tunnel ops exist (b8093c65137). TeamDO reconciler missing. |
| One Freestyle VPC per team (D37) | IN PROGRESS | L12 a00f9f88e497a3922 | Today one VPC per owner. Team VPCs not built (unverified scope). |
| Per-device IPv6 firewall rule | IN PROGRESS | L12 a00f9f88e497a3922 | Waits for `network.device.join`. |
| LAN discovery and NAT-punched direct path (T3; s5; D38) | IN PROGRESS | L12 a00f9f88e497a3922 | STUN codec and selector done. Candidate exchange needs HostDO. |
| Overlay provider in cmux-remote, `cmux link` dialing, session routing, "via cloud region" label (step 5; T2; D38) | IN PROGRESS | L12 a00f9f88e497a3922 | Not started. |
| T4: overlay carries cmux.wire/1 frames unchanged | IN PROGRESS | L12 a00f9f88e497a3922 | Needs the overlay provider. |
| iOS in-app WireGuard endpoint (T3; s11) | IN PROGRESS | L12 a00f9f88e497a3922 | Not started. L14 integrates it. |
| Wi-Fi to cellular roaming test | IN PROGRESS | L12 a00f9f88e497a3922 | Needs the phone, the L14 Network Lab and a slot with Lawrence. |
| Delete the old relay paths (T1; s14; step 6) | IN PROGRESS | L12 a00f9f88e497a3922 | CmuxNextMobile still uses the old relay. Deletion after the overlay ships. |
| Ask Freestyle for direct tunnel-to-tunnel paths (D38; s16) | NO OWNER | - | Lawrence is the contact. Not sent (unverified). |
| Direct host-to-host bulk copy under a job grant (L12-1) | NO OWNER | - | Accepted. No implementation or job owner. |

### Release and nightly

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| nightly-next workflow, promote workflow, feed guard (R1; R2) | DONE | d43ea8aabad (.github/workflows/nightly-next-promote.yml) | Debounced to one build per 2 h. |
| Sparkle feed classification: channel cmux-next, nightlyNext feed (R1) | DONE | d43ea8aabad (CmuxNextUpdater/UpdateBuildIdentity.swift) | Whether the Swift tests ran is unverified. |
| release-next env, protected nightly-next branch, scoped R2 token, separate Sparkle key (R2) | DONE | d43ea8aabad; live infra per L21 | Ruleset 24398398, bucket cmux-nightly-next. |
| First nightly-next publish (approved base 1e6c86ba7aef) | IN PROGRESS | L21 a6af4f2116fab191c | Nothing published yet. |
| cmux hq offers the nightly-next download (R1) | IN PROGRESS | L21 a6af4f2116fab191c | Not started. |
| Move repo-level signing secrets into environments (R2 finding) | NO OWNER | - | Any in-repo branch workflow can read them. Needs Lawrence. |
| Fresh tagged app for Lawrence every few hours (P3) | NO OWNER | - | No mechanism found. nightly-next may cover it once it publishes. |
| Daemon capability CI gate, cmux-tui from the same commit, automatic pin bumps (P10) | NO OWNER | - | Only manual awaitingPin lists exist. |

### Fleet and process

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Fleet alerts, data-path health, weekly report (FL1) | DONE | hq a2569a90f5, af0ee271fc | Alerts cover silent workers, streaks and wedged disk. |
| R2 artifact store as fallback for every worker (FL1) | DONE | hq 29fd13dc6b | The old cache host stays retired. |
| aws-m4pro-1 one-time fallback fix (FL1) | DONE | hq 8df6b3fcf1 | Fallback removed and the host excluded. |
| Dedicated fleet lead, self-healing (FL1) | IN PROGRESS | L6 aea7f7dc2fc0196d6 | Ongoing: mini-6 gc, CEF recipe, controller move plan. |
| cmux-browser on the Xcode 27 pin, DEVELOPER_DIR (FL2) | DONE | cmux-browser-hq 3bf1644, ddec5c5 | - |
| cmux-lawrence-2 build host, weekly report LaunchAgent (FL3) | DONE | hq 8cf23e858c, e1278eeb11 | Temporary R2 token revocation is from the decision text (unverified). |
| Direct commits on feat-cmux-next (W1) | DONE | lane rules adopted; b1e188d4e49 landed directly | Process item. |

## Cloud, automations, team VM, network policy, agent egress

Source: spec/cloud-and-automations.md, spec/automations-runtime.md, spec/automations-billing.md, spec/team-vm.md, spec/network-policy.md, spec/agent-egress.md, decisions D11, D13, D21, D27-D39, A10-A21, R7, C1.

### Cloud machines

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Machine record stays in the old backend, reached only through its API (D11 phase 1) | DONE | 50eb18daa53 | The typed host relay calls the old VM API. |
| Move machine records to PlanetScale cmux-next with host_registry_id, purpose, idle_policy (D11 phase 2) | NO OWNER | - | No migration and no ops. |
| Machine lifecycle and snapshot ops | DONE | 50eb18daa53, cec34217405 | backend/catalog/cloud-relay-operations.json. |
| vm.exec and machine file ops | DONE | 07cbf3a01ba, da9bb3dacd1 | Exec plus fs list/read/write/mkdir/remove/stat. |
| vm.attach, open_port, ssh/scp, ephemeral create-run-destroy | NO OWNER | - | Not in the relay catalog. Earlier slices by Leo (owner unverified). |
| Idle policy mapped to Freestyle, vm.ensure_awake, vm.idle_policy.set (D21) | NO OWNER | - | The old driver still disables idle timeout. Freestyle idle semantics not measured. |
| Every machine runs cmux link to HostDO; Cloud VMs enroll at create | IN PROGRESS | L12 a00f9f88e497a3922 | HostDO is transport step 3 (DO tag v9). Not landed. |
| Self-hosted machines enroll through pairing (U2) | DONE | 23dd7e308b9 | PairingDO and server.pair.*. |
| host.enroll/list/revoke in the TeamDO directory | DONE | backend/packages/protocol/src/ops.ts, 0ce9557ca76 | Revoke ships as host.remove and server.revoke. |
| Each machine shows as a machine tree in the sidebar | DONE | CmuxNextApp/Cloud/CloudService.swift | Reconciles the VM list into MachineRegistry sessions. |
| "Runs" group, group by purpose, asleep machines shown without waking | NO OWNER | - | Needs vm.stats asleep and the purpose field. |
| Per-run tokens and edge-injected VM credentials (Security) | NO OWNER | - | No run-token minting. Edge rules after create untested. |

### Automations core

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| SchedulerDO per owner, one Workflow per run (D13) | DONE | 4fe264a3e0e | scheduler-do.ts, automation-workflow.ts. |
| Automation shape v1 as Effect Schema in the catalog | DONE | backend/packages/protocol/src/automations.ts | - |
| Dedupe keys; a duplicate instance id never starts a second run | DONE | 4fe264a3e0e | Delivery table kept 30 days. |
| automation.create/update/delete/run/list/get/runs.list/webhook.get | DONE | backend/packages/protocol/src/automation-ops.ts | - |
| run.get/cancel/retry/approve/logs; approval steps | NO OWNER | - | Tied to the run UI. |
| Event-driven deadlines and persisted retry backoff | DONE | 6d68dd5cb77 | - |
| 24 h default limit for an agent run, customizable (A19) | DONE | 40826e8357e | Shared teams refused until roles exist. |
| cron, manual, continue triggers | DONE | backend/apps/api/src/domains/scheduler.ts | - |
| Signed webhook trigger | DONE | cfe5c1b6073 | - |
| Integration event triggers (GitHub, Linear, Slack) | DONE | e43ae60fd19 | - |
| Task event trigger | IN PROGRESS | coordinator: Tasks lead | Stored as not_yet_supported today. |
| message, presence, machine, store triggers | NO OWNER | - | Stored as not_yet_supported. |
| steps body (sleep, note) | DONE | 4fe264a3e0e | - |
| op step type (integration and catalog ops) | NO OWNER | - | Spec "step 3". |
| agent_prompt body ("an automation is a message to a chief") | NO OWNER | - | Fails with body.unsupported. Needs MuxDO and placement. |
| TargetPolicy host; remote steps wait on the daemon exit receipt | NO OWNER | - | Depends on HostDO and the link (L12). |
| Projection tables automations, automation_runs | DONE | backend/db/migrations/0003_automations.sql | - |
| Projection read path (read-only role and Hyperdrive per env) | NO OWNER | - | Not created. |
| Import old local automation rules | NO OWNER | - | - |
| Creation UX: a chief chat fills one editable form | NO OWNER | - | No automations UI in app, apps or dashboard. |
| Run history UI with loud failures and notifications | NO OWNER | - | - |
| Concurrency per automation, queue or skip as visible rows | DONE | backend/apps/api/src/domains/scheduler.ts | - |
| Per-run budgets pause the run in `waiting` | NO OWNER | - | Only the wall-clock deadline exists, and it terminates. |

### Automations runtime tiers (A11-A17, R3, R8, R9)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Runtime research plan, rounds 1 and 2 | DONE | 6620725970c | Plan only. |
| env.cmux binding generated from the catalog (A11) | NO OWNER | - | Nothing in code. |
| One code.storage repo per team, automation.deploy, code_ref pin, body {type: code} (A12, C1) | NO OWNER | - | No code.storage client. |
| Tier 1: Dynamic Workers and Dynamic Workflows (A13, A20) | NO OWNER | - | No loader, egress or tail bindings in wrangler.jsonc. |
| No Workers for Platforms for automations (A20) | DONE | 8e2f9955aaa | Research closed. |
| Tier 2: automations-host role (pinned workerd, wake shim) (A14) | NO OWNER | - | L1 bakes workerd and L10 lists the role. Nobody builds it. |
| Record tier-2 soak results (runtime plan step 1) | NO OWNER | - | Results never recorded. |
| Rust Workflows-compatible engine and conformance suite (R3) | NO OWNER | - | R3 still open. |
| Evaluate a no-polling TypeScript durable library on Postgres (A14) | DONE | 6620725970c | None is fully event-driven. |
| Observability by default: logs, traces, run timeline, alerts (A16) | NO OWNER | - | - |
| Telemetry store (R8) | NO OWNER | - | R8 open. |
| cmux-automations skill and `cmux automations init/test/deploy/run` (A17) | NO OWNER | - | No skill exists. |
| Job queue for apps on the team VM (R9) | NO OWNER | - | R9 open. |

### Automations billing (A18, A21)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Billing plan: metering design | DONE | 8e2f9955aaa | Plan only. L5 finished. |
| UsageMeterDO per-team ledger (A21) | NO OWNER | - | Not in code. |
| Plans with quotas plus metered overage; hourly Stripe meter events (A18) | NO OWNER | - | Quota and price levels not set. |
| Daily reconciliation against Cloudflare usage APIs | NO OWNER | - | - |
| Per-team abuse limits: CPU, subrequests, steps, creation rate, deploys, egress | NO OWNER | - | Only per-automation concurrency exists. |

### Team VM (D27-D36, A15, R7)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Every team gets a team VM, created with the team | NO OWNER | - | No create path. |
| TeamVmDO: VM id, wake and idle leases, routing, KRL push | NO OWNER | - | The "team VM lead" has no agent. cmux-tasks Owner::resolve is a stub. |
| Team VM image and `team` role set | IN PROGRESS | L1 a62c42237cb5703d4 | Plan only. Promotion waits for Lawrence. |
| Default Postgres per app: role, database, peer auth, WAL to R2 (A15, R7) | IN PROGRESS | L10 a07ed15c10e36f8c8 | Plan logic in cmux-server-core. Runner and team_vm.db.* remain. |
| Linux user and group reconciler from TeamDO; UIDs never reused (D27) | NO OWNER | - | - |
| Permission hierarchy compiled to role groups, POSIX ACLs, setgid, umask 007 (D27, D29, D30) | NO OWNER | - | - |
| SSH CA in TeamDO, team_vm.ssh_cert, sshd trust, revocation, force-command (D28) | NO OWNER | - | transport.md plans the client side only. |
| SSH Path A over userspace WireGuard (D33 rec) | IN PROGRESS | L12 a00f9f88e497a3922 | Engine landed. Link overlay provider remains. |
| SSH Path B: public gate on Fly.io (D32, D33, D34) | NO OWNER | - | D33 and D34 open. |
| Zero-loss tier (JuiceFS, R2, Postgres metadata), spike, backup and restore (D31, D35, D36) | NO OWNER | - | D35 and D36 open. |
| Move the mailbox to the team VM; `cmux team mail` (D32) | NO OWNER | - | Blocked on team VM and SSH certs. |
| Memory repos (org and person), team.memory.* ops (D29, D30) | NO OWNER | - | The memory app browses local files only. |
| Self-modifying apps: team_vm.app.deploy/rollback | IN PROGRESS | L10 a07ed15c10e36f8c8 | Plan only (server.md s7). |
| Strong audit on the VM: auditd, key-id map, hash chain off the VM | NO OWNER | - | Backend audit chain c122d5b4488 is enterprise audit only. |
| Tasks service runs on the team VM | IN PROGRESS | coordinator: Tasks lead | Local `cmux-tasks serve` only. Waits for TeamVmDO. |

### Network policy (D3, D37, D38)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Policy document in TeamDO; network.policy.get/preview/apply/rollback; lockout guard | IN PROGRESS | L12 a00f9f88e497a3922 (owner unverified) | Unlanded branch feat-cmux-next-network-policy 634f024602d. |
| Reconciler to Freestyle firewall rules, one VPC per team, drift report (D3, D37) | IN PROGRESS | L12 a00f9f88e497a3922 | Same unlanded branch. |
| network.device.join/revoke and the Mac join flow | IN PROGRESS | L12 a00f9f88e497a3922 | The app still uses the old tunnel path. |
| network.machine.tag and tagOwners | IN PROGRESS | L12 a00f9f88e497a3922 | Unlanded branch only. |
| Per-user tunnel and firewall relay ops | DONE | b8093c65137 | Flag: owned by UserDO, but the spec puts team policy in TeamDO. |
| Same-LAN discovery, DO relay, "via cloud region" label, network.path.status (D38) | IN PROGRESS | L12 a00f9f88e497a3922 | Selector landed. HostDO relay and path events remain. |
| Phase 2: TeamDO pushes peer maps to userspace WireGuard (D3) | IN PROGRESS | L12 a00f9f88e497a3922 | Engine and watchdog landed. |
| Policy history and audit projection; `cmux network policy log`; dashboard view | NO OWNER | - | - |
| Send the Freestyle ask list | NO OWNER | - | Drafted in transport.md s16. Not sent (unverified). |

### Agent egress (D39)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Egress rules in the policy and a compiler to three enforcement points | NO OWNER | - | The network-policy branch has no egress section. |
| Integration gateway: secret injection, per-op grant, approvals | IN PROGRESS | coordinator: backend lead | ConnectionDO tokens and provider ops landed (e43ae60fd19, 80e83c37d59). |
| Team VM egress proxy (CONNECT and SOCKS5) with per-connection credential | NO OWNER | - | - |
| Freestyle firewall default deny for agent workloads | IN PROGRESS | L12 a00f9f88e497a3922 | Plan only. |
| Local Mac cooperative egress: proxy env, local log, UI label | NO OWNER | - | - |
| One team audit stream and egress.log.query | NO OWNER | - | The enterprise audit chain could be the base (unverified). |
| Customer-owned tailnet: OAuth connection, ephemeral node on the team VM | NO OWNER | - | - |

### Related plans (cloud parity, cloud iOS, coderouter, remote localhost)

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| Cloud parity inventory | DONE | 051c93d627f | - |
| Code-mode typed Cloud relay, catalog allowlist, script origin | DONE | 50eb18daa53, d9ff76202c9, 5ec59529569 | - |
| VM domains and publications | DONE | 62690c42c48 | - |
| Remaining cloud parity: TLS, identities, tokens, billing views, skill install, Machines section, Settings Cloud | NO OWNER | - | Leo's cloud-parity branches are unlanded. Owner unverified. |
| cloud-ios P1-P5 (iOS on daemons) | IN PROGRESS | L14 a137f79e0edfeef9c | Replaced by the iOS rewrite plan. |
| CodeRouter accounts in cmux-next | DONE | 270b069f273 | CmuxNextCodeRouter and CmuxNextAccounts. |
| CodeRouter handoff lease; VM token scope conflict | NO OWNER | - | Flag: plan lets VM tokens manage the pool; spec denies it for automation VMs. |
| Remote localhost stages 1-3 | DONE | a3b144cd437, 6e846afdc6a | Stage 4 (WebKit) blocked by macOS. |
| Remote localhost open items: palette and CLI override, profile delete cleanup | NO OWNER | - | - |

## Enterprise, integrations, Tasks

Source: spec/enterprise.md, spec/integrations.md, spec/tasks.md, spec/tasks-design.md, decisions E1-E10, I10-I13, S1-S4, D14, D17, F2, F3, H12, U0.

### Enterprise

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| TeamPolicy typed record, `team.policy.get/history/update/rollback`, CAS (s4.1-4.3) | DONE | 23721bb0a8a | 26 keys. |
| Policy projection into ConnectionDO (s4.6, I11) | DONE | 0f5ad2e41d4, 45346f621ff | Pushes only when the slice changes. |
| SSO/MDM lock wins; only an admin releases it, audited; TeamDO re-pushes (E10) | DONE | 101d7e108c2, 2e727bf024a | Nothing writes SSO or MDM locks yet. |
| Swift managed-prefs reader, domain com.manaflow.cmux, legacy DisableAutoUpdate, precedence (s4.4, s5.1-5.2, E6) | DONE | 6aa4a6e1170 (CmuxNextSettings/Managed/) | Reloads on file change. |
| MDM can lock every setting (U0) | DONE | 6aa4a6e1170 (ManagedPreferencesManifestTests.swift) | Golden test fails when a setting lacks MDM metadata. |
| Settings shows "Managed by..."; `SettingManaged` refusal on every path (s4.4) | DONE | 6aa4a6e1170, 71a826d67d3 | Palette and action.run refuse too. |
| Settings "Why?" and palette "Show Managed Settings" (s4.4, s8) | IN PROGRESS | coordinator: enterprise lead | Not built. |
| MDM forced wins, conflict reported (E2) | DONE | 71a826d67d3 | - |
| Device keys only from the managing team (E3) | IN PROGRESS | coordinator: enterprise lead | TeamPolicyLayer landed (775ae29f9fa). App wiring and accept step remain. |
| Generated MDM schema artifacts (s5.3) | DONE | 6aa4a6e1170 (docs/mdm/) | Golden test. |
| Publish the schema at cmux.com/mdm/ each release (s5.3) | NO OWNER | - | No release or web step. |
| Vendor guides and legacy-profile declaration (E8, M3) | DONE | 71a826d67d3 (docs/mdm/vendors.md) | Console paths not checked live. |
| Local managed-status.json for device tools (E9, M1) | DONE | 71a826d67d3 | Never writes the token value. |
| Device compliance report and query (E8, E10, M2) | DONE | adae3ffd834 | Backend only. |
| Enrollment tokens (hashed), enroll and release, only admins release (s5.4, E9) | DONE | c122d5b4488, 93c6fe9259f | - |
| `device.settings` policy key carries cmux.json settings (E9) | DONE | 5713da68de0 | - |
| App enrolls after sign-in, subscribes to device policy, reports status (M7) | IN PROGRESS | coordinator: enterprise lead | Blocked: the app has no new-backend client. |
| Rust config reader and shared precedence vectors (s5.2, E4) | IN PROGRESS | coordinator: enterprise lead | Planned. No code. |
| Linux /etc/cmux/policy.json (s5.7, M5) | IN PROGRESS | coordinator: enterprise lead | Depends on the Rust reader. |
| `cmux mdm status --json` (E8, M4) | IN PROGRESS | coordinator: enterprise lead | Planned. |
| iOS managed app config (s5.8, E8, M6) | IN PROGRESS | coordinator: enterprise lead | After the iOS app uses cmux-next settings (L14). |
| ManagedUpdatePolicy reads through SettingsController only | IN PROGRESS | coordinator: enterprise lead | The updater still reads DisableAutoUpdate itself. |
| DisabledFeatures enforcement on surfaces and hosts (s5.5) | NO OWNER | - | Key parsed, nothing reads it. |
| Device-side UpdateChannel, MinimumVersion, RestrictToManagedTeam, AllowedSignInMethods (s5.1, s5.4, s5.5) | NO OWNER | - | Keys are in the manifest only. |
| Server-side key enforcement: minimum version at token mint, computer use at relay, sandboxes, retention (s4.2, s4.5) | NO OWNER | - | Schema only. |
| `apps.*` policy at app.install (s4.2) | IN PROGRESS | coordinator: app platform lead | The install reducer ignores TeamPolicy. |
| `agents.allowedClasses` at grant mint (s4.6) | NO OWNER | - | Waits for a grant-mint owner. |
| DomainDO, DNS TXT over two resolvers, weekly re-check (s3.4) | DONE | 49fe00b869a, ee7ecc9aebd | - |
| SSO discovery endpoint, rate limited (s3.3) | DONE | 72e72ce7041 | - |
| OIDC connections and sign-in (E1) | DONE | 88ba33fe0d7, d87eefd864e | - |
| Stack server calls verified against real Stack on staging | IN PROGRESS | coordinator: enterprise lead | Tested against a fake only. |
| Own SAML validator with attack corpus (E1) | DONE | 3e4541e8882, 2ac73b13639 (backend/packages/saml) | - |
| SAML SP wiring: ACS, SP metadata, replay cache | IN PROGRESS | coordinator: enterprise lead | Validator landed. No API route. |
| SCIM 2.0 Users and Groups (s3.5, E1, I12) | IN PROGRESS | coordinator: enterprise lead | Blocked on shared teams. No code. |
| IdP groups to Linux groups through the team-host reconciler (s3.5) | NO OWNER | - | Needs a team VM reconciler. |
| JIT provisioning, owner break-glass, sso.allowGuests (s3.3, s3.6) | IN PROGRESS | coordinator: enterprise lead | Blocked on shared teams. |
| Enforced SSO, session max age, idle timeout at authenticate (s3.6) | IN PROGRESS | coordinator: enterprise lead | Policy invariants landed. Enforcement point missing. |
| SSO sign-in clients: native web auth session, dashboard button (s3.3, s5.6) | IN PROGRESS | coordinator: enterprise lead | No client calls the SSO endpoints. |
| Shared teams and roles guest/member/admin/owner/billing (H12) | IN PROGRESS | coordinator: backend lead | Ordered after Home stages B and C. |
| Audit hash chain and audit_events (s6, E9) | DONE | c122d5b4488 (backend/db/migrations/0005_audit_events.sql) | Applied to staging and production. |
| Daily signed audit checkpoint to R2 with object lock (s6) | IN PROGRESS | coordinator: enterprise lead | Not started. |
| Audit views: dashboard page, `cmux team audit log`, JSON export (s6, s8, E7) | IN PROGRESS | coordinator: enterprise lead | No op yet. |
| Dashboard /policy and /devices (s7) | DONE | backend/apps/dashboard/src/routes/policy.tsx, devices.tsx | Browser check unverified. |
| Dashboard SSO, domains, directory, audit pages (s7) | IN PROGRESS | coordinator: enterprise lead | Not built. |
| Enterprise ops in the catalog with CLI paths, MCP never (s8) | IN PROGRESS | coordinator: #16174 Rust CLI owner | Catalog entries landed. CLI generation unverified. |
| Paid gate: F2 plan-flag cron to TeamDO, paid ops check it (E5, F2) | IN PROGRESS | coordinator: enterprise lead | Not started. |
| "cmux Enterprise required" notice for admins without a plan (E7) | IN PROGRESS | coordinator: enterprise lead | Not built. |

### Integrations

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| ConnectionDO per team, sealed tokens, private/team sharing | DONE | e43ae60fd19 | Interim key wrap. |
| KMS wrap replaces the Worker-secret key | NO OWNER | - | Same stored shape. |
| GitHub App connection, installation tokens, issue comment (D14, I10) | DONE | e43ae60fd19 | - |
| Linear and Slack bot connections and ops (D14, I10) | DONE | e43ae60fd19 | - |
| Google Calendar connection and calendar.* ops (D14) | NO OWNER | - | The app shows "Not set up yet". |
| Gmail send/readonly/modify connection and mail.* ops (D14, S3) | NO OWNER | - | No Google provider. |
| CASA steps 0-8 (S1) | NO OWNER | - | Not code. No integrations lead named. |
| Gmail Pub/Sub watch, history normalizer, new-email triggers, ids only (S2) | NO OWNER | - | Waits for CASA and Gmail. |
| SchedulerDO watch and channel renewal, renewal-health alerts | NO OWNER | - | - |
| Provider webhooks verified and routed with dedupe | DONE | cfe5c1b6073, e43ae60fd19 | GitHub, Slack, Linear. |
| Ingestion remainder: event log, Queue, normalizer, R2 payloads, event.search/get | NO OWNER | - | Webhooks go straight to SchedulerDO. |
| GitHub scope policy: linking user's repos, allow list, org admin (I11) | DONE | 3a400ccd632, 0f5ad2e41d4 | - |
| installation_repositories webhook refresh | NO OWNER | - | Only re-linking refreshes today. |
| integration.policy.set forwards to team.policy.update (F3) | NO OWNER | - | It refuses with policy.locked today. |
| Gateway approval rules and per-connection rate limits | NO OWNER | - | Grant admission exists. No token buckets. |
| Agent app installs blocked; only users install (I13) | DONE | 00951dc6d24 | - |
| Integrations first-party app prototype and MIT integrations core | DONE | 03a82832d11, 81c2178ceb1 | Never ran in a tagged build. |
| Integrations app v2 | IN PROGRESS | L3 a98142a865bc6d642 | WIP; tests fail; needs backend lead agreement. |
| Browser path for Gmail and other sites until CASA (D14) | IN PROGRESS | coordinator: browser REPL parity owner | Not verified. |
| Second wave: Notion, Sentry, Stripe, PostHog | NO OWNER | - | After the launch set. |

### Tasks

| Item (source) | Status | Evidence / owner | Note |
| --- | --- | --- | --- |
| cmux-tasks-core: model, reducer, invariants, proptests, 36-op catalog (D17) | DONE | 2964b2169ac, e442b6d7584 | - |
| cmux-tasks service: op-log store, snapshots, socket server, client | DONE | 2964b2169ac | Local disk only. |
| Standalone cmux-tasks CLI | DONE | cmux-tui/crates/cmux-tasks/src/cli | - |
| CmuxNextTasks module: mirror, intent log, three layouts | DONE | 2964b2169ac | - |
| `cmux task` mounted in the cmux binary | IN PROGRESS | coordinator: Tasks lead | Unblocked now that #16174 merged. |
| App wiring: Tasks tab kind, palette, daemon supervises serve, settings | IN PROGRESS | coordinator: Tasks lead | The pane never opens in the app. |
| MCP tools wiring | IN PROGRESS | coordinator: Tasks lead | Only definitions exported. |
| Agent dispatcher: claim, acp.session.create, attach | IN PROGRESS | coordinator: Tasks lead | Owner side only. |
| Automation delivery of task events | IN PROGRESS | coordinator: Tasks lead | Not built. |
| Authenticated actors on the Tasks socket | IN PROGRESS | coordinator: Tasks lead | The socket trusts the hello actor. |
| PlanetScale outbox projection: search, cross-team views, inbox counts (S4) | IN PROGRESS | coordinator: Tasks lead | Needs a migration. |
| GitHub PR auto-link and one-shot importer | IN PROGRESS | coordinator: Tasks lead | Not started. |
| Team VM hosting: TeamVmDO wake, route, lease (S4) | NO OWNER | - | Owner::TeamVm returns unreachable. |
| Zero-loss durability: log to R2 or the zero-loss tier, snapshots (S4) | NO OWNER | - | Depends on the storage tier (unverified). |
| Cross-team move saga and TLA+ model | IN PROGRESS | coordinator: Tasks lead | Not in the Tasks plan (unverified). |
| Fork model: template, contract tests, upgrade flow (S4, D17) | IN PROGRESS | coordinator: Tasks lead | Drift test and property suite landed. |
| Tasks as first-party app cmux/tasks with server block | IN PROGRESS | coordinator: Tasks lead | Schema fixture landed. No manifest. |
| Tasks web dashboard | IN PROGRESS | coordinator: Tasks lead | Not started. |
| Tasks decisions T1-T5 (tasks-design s11) | IN PROGRESS | coordinator: Tasks lead | Not in decisions.md. Lawrence must decide. |

## NO OWNER work packages, in priority order

Order: Lawrence's direct asks first (decisions marked as Lawrence's, plus Home, iOS, nightly, windows and Settings), then items that block other lanes, then the rest. Each package groups NO OWNER rows that one agent can own. "Covers" names the rows from the tables above.

### Tier 1: Lawrence's direct asks

**P1. Chief on the Mac (H8, D10, IOS2)**
- Covers: Chief brain as a Rust port on the Mac; Chief tools as a generated code-mode API; conversation.promote.
- Goal: Chief runs inside cmux, in-process with cmux-conversation and acpmux, and calls only typed catalog ops. A local conversation can be promoted to a ConversationDO.
- Files: mux/host, mux/packages/brain, cmux-tui/crates/cmux-conversation, acpmux, CmuxNextHome/HomeBrainHost.swift, catalog generator.
- Done when: Chief answers on the Mac with no env-var host, the shared behavior corpus passes on both brains, and promote works end to end with tests.
- Depends on: a cmux-tui landing window; Home ops routing (finding 2). Coordinate with: coordinator Home lead, L15, L16.

**P2. Cloud Home completion (spec home-and-agents, B10, H2)**
- Covers: always-on cloud brain on MuxDO; Home push from UserDO; attachments to R2; web dashboard Home; self-hosted Home owner; Chief memory in the team VM.
- Goal: Home works with no Mac awake, notifies the phone, carries images, runs on the web, and runs self-hosted with the same reducers and SQL.
- Files: backend/apps/api (mux-do.ts, user-do.ts, wrangler R2 and loader bindings), backend/apps/dashboard, backend/packages/home-core, server/.
- Done when: a cloud Chief replies with no Mac; a staging message reaches the phone with badge = unread; an image round-trips on iOS and Mac; the corpus passes on the self-hosted adapter.
- Depends on: Home ops routing (backend lead), L14-2 push targets, L10 server for self-hosting. Coordinate with: coordinator Home lead, backend lead, L9, L14, L15.

**P3. Relationships and team roles (H3, H5, H12)**
- Covers: Contacts, Grants and Team as separate primitives; compose dropdown; message requests in app and by email; roles guest, member, admin, owner, billing.
- Goal: build the accepted relationship model and the role rules.
- Files: backend/packages/home-core, AddressDO, ConversationDO, TeamDO (domains/team.ts, team-audit.ts), iOS compose sheet.
- Done when: the dropdown shows only related people; team invites use their own sheet; guests are free; billing sees only billing audit; only owners remove admins; reducer tests cover each rule.
- Depends on: shared teams (backend lead). Coordinate with: L15, coordinator Home lead, enterprise lead (SSO JIT uses the same roles).

**P4. iOS terminal: ghostty-next round 2 and host snapshots (IOS1, plan-ghostty-next s3, s6, s11, s12)**
- Covers: `ghostty_surface_set_grid`; `ghostty_surface_restore_snapshot`; surface calls never block; iOS ports (72 DPI, layer teardown, bounded wait); host snapshot capability (terminal-snapshot-v1, terminal.history, read_range, digest); phone sizing rules and fixtures; terminal frame fields kind/generation/offset and presence (T4); fidelity corpus and 100 MB flood test.
- Goal: the iOS terminal gets a host-locked grid, atomic snapshot restore and no blocking calls, and the host serves snapshots.
- Files: manaflow-ai/ghostty-next (embedded.zig, ghostty.h, face.zig, Metal.zig), cmux-tui-core, schemas/terminal-sizing, Packages/Shared/CmuxTerminalSizing, cli-requests/terminal-snapshot-history.md.
- Done when: a GhosttyNextKit release ships the new API; phone and host snapshots are byte-equal on the corpus; the flood test stays in budget; L14 attaches and resizes with host snapshots.
- Depends on: a cmux-tui landing window for the host side. Coordinate with: L14 (consumer), L12 (frame fields), the cmux-tui pin owner. L13 is closed; restart it or start a new lead.

**P5. Nightly and release gates (R1, R2, P3, P10, passkeys K14)**
- Covers: daemon capability CI gate with cmux-tui built from the same commit and automatic pin bumps; a fresh tagged app for Lawrence every few hours; move repo-level signing secrets into environments; RC passkey entitlement (K14, D6).
- Goal: no build ships a feature gated on a capability its bundled daemon lacks, and Lawrence gets a new app on a schedule.
- Files: .github/workflows/cmux-next.yml, nightly.yml, release.yml, scripts/cmux-next/pin-cmux-tui.sh, CmuxNextDaemon DaemonEndpoint.swift (awaitingPin), cmux.rc.entitlements.
- Done when: a planted unserved capability fails CI; a scheduled build reaches Lawrence without manual steps (nightly-next may be enough); a non-protected branch workflow cannot read signing secrets; an installed RC has the passkey entitlement.
- Depends on: L21 first publish; Lawrence approves the secrets move and picks D6. Coordinate with: L21, L6, passkeys lead.

**P6. Visual parity tooling (P2, B11)**
- Covers: debug verbs for the unverified states (pressed, hover card open, status set, palette row hover); screenshot-diff harness with CI gating and per-port coverage; Reduce Transparency fallback for the remaining raw glass panels.
- Goal: every component state has a reference image, and ports are checked against it in CI.
- Files: CmuxNextApp/Control (DebugLayers, AppControl), HoverCardCoordinator, StatusIndicator, plans/cmux-next/spec-proposals/visuals/tools, CmuxNextOnboarding/Variants.
- Done when: tools/capture.sh captures every listed state; CI diffs states that have images; no direct `Glass.makePanel` caller is left outside the overlay path.
- Depends on: `debug.window_snapshot` (L20). Coordinate with: spec visuals agent a5cb7e0b8ec8bba1e, L20, GPUI lane, browser lead.

**P7. Agent pane gaps: git actions, file search, Markdown editor (S5, S8)**
- Covers: git file search (`file.search` / `git.files.search`), `git.commit`, `git.push`, the last-turn diff op; Markdown file editor with round-trip corpus, preserve-format serializer, edit-scoped writes and the format-changes indicator.
- Goal: finish the S8 git service in the Rust binary and ship the S5 editor.
- Files: cmux-tui-core git_ops, resource-operations-v2.json, webviews/src/agent-session/acpmux/changes, new webviews/src/markdown-editor.
- Done when: @ mentions and Cmd-P get results from the Rust handler; commit and push work from the Changes pane with failure states and risk classes; the corpus test is byte-identical or documented-normalized.
- Depends on: c055bc1cd1e (landed). Coordinate with: ACP/agent pane lead, #16174 Rust CLI owner, L3 (editor apps).

**P8. Identity foundation: launch credentials and the actor stamp (D5, D16, D20)**
- Covers: local launch credential (HMAC per terminal and ACP session) with `credential.verify` and `terminal.for_pid`; actor stamp on local agent requests; no unauthenticated localhost HTTP (mandatory token, Origin and Host checks); tailnet mode; HTTP MCP with scoped revocable tokens.
- Goal: every local agent request carries a verifiable identity, and no local listener accepts unauthenticated requests.
- Files: cmux-tui-core spawn path, acpmux server/mod.rs, cmux-browser-host, CmuxNextControl, cmux-tui/src/cli/mcp.
- Done when: children receive the credential; owners record the agent actor; a foreign Origin is rejected in tests; the tailnet allow list works.
- Depends on: nothing. This unblocks computer use (P9), agent app installs (I13), feed delegation and the D20 relay rules. Coordinate with: ownership lead, browser lead, app platform lead, L9.

**P9. Computer use in cmux-next (D19, D15, D20)**
- Covers: Computer Use helper bundled, signed and notarized in cmux-next nightly and release; Linux displays (`cmux-cua serve`, per-workspace Xvfb or nested compositor); `cua.*` relay with D20 rules; unified agent activity timeline; phase 1 computer use roadmap row.
- Goal: computer use is in the first dogfood with the Agent activity pane, as Lawrence decided.
- Files: scripts/build-cmux-cua.sh, scripts/ci/notarize-computer-use-helper.sh, CmuxNextAgentActivity, cmux-cua Linux backend, browser host and acpmux event logs.
- Done when: a nightly contains a notarized helper the onboarding step finds; a hosted Linux e2e drives an app in a per-workspace display; one agent's browser, CUA and ACP events show in one pane timeline.
- Depends on: P8; cmux-cua PR 28 merged. Coordinate with: computer use lead (liveness unverified), L21, L6, browser lead.

**P10. Remote desktop and remote view (APPS, U4)**
- Covers: `cmux-rd-proto` and `cmux-rd-core`; Linux host; macOS `remote_view` pane; access policy and bench; app manifest and `desktop` host role; `rd.*` catalog ops; macOS host (phase 2); phases 3-4; remote Chromium tab view; remote desktop app listing; phase 3 remote view roadmap row.
- Goal: the fast remote desktop app Lawrence asked for, built from the landed plan (remote-desktop.md).
- Files: new cmux-tui/crates/cmux-rd-*, new CmuxNext remote view module, first-party-apps/remote-desktop, cmux-browser-host CDP screencast.
- Done when: phase 1 streams a VM desktop to a Mac pane within the s2 latency budget and passes the s11.1 policy tests; a headless VM tab can be watched and driven under D20.
- Depends on: L12 datagram service; Lawrence decides D-RD2. Coordinate with: L12, L1, L10, L3. Restart L17 ad807ab16e5dd462a or start a new lead.

**P11. VM image build (V1, V2)**
- Covers: three-layer image recipe with inputs.lock and CI bake; coderouter and curated programs in every VM; `cmux host` bind agent and supervisor; store updater and signed channel manifest; team role and JuiceFS in the image; `vm.image.*` ops and `cloud.machines.*` settings; make the new image the cmux-next default; idle-wakeups open items.
- Goal: build what vm-image.md planned.
- Files: images/cmux-vm (new), cmux-server-core manifest, cmux-tui (host role), web/scripts/build-devbox-freestyle.ts, CmuxNextCloud, CmuxNextSettings, CmuxNextWakeups.
- Done when: a CI bake is reproducible from the lock and passes the smoke test; clone tests pass with no 1 s poll; tampered and downgraded manifests are refused.
- Depends on: signing key custody decision; Lawrence approves any production default. Coordinate with: L1 a62c42237cb5703d4 (resume it for this), L10.

**P12. Automations tier 1 (A11, A12, A13, A16, A17, A20, C1)**
- Covers: env.cmux binding from the catalog; one code.storage repo per team with automation.deploy and code_ref; Dynamic Workers and Dynamic Workflows; observability by default; telemetry store (R8); cmux-automations skill and CLI verbs; tier 2 automations-host role and soak results; Rust Workflows engine (R3); app job queue (R9); Chief-written apps in code.storage.
- Goal: user automation code runs in the decided cloud tier, deployed from code.storage with one prompt.
- Files: backend/packages/protocol, backend/apps/api (automation-workflow.ts, wrangler loader bindings), skills/, Rust CLI.
- Done when: a run loads tenant code at its pinned commit through the loader; the skill runs init, test, deploy and run; each run has a trace and a timeline.
- Depends on: Lawrence decides R3, R8, R9. Coordinate with: backend lead (DO tag registry), L10, L1.

**P13. Automations runs and UX (D13, D21, A19)**
- Covers: run.get/cancel/retry/approve/logs; message, presence, machine and store triggers; op step type; agent_prompt body; TargetPolicy host with daemon exit receipts; per-run budgets; projection read path; import local rules; creation form; run history UI.
- Goal: automations are usable end to end from a chat or form, with visible runs.
- Files: backend/apps/api (scheduler-do.ts, automation-workflow.ts, automation-ops.ts), a first-party app or pane, backend/apps/dashboard.
- Done when: create and edit work from the form and the palette; every run is a visible row and failures notify; remote steps wait on exit receipts.
- Depends on: HostDO (L12), MuxDO (P2), UsageMeterDO (P14). Coordinate with: backend lead, L3, L9, Home lead.

**P14. Automations billing (A18, A21)**
- Covers: UsageMeterDO ledger; quotas and Stripe meter events; daily reconciliation; per-team abuse limits.
- Goal: build the billing design in automations-billing.md.
- Files: new DO and migration, tail handler, scheduler-do.ts.
- Done when: the ledger is idempotent, usage reaches Stripe hourly, drift alerts fire, and limits refuse abuse.
- Depends on: P12; Lawrence sets quota and price levels. Coordinate with: backend lead. L5 ab6e246b46abc11a0 wrote the plan.

**P15. Team VM foundation (TV, D27-D32, S4)**
- Covers: team VM created with each team; TeamVmDO; Linux user and group reconciler; permission hierarchy to POSIX ACLs; SSH CA and team_vm.ssh_cert; Fly.io SSH gate; zero-loss tier spike and mount; mailbox migration; team memory repos; team VM audit; Tasks hosting and zero-loss durability; IdP group to Linux group sync; phase 3b roadmap row.
- Goal: every team gets a working team VM that members and agents reach with short-lived certificates.
- Files: backend/apps/api (TeamVmDO, team-do.ts), cmux-tui team-host role, image sshd config, cmux-tasks owner.rs.
- Done when: a new team's VM boots with members and agents able to SSH in; revocation cuts sessions; a paused VM serves a Tasks write within the wake budget; a crash loses no acknowledged op.
- Depends on: P11; Lawrence decides D33-D36. Coordinate with: Tasks lead, backend lead, L1, L10, L12, enterprise lead.

**P16. Google integrations and CASA (D14, S1, S2, S3)**
- Covers: Google Calendar connection; Gmail connection (send, readonly, modify); CASA steps 0-8; Gmail Pub/Sub new-email triggers; watch and channel renewals.
- Goal: the launch set is complete; email arrives as ids only.
- Files: backend integrations providers, gateway, SchedulerDO, ingress.
- Done when: workerd tests pass; an e2e test fires an automation on new mail and stores no content; CASA is filed with a named signer.
- Depends on: Lawrence names the integrations lead and the CASA signer. Coordinate with: backend lead, L3.

**P17. Enterprise policy enforcement (E2, E5, E8, U0)**
- Covers: DisabledFeatures enforcement; device-side UpdateChannel, MinimumVersion, RestrictToManagedTeam, AllowedSignInMethods; server-side key enforcement; `agents.allowedClasses` at grant mint; publish the MDM schema each release; F3 policy forward.
- Goal: every parsed policy key has an enforcement point.
- Files: CmuxNextSettings managed policy consumers, ActionCatalog, CmuxNextUpdater, backend auth.ts and user-do.ts, docs/mdm, release workflow, domains/connections.ts.
- Done when: each key is refused at its owner with tests; each release URL serves the schema.
- Depends on: the app's new-backend client. Coordinate with: enterprise lead (natural owner), backend lead, L21.

### Tier 2: blocks other lanes

**P18. Cloud-homed documents (D2)**
- Covers: DocDO with the WASM store reducer; document homes in TeamDO, `doc.transfer_home`, `owner_for`.
- Goal: team-shared and cloud-homed workspaces get a cloud owner that runs the same reducer.
- Files: backend/apps/api (DocDO), cmux-tui/crates/cmux-layout-reducer (WASM build), cloud catalog doc.* ops.
- Done when: DocDO passes the shared conformance cases; transfer has a handover with never two sequencers.
- Depends on: TLA+ plan change 7a (ownership lead). Coordinate with: ownership lead, backend lead, L12 (DO tags).

**P19. App platform gaps (D44-D49, D52, D55-D58, N13)**
- Covers: integration.request through the gateway; catalog metadata and typed watch streams; synced app storage; auto-update `sameScopes`; Verified-tier review pipeline; team app policy and kill switches; import old JS sidebars; scene renderers for web, iOS and TUI; usage data owner; notes server; app servers (lease, election, durable data).
- Goal: close the platform gaps that block L3 apps from running for real.
- Files: app supervisor (branch PR 16872), backend AppDO and UserDO branches, catalog files, first-party-apps/{usage,notes}.
- Done when: inbox and integrations get real data with no token in app code; usage and notes run on real servers; a new app stays hidden until staff set a tier.
- Depends on: supervisor and store backend landing. Coordinate with: app platform lead (natural owner), L3, backend lead, enterprise lead.

**P20. Cloud machines (D11, D21)**
- Covers: machine records to cmux-next; vm.attach, open_port, ssh/scp, ephemeral runs; idle policy and vm.ensure_awake; Runs group and asleep machines in the sidebar; per-run tokens and edge credentials; remaining cloud parity; CodeRouter handoff lease and VM token scope (finding 4); phase 3 machine directory row.
- Goal: cmux-next owns machine lifecycle with correct idle behavior and scoped tokens.
- Files: backend/catalog/cloud-relay-operations.json, CmuxNextCloud, web/services/vms/drivers/freestyle.ts (old backend), backend migrations.
- Done when: automation and pool VMs pause after 5 min; each relay verb has fake-driver tests; run tokens are the only credential in Workflow steps.
- Depends on: P13 for run tokens. Coordinate with: Leo (cloud parity), L1, L12, L3 (CodeRouter app), L20 (Settings).

**P21. Agent egress and network policy history (D39)**
- Covers: egress rules and compiler; team VM egress proxy; local Mac cooperative egress; team audit stream and egress.log.query; customer-owned tailnet; network policy history view; Freestyle ask list.
- Goal: agent network traffic follows the decided hybrid model with one audit stream.
- Files: backend/packages/network-policy (unlanded branch), team-host role, cmux-tui session host.
- Done when: rules compile to gateway, proxy and firewall; a flow log appears in the team audit stream.
- Depends on: the network-policy branch landing; P15 for the proxy. Coordinate with: L12, backend lead, enterprise lead.

**P22. Daemon and client platform gaps (D26, U6, s12)**
- Covers: login environment capture remainder; U6 presence list and "disconnected by X"; cmux.wire/1 conformance suite; plan change 6 (web projection rule); idle-wakeups open items if P11 does not take them.
- Goal: close the cross-cutting owner gaps in the daemon and clients.
- Files: cmux-tui-core spawn path, acpmux login_env.rs, CmuxNextDaemon/Launch/LoginEnvironment.swift, CmuxNextTerminal, backend/packages/ownership/test, plans/cmux-next/architecture.md.
- Done when: no-shell spawns wait only for the capture; kick works with the kicker shown; every client passes the shared frame suite.
- Depends on: a cmux-tui landing window. Coordinate with: #16174 Rust CLI owner, ownership lead, L12, L14.

### Tier 3: the rest

**P23. Finder remote targets and server approval**
- Covers: plain SSH targets through SFTP in cmux link; terminal.drop, agent.attach, ent_ handles; direct host-to-host bulk copy (L12-1); server approve from iPhone QR and web page.
- Done when: Finder copies on a plain SSH host; a changed host key is a hard stop; a VM-to-VM copy skips the client; a swapped QR fingerprint is refused.
- Coordinate with: L12, L3, L10, L14, app platform lead.

**P24. Integrations backend hygiene**
- Covers: KMS wrap for credentials; ingestion pipeline remainder; installation_repositories refresh; gateway approvals and rate limits; integration poster for the feed; second-wave providers.
- Done when: each has tests in workerd; a review request makes one deduped feed item.
- Coordinate with: backend lead, L9, L3.

**P25. Backend leftovers**
- Covers: entitlements through the old backend API; fold the presence and old relay Workers (D8c).
- Done when: a typed client reads entitlements; old Workers retire after clients move.
- Coordinate with: backend lead.

**P26. Browser and palette leftovers**
- Covers: VM egress policy for agent browsing (metadata IPs, private ranges); public task benchmark subset; remote localhost open items; Search Tabs favicons; documents scope and cross-app palette scopes.
- Done when: a hosted Linux test refuses metadata IPs; one benchmark run publishes per-task logs; rows draw favicons.
- Coordinate with: browser lead, L2, L11, app platform lead.

### Decision batch for Lawrence (no agent; the coordinator asks)

These rows wait for a decision, not for work: S6 (agent session list place); sidebar s9 (collapse per window or synced; sections versus the space bar); bottom band Customize item (finding 7); non-macOS font; D-RD2 (apply for restricted macOS entitlements); D33, D34, D35, D36 (team VM SSH paths, gate default, metadata store, FUSE fallback); R3, R8, R9 (workflow engine, telemetry store, app job queue); A18 quota and price levels; B10 desktop web app scope (is webviews/ that app?); the integrations lead and CASA signer (S1); passkey D1-D6 including K14; Tasks T1-T5; moving signing secrets into environments; sending the Freestyle ask list; N1 final name.
