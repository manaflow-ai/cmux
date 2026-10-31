# The cmux-next app store: the platonic ideal (design)

Status: design only, no product code. 2026-10-30. Owner: Chief subagent "App store design doc".
Branch: `feat-cmux-next`.

Asks (Lawrence, Chief log 17660 and 17669):

- "let's work on app store now, let's talk about platonic ideal for app store, how do we make stuff
  extensible. what ideas from https://github.com/get-bb/bb should we steal"
- "i think platonic ideal for multiplayer app store is https://exe.dev/ where you can deploy
  somewhere and then pin stuff in workspaces, have panes that are remote exe.dev stuff etc"

This doc does not replace the app platform. It sets the target that the existing plans converge
on, names what is missing, and gives the smallest first slice. Read these first; this doc does not
repeat them:

| Doc | What it already decides |
| --- | --- |
| [app-platform.md](../plans/cmux-next/app-platform.md) | manifest v2, catalog fragment, interfaces, documents, handles, three renderers, the Rust app supervisor, tiers, install/enable/hide, `cmux.apps.*` ops, `presentation`, toolbar items, third-party servers, elevated scopes |
| [extensibility-DESIGN.md](../plans/cmux-next/extensibility-DESIGN.md) | three extension places only (sidebar parts, panes, right panels), R1-R7 (zero cost when unused, never on the main thread, budgets, no per-feature native hooks), store trim |
| [first-party-apps.md](../plans/cmux-next/first-party-apps.md), [first-party-apps/](../first-party-apps/README.md) | 15 first-party apps on the public API, tiers (D51), the sandbox (D52), the gap list |
| [module-store-threat-model.md](../plans/cmux-next/module-store-threat-model.md) | git-distributed modules: pinned commit, digest, review, per-module profile |
| [chief-toolpacks-DESIGN.md](../plans/cmux-next/chief-toolpacks-DESIGN.md) | `pack.toml`: CLIs with sign-in, skills, MCP servers for Chiefs |
| [add-your-harness.md](add-your-harness.md) | one TOML file adds an agent harness to acpmux |
| [cloud-app.md](../plans/cmux-next/cloud-app.md) | cmux Cloud as an app on public interfaces (`cmux.terminal.connector/1`, `cmux.terminal.backend/1`, `cmux.fs.provider/1`) |
| [team-vm-plan.md](../plans/cmux-next/team-vm-plan.md), [cloud-groups-DESIGN.md](../plans/cmux-next/cloud-groups-DESIGN.md) | team VM (`TeamVmDO`, team app servers, SSH CA), cloud groups as the unit of sharing |
| [pane-protocol.md](../plans/cmux-next/pane-protocol.md) | one typed, engine-neutral, forkable pane protocol; control plane vs direct data plane |
| [vm-identity-edge-auth.md](vm-identity-edge-auth.md) | machine principal and Reflection (modeled on exe.dev) |

## 1. Summary

1. **One unit, one manifest.** Every extension of cmux is an *app*: one `cmux-app.json` that
   holds the listing, the permissions, every entry point (palette, CLI, MCP, menus, keys,
   automations), what it renders, where it runs, the tools it gives agents, and how it bills.
   Tool packs, harness profiles and config packs become sections of that manifest, not three
   more formats.
2. **Zero first-party privilege.** Home, Cloud, CodeRouter, Diffs and every other built-in use
   only the public SDK. A CI ratchet counts every place where native code names an app id; the
   count can only go down.
3. **Every built-in is forkable.** "Fork" on any listing copies the app into `local/<name>`
   under the user's namespace. A CI check forks every bundled app and runs its own tests on the
   fork. If the fork fails, the built-in used a private path.
4. **Declarative first, code as an upgrade.** The base of every app is a scene (data + semantic
   components), rendered natively by every client: Mac, iPhone, web, TUI. A web pane or a
   native pane is an optional upgrade for one client; the scene stays as the fallback.
5. **Install = deploy + pin.** Installing an app can start an *instance* somewhere (this Mac, a
   Cloud VM, the team VM, an SSH host) and *pin* it into a place (a workspace pane, a sidebar
   item, a right panel, Home). One op does all three, atomically, with one consent sheet.
6. **Panes can be remote.** A pane shows a remote instance: a web service, a scene streamed
   from a server, a terminal, a desktop, an agent. The remote kinds are the same pane kinds with
   an instance handle; the client never knows a URL or a key it should not.
7. **Shared live instances.** A team instance runs once and every member sees the same live
   state. The pin lives in a cloud group, so sharing a group shares the app with its state. This
   is the exe.dev idea: deploy once, share by link, auth at the edge.
7a. **Self-hosted is a first-class target.** Everything above also runs on a machine the
   enterprise owns (its own Linux VM or a Kubernetes cluster, joined over SSH or Tailscale),
   with the same runner, the same health check and the same pin. Nothing in the install,
   deploy, pin or share path needs cmux Cloud (section 8a).
8. **Users and agents are equal operators.** Every op an app declares is a palette entry, a CLI
   verb and an MCP tool, generated from one catalog fragment. Agents may call granted ops; only a
   user gesture in a native sheet may install, widen grants or spend money.
9. **Untrusted code runs in a VM, not on the Mac.** Unverified apps with servers deploy to a
   Cloud VM by default. The Mac runs only sandboxed scene JS and sandboxed web content.
10. **Smallest first slice** (section 15): a third-party web app from a git repo, deployed to the
    user's Cloud VM or to a self-hosted machine, pinned as a remote web pane in the current workspace, shared through a
    cloud group, with the first-party privilege ratchet in the gate.

## 1a. What bb and exe.dev actually do (read 2026-10-30)

Facts, with sources, so the steals below rest on what the projects ship, not on what we assume.

**get-bb/bb** ("The agent IDE that builds itself"):

- A plugin is an npm-style package; its manifest is the `bb` key in `package.json` (`name`,
  `description`, `branding.icon`, entry files `server`, `app`, `host`) with `engines.bb` and
  `engines.bbPluginSdk` floors (`plugins/keep-awake/package.json`). About 50 built-ins live in
  `plugins/`, the agent providers (Claude Code, Codex, Pi, ACP) included.
- `docs/provider-plugin-api.md`: "Zero first-party privilege. First-party providers use only the
  public API." `docs/VISION.md`: "Users and agents are both first-class operators"; the CLI
  "should not be treated as a sidecar"; adapt to the user's setup "not force them to fork bb".
- SDK `@get-bb/plugin-sdk` (`packages/plugin-sdk`): backend `bb.rpc.register`,
  `bb.cli.register` (one top-level `bb <name>` command), `bb.http.route` (mounted at
  `/api/v1/plugins/<id>/http/<path>`, auth `local` | `token` | `none` for signed webhooks),
  `bb.realtime.publish`, `bb.storage.kv`, `bb.agents.registerTool`,
  `bb.agents.contributeInstructions`, `bb.providers.register`, `bb.ui.requestInput`; frontend
  `definePluginApp` with composer actions and banners, side-panel tabs, sidebar footer, homepage
  sections, settings, renderers, content scripts. A crashed slot is hidden without affecting
  others. Every new public API starts `experimental_` and is listed in `docs/api_to_audit.md`.
  `createFakePluginHost` / `renderSlot` test a plugin without the host.
- Install: `bb plugin install ./path | npm:pkg@^1 | git:URL@ref`; bb "refuses the plugin if that
  tag is ever moved to another commit"; `bb plugin update` picks only versions inside the
  `engines` ranges; a failed activation rolls back to the previous snapshot.
- **No sandbox.** "Install and update run third-party code with full trust." Content scripts are
  "trusted same-origin page code, not a sandbox." The only guard is a confirmation showing the
  resolved source, and git clones with `core.hooksPath=/dev/null`.
- Marketplaces: one `marketplace.json` index that "never hosts plugin code"; `bb marketplace add
  https://… | git:… | path:…`; `bb-official` and `bb-community` are reserved names. The community
  index is the repo get-bb/marketplace: one `entries/<id>.json` per plugin, `overview/<id>.md`
  (4,000 characters, no raw HTML), up to 6 screenshots; submission by PR, CI validates the entry
  and its source, "A maintainer reviews the source and the plugin behavior"; `author.github` owns
  later edits. Ranking: installs in the last 14 days ÷ (days since publish + 2)^1.5, minimum 5
  installs. "BB installs nothing automatically."
- Fork check (`docs/forkable-plugins.md`, `scripts/forkable-plugins.json`, 38 plugins): lint rule
  `bb/forkable-plugin-imports` refuses imports of `@bb/*` workspace packages, internal SDK
  modules, relative paths out of the plugin folder; CI "Plugin Fork Check" (`pnpm
  check:plugin-forks`) copies each plugin to a temp dir, installs the packed SDK, then runs
  typecheck, tests and `bb plugin build` (`--changed-from`, `--shard=i/n`).

**exe.dev** ("Build apps or SSH into a persistent Linux VM. ssh exe.dev."):

- "The exe.dev API is SSH" (`ssh exe.dev new --json`), plus `POST https://exe.dev/exec` and an
  MCP server at `https://exe.dev/mcp`. VMs are persistent on local NVMe ("serverful, not
  serverless"), boot any Docker image (`--image`) or `exeuntu` with `--setup-script`;
  `--egress=integrations` blocks other internet access.
- Each VM gets `https://vmname.exe.xyz/` with TLS; ports 3000-9999 forwarded. **Private by
  default**: a first visitor goes to the exe.dev login; `share set-public` opens one port.
- Sharing has two levels: **Web** (proxy only) and **Root** (SSH, browser terminal, the Shelley
  agent). Grants go to an email, to `team` (follows current membership) or to a link (Web only).
  Team admins set `vm-sharing off|admins-only|all-members` and `public-sharing on|off`.
- The proxy injects `X-ExeDev-UserID` and `X-ExeDev-Email`, serves `/__exe.dev/login` and
  `/logout`; API tokens carry scoped `cmds` lists.
- Integrations "inject secrets on the network, so that those secrets cannot be extracted from
  the VM" (100+ services).
- `exe.dev/suggest?command=…` lets an agent hand an action to a human to approve;
  `exe.dev/new?repo=…` is a "Deploy on exe.dev" button.
- Pricing: Personal $15-$155/month (2-16 vCPU shared by up to 50 VMs); Work $75/month then $0.105
  per 2 vCPU/4 GiB unit-hour.
- exe.dev has **no "pin into a workspace" feature**. Pinning is Lawrence's addition; it is
  cmux's half of the idea (exe.dev gives the deploy and the share, cmux gives the place).

## 2. Principles (and where each comes from)

| # | Principle | Stolen from | Already in cmux | Missing |
| --- | --- | --- | --- | --- |
| P1 | No first-party privilege: a built-in is an app on the public API | bb provider API ("zero first-party privilege"); VS Code built-ins (mostly) | first-party-apps README, cloud-app.md 0.1, extensibility R7 | an enforced count of id special cases (section 5) |
| P2 | Built-ins are forkable, checked in CI | bb forkable plugins (lint rule + CI fork check) | none | fork check (section 5) |
| P3 | Declarative base, every client renders without app code | bb provider API ("declarative presentation"); Raycast (`List`, `Detail`, `Form`, `ActionPanel`) | scene graph, app-platform V7 | renderers for iPhone, web, TUI; fallback rule (section 6) |
| P4 | Users and agents are first-class operators; the CLI is not a sidecar | bb VISION | one catalog generates palette, CLI, MCP (V1) | agent proposal path for install (section 10) |
| P5 | Each fact lives in one place | bb provider API; cmux OWNERSHIP-PRINCIPLES | owner tables everywhere | manifest sections that today live in three formats (section 4) |
| P6 | Install = deploy + pin | exe.dev | Cloud VM create, publications, cloud groups | the instance record and the pin record (sections 8, 9) |
| P7 | Remote is a pane kind, not a feature | exe.dev; VS Code Remote (`extensionKind`) | connector/backend interfaces, remote desktop, remote tabs | `remote.web`, `remote.scene` (section 7) |
| P8 | Zero cost when unused; budgets enforced by the host | Raycast (no-view commands); bb VISION ("fast, lightweight") | extensibility R1-R6, a436 perf gate | nothing new |
| P9 | Local first, remote when it pays | bb VISION | daemon owns state; cloud is a projection | deploy targets in the manifest |
| P10 | The store is an index, never a code host; sources are pinned and a moved tag is refused | bb marketplace ("never hosts plugin code"), bb distribution | module store pins commit + digest | registry as an index repo; user-added indexes (section 4a) |
| P11 | Private by default, share at two levels, identity at the edge | exe.dev proxy and sharing | edge route tokens, Reflection | Use vs Operate share levels (section 9) |
| P12 | Secrets are injected on the network, never handed to app code | exe.dev Integrations | handles (V6), credential broker | an egress proxy for instances (section 10) |
| P13 | Agents propose, humans approve, by link | exe.dev `suggest` links | agent installs blocked (app-platform 8) | `cmux://suggest` (section 8) |
| P14 | Self-hostable end to end: an enterprise adopts the store with no dependency on cmux Cloud | Lawrence 2026-10-30 (Chief log 17766); exe.dev's "a computer per app" on hardware the customer owns | `cmux server` on Linux, `cmux remote enroll`, Tailscale links, session host on any Linux box | the `self-hosted` deploy target and a self-hosted index and edge (section 8a) |

## 3. Vocabulary

| Term | Meaning |
| --- | --- |
| app | a manifest plus implementations; the one unit of extension, listing and consent |
| implementation | how a place is filled: `scene` (QuickJS export), `web` (bundled page), `native` (first-party and Verified only), `server` (native, js or external), `remote` (an instance) |
| place | where an app shows up: sidebar section, sidebar item, pane, right panel, status item, toolbar item, palette, CLI, MCP, Home chat tool, automation trigger. Places are interfaces (`cmux.section/1`, `cmux.pane/1`, `cmux.status/1`, ...) |
| instance (`inst_…`) | a running deployment of an app's server: tenancy `machine`, `user` or `team`; target `local`, `cloud-vm`, `team-vm`, `self-hosted` (a machine or cluster the customer runs; `ssh-host` is its single-machine form) |
| pin (`pin_…`) | a placement record that puts an app (and optionally an instance) into a place; owned by the layout owner of that place (workspace store, sidebar layout, cloud group) |
| grant | a scope or handle the user gave an app; owned by `UserDO`/`TeamDO`, enforced by the supervisor and op owners |

## 4. One manifest

Today an extension of cmux can take four shapes with four formats: `cmux-app.json` (apps),
`pack.toml` (Chief tool packs), `~/.config/cmux/harnesses/*.toml` (harnesses), `cmux.pack.json`
(config packs). The ideal is one manifest with optional sections. The other formats stay as
input formats: an importer turns each into a manifest at load, so no file a user wrote breaks.

```jsonc
{
  "$schema": "https://cmux.dev/schemas/cmux-app/3.json",
  "manifestVersion": 3,
  "id": "acme/pg-admin",                       // <publisher>/<name>; namespace acme.pg_admin
  "version": "1.4.0",
  "source": {"git": "https://github.com/acme/pg-admin", "commit": "9f2c…", "digest": "sha256-…"},

  // 1. Listing: what the store shows. Every string localized.
  "listing": {
    "name": {"en": "Postgres Admin", "ja": "Postgres 管理"},
    "summary": {"en": "Browse and query your team's databases.", "ja": "…"},
    "icon": "icon.png", "screenshots": ["shots/light.png", "shots/dark.png"],
    "categories": ["databases"], "license": "MIT",
    "forkedFrom": null                          // set by Fork; the store shows the lineage
  },

  // 2. Permissions: everything the consent sheet shows. Nothing outside this block is granted.
  "permissions": {
    "scopes": {"acme.pg_admin:read": "List saved queries", "terminal:read": "Show query output"},
    "optionalScopes": {"acme.pg_admin:write": "Save queries"},
    "handles": {"credential": {"reason": "Connect to the database", "kinds": ["postgres"]}},
    "egress": ["db.acme.internal:5432"],         // the instance's network allowlist
    "dataClasses": ["team-shared"]              // what the instance stores, shown in the sheet
  },

  // 3. Entry points: one catalog fragment. Palette, CLI, MCP, menus, keys and automations are
  //    generated from it (app-platform V1). Nothing is declared twice.
  "catalog": "catalog.json",                    // ops acme.pg_admin.query, .saved.list, ...

  // 4. What it renders, per place. scene is required for every place; web/native are upgrades.
  "implements": {
    "cmux.pane/1": {"scene": "renderPane", "web": "web/index.html", "remote": "instance"},
    "cmux.section/1": {"scene": "renderSection"}
  },

  // 5. Where it runs. Absent = no server, nothing to deploy.
  "deploy": {
    "server": {"kind": "container", "image": "Dockerfile", "port": 8080, "health": "/healthz"},
    "tenancy": ["team", "user"],                 // offered choices; the first is the default
    "targets": ["team-vm", "cloud-vm", "self-hosted", "local"], // allowed targets; unverified apps never get local
    "size": "small", "state": "/data"           // persistent path, snapshotted with the VM
  },

  // 6. What it gives agents (today's pack.toml and harness TOML, as sections).
  "agentTools": {
    "skills": ["skills/pg-admin/SKILL.md"],
    "mcpServers": [{"name": "pg", "from": "instance", "path": "/mcp"}],
    "clis": [],
    "harness": null
  },

  // 7. Billing: facts only (blog.exe.dev/billable-facts); the store computes the price.
  "billing": {"model": "free"}                  // free | seat | instance | usage (section 11)
}
```

Rules:

- **Validator.** One Rust validator (`cmux-app-manifest`) for all sources; the importers for
  `pack.toml`, harness TOML and `cmux.pack.json` produce a manifest and run the same validator.
- **Derived, not declared.** The store's "Works on" row, the consent sheet, the CLI help, the MCP
  tool list and the palette entries are all derived from the manifest. No list is kept by hand
  (CLAUDE.md "no parallel hand-maintained registries").
- **Scope growth asks again.** An update that adds scopes, handles, egress hosts, a deploy target
  or a billing change shows the sheet again (app-platform 15 already does this for scopes).
- **The manifest is the listing.** The store page is a rendering of the manifest at a pinned
  commit. There is no second listing form.

## 4a. The registry is an index

Taken from bb's marketplace, with cmux's tiers on top:

- **Index repo.** The cmux registry is a git repo (`manaflow-ai/cmux-apps`, to be created) with
  one `entries/<publisher>.<name>.json` per app: source (git URL + tag + commit), tier, owner
  GitHub login, screenshots. It holds no app code. A PR adds or changes an entry; CI validates the
  entry, fetches the source at the commit and runs the manifest validator and the app's tests; a
  maintainer reviews source and behavior for Verified. `AppDO` (app-platform 7) serves the index;
  the repo is its reviewed input.
- **Pinned sources.** An install records the commit; a tag that later points elsewhere is refused
  (bb's rule), the user sees "source changed" and the old commit keeps running.
- **User-added indexes.** `cmux apps index add <https|git|path>` adds a company index;
  `cmux-official` and `cmux-community` are reserved names. Apps from a user index are
  unverified unless the index is a team index an admin added.
- **Compatibility.** `engines.cmux` ranges pick update candidates; a failed activation rolls back
  to the previous version (bb); a crashed place is replaced by its native fallback without
  touching other places (bb's slot isolation, extensibility R5).
- **API maturity.** Every new public op or interface starts `experimental` in the catalog and is
  listed until reviewed (bb's `experimental_` + `api_to_audit.md`); the store warns on listings
  that use experimental APIs.
- **Ranking.** Installs from the install record, with bb's time decay; publisher claims do not
  rank.
- **Nothing installs itself** (bb). Default apps come from the shipped deployment list only.

## 5. Zero first-party privilege and the forkable built-ins check

### Rules

1. A first-party app uses only what a third-party Verified app could get: the public manifest,
   the generated `cmux` global, the public interfaces and host capabilities. Bare op families
   (`git`, `fs`, `cmux`) are the one namespace privilege; they are names, not powers.
2. Native code never branches on an app id. Today it does, in about ten places
   (extensibility-DESIGN 7: `TopPageRoute.swift`, `AppsService.swift`, `KeyRouter+Context.swift`,
   `AgentMemorySearchHandler.swift`, `cmux-tui-core/src/apps/catalog.rs`, ...). Each is debt.
3. `native` implementations (Home, App Store, Remote Desktop) are allowed only behind a public
   interface that a third-party app could also implement, and each ships a scene fallback.
4. If a built-in needs something the SDK lacks, the SDK grows (versioned), and the built-in is
   the first user. This is R7 of extensibility-DESIGN, stated as a test.

### Checks (in the gate)

| Check | What it does | Where |
| --- | --- | --- |
| `app_id_special_cases` ratchet row | counts string literals of first-party app ids (`"cmux/home"`, `"cmux.cloud"`, ...) in Swift and Rust outside `first-party-apps/` and the manifest loader; the count can only go down; a rise needs a dated exception | a new rule module for `scripts/cmux-next/arch-ratchet.py` (the existing ratchet; pre-push, never CI per its `_doc`) |
| fork check (bb's "Plugin Fork Check", adapted) | for every app with a `BUNDLED` marker: copy it to a temp dir with only the packed public SDK (generated `cmux-app.d.ts`, runtime, view builders) beside it, rewrite its id to `local/fork-<name>` and its ops to `local.fork_<name>.*`, run `cmux apps validate`, run the app's own `bun test`, and mount each declared place in a headless supervisor with the mock host; the fork must give the same scene output as the original | `first-party-apps/build.ts --fork-check`, run by `check-app-platform.sh` and the `apps` CI job (Blacksmith runner) |
| import lint (bb's `bb/forkable-plugin-imports`) | an app's sources may import only the public SDK and paths inside its own folder; no `../../cmux-tui/...`, no workspace packages | `first-party-apps/build.ts --check` |
| privilege diff | the fork check also records every `operation.unsupported` and `scope.missing` the fork hits and the original does not; any entry fails the check and names the private path | same |

The fork check is a behavior check (it runs the app), not a source-text check, so it follows the
test quality policy. The ratchet row is a lint and lives with the other lints, not in tests.

### Fork for users

Every listing has **Fork**: the store copies the app's source at the installed commit into
`~/.config/cmux/apps/local/<name>/`, sets `listing.forkedFrom`, starts it sandboxed with the
original's grants offered (not granted), and opens the folder in a workspace with an agent chat
primed with the app's README. "Publish fork" pushes it to the user's GitHub and lists it as
unverified. This is bb's forkable plugin flow plus Raycast's "Fork extension".

## 6. Declarative base render, code as an upgrade

| Client | Base renderer (scene) | Upgrade |
| --- | --- | --- |
| Mac | AppKit scene renderer (extensibility decision 3.2) | `web` pane (WebKit, `cmux-app://`), `native` (first-party/Verified) |
| iPhone | UIKit scene renderer over the relay scene stream | `web` pane (WKWebView, same bundle) |
| web (cmux.com dashboard, shared links) | React scene renderer (the webviews package) | `web` pane in an iframe on the app's origin |
| TUI (cmux-tui) | ratatui scene renderer: List, Row, Table, Form, Meter, ActionPanel map to text widgets | none; a `web`-only place shows "Open on Mac / Open link" |

Rules:

- **Scene is required for every declared place.** The validator refuses a place with only `web`
  or only `native`. The scene may be small ("3 open queries, Open"), but it exists, so every
  client and every agent (through the scene's text form) can use the app.
- **Semantic components, not layout.** The scene vocabulary grows semantic nodes (`List`,
  `Section`, `Row`, `Detail`, `Form`, `ActionPanel`, `Table`, `Meter`, `EmptyState`), as Raycast
  does; each client maps them to its own controls. Layout primitives (`VStack`) stay for small
  cases.
- **Agents read scenes.** Every mounted scene has a text projection (`cmux apps scene <mount>
  --text`), so an agent sees what the user sees without a screenshot.
- **The store shows "Works on"** from the manifest: Mac, iPhone, web, TUI, and which places are
  upgraded on which client.

## 7. Pane kinds, local and remote

A pane is `cmux.pane/1` with one implementation. Remote kinds add an instance handle; the client
gets a capability token from the router (pane-protocol control plane) and talks to the instance
directly (data plane).

| Kind | What the pane shows | Runs where | Transport | Clients | Exists today |
| --- | --- | --- | --- | --- | --- |
| `scene` | scene from the app's QuickJS export | app host on the session host | daemon scene stream | all | yes (Mac) |
| `web` | a bundled page | WebContent process | `cmuxPage` bridge | Mac, iPhone, web | designed (extensibility 4) |
| `remote.web` | the instance's HTTP UI | the instance | cmux edge proxy (`https://<inst>.<team>.cmux.app`) with the user's identity asserted at the edge; in the pane, the browser engine with a per-app profile | Mac, iPhone, web | publications exist in the Cloud control plane; the pane kind does not |
| `remote.scene` | scene ops streamed from the instance's server | the instance | pane protocol data plane | all, TUI included | no |
| `remote.terminal` | a terminal on the instance or host | the instance's session host, or a byte backend | `cmux.terminal.connector/1`, `cmux.terminal.backend/1` | all | yes (Cloud VMs, SSH) |
| `remote.desktop` | a desktop stream | a VM or Mac | `rd.*` ops, native surface | Mac, iPhone | yes (dev only) |
| `remote.agent` | an ACP agent chat on a peer | acpmux on the instance | acpmux peer link | all | yes (cloud subagents) |

`remote.scene` is the most important new kind. A server-side app (a team task board, a deploy
dashboard, a database browser) writes scene ops; every client, the TUI and iPhone included, draws
it natively with no web view, and every member sees the same live instance. A `remote.web` pane is
the escape hatch for apps that already have a web UI.

## 8. Install = deploy + pin

One op: `cmux.apps.install {app, version?, deploy?: {tenancy, target, size}, pin?: {place,
target}}`. It runs these steps as one request with an idempotency key and rolls back on failure,
like the atomic `workspace.create` launch (workspace-create-extension.md):

1. **Resolve and review.** Fetch the source at the pinned commit, digest it, validate it
   (module-store-threat-model.md steps; the store registry for listed apps).
2. **Consent.** The native sheet shows scopes, handles, egress, deploy target and size, data
   classes and price. Only this sheet stamps origin `user` (app-platform 15).
3. **Grant.** `UserDO` (or `TeamDO` for a team install) records the install and grants.
4. **Deploy** (when `deploy` is present). The supervisor asks the target's owner for an
   instance: the Cloud control plane for `cloud-vm` (create or reuse a VM, run the container,
   create the publication), `TeamVmDO` for `team-vm` (team app server lease, team-vm-plan S7),
   the local daemon for `local`, the enrolled host's session host for `self-hosted` (section 8a).
   The instance record
   (`inst_…`, app, version, tenancy, target, state, URL handle) is owned by that target's owner;
   the supervisor holds a projection.
5. **Pin** (when `pin` is present). The layout owner of the place writes a pin record: a pane in
   the current workspace, a sidebar item, a right panel, a Home chat tool. A pin references the
   app and the instance handle, never a URL.

Surfaces (one op, every entrypoint):

| Where | How |
| --- | --- |
| App Store | **Get** opens the sheet with deploy and pin choices filled from the defaults below |
| Palette (Cmd-Shift-P) | **Install App…**, **Deploy <App>…**, **Pin <App> Here** |
| CLI | `cmux apps install acme/pg-admin --deploy team --pin pane` (`--json`, `--wait`); `--deploy self-hosted:<host>` for a customer machine |
| MCP | an agent calls `apps_propose_install`; it returns a `cmux://suggest?op=apps.install&…` link (exe.dev `suggest`) that the agent posts in chat; clicking it opens the sheet; agents never install directly (app-platform 8) |
| Web | a "Deploy on cmux" button `https://cmux.com/new?repo=…` (exe.dev `new?repo=`) opens the app and the same sheet |
| Drag | drag a listing onto a pane drop zone = install + pin there |

Defaults picked (the user can override in the sheet):

- tenancy: the first entry of `deploy.tenancy`; an install made inside a shared cloud group
  defaults to `team`;
- target: `team-vm` for team tenancy, `cloud-vm` for user tenancy; when the user or team has a
  `self-hosted` host enrolled and no cmux Cloud account (or the team setting `apps.deployTarget`
  says so), `self-hosted` instead; `local` only for first-party and Verified apps;
- pin: a pane in the current workspace when the app implements `cmux.pane/1`, else a sidebar item.

Uninstall stops instances the user owns (after a snapshot), removes pins and grants in one commit.
A team instance stops only when a team admin uninstalls it.

## 8a. Self-hosted target (enterprise)

Lawrence, 2026-10-30 (Chief log 17766): "we need self hosted cloud vm thing too tho so
enterprises can easily adopt". The `self-hosted` target is the Cloud VM path with the customer's
machine in place of ours. Rule: **no step of install, deploy, pin, share or update may need cmux
Cloud** when the target is `self-hosted`.

| Piece | cmux Cloud (`cloud-vm`) | Self-hosted (`self-hosted`) |
| --- | --- | --- |
| Machine | a VM the Cloud control plane creates | the customer's Linux VM, bare-metal box or a Kubernetes cluster, enrolled once with `cmux server` (installs the session host) and joined over SSH (`cmux remote enroll`) or Tailscale (`cmux link`) |
| Runner | session host on the VM runs the container (`deploy.server.kind: container`) | the same session host and the same runner; on Kubernetes the runner applies a Deployment + Service from the same `deploy.server` fields (image, port, health, state volume) |
| Health | `deploy.server.health` polled by the runner, one result to the supervisor | identical |
| Instance record owner | Cloud control plane (with the VM record) | the enrolled host's session host (it owns the container); the supervisor holds a projection |
| URL / edge | cmux edge `https://<inst>.<team>.cmux.app` | the customer's own ingress or the host's tailnet name; the session host's built-in proxy signs `X-Cmux-User` / `X-Cmux-Email` / `X-Cmux-Team` with the enterprise's own key, so the app's identity contract is the same |
| Install records, grants | `UserDO` / `TeamDO` | the local supervisor's install mirror, and for a team the enterprise's own control plane (the self-hosted `cmux server` team mode); the same records, a different owner |
| Registry | cmux index (`cmux-official`) | any user-added index (`cmux apps index add <git or path>`), or a direct git URL / folder; the enterprise can run an internal index with no outbound access |
| Consent sheet | the same sheet | the same sheet; it names the host (`deploy to build-01.corp`) |
| Sharing | pins in cloud groups, the edge enforces Use / Operate | pins in the enterprise team's layout; the host proxy enforces Use / Operate with the enterprise's identity provider (OIDC) |
| Billing | instance compute on Cloud credits | none from cmux: the customer pays for its own machines |
| Air-gapped | not applicable | supported: images from the customer's registry, index from a folder, no call to cmux.com |

Defaults picked: one target name, `self-hosted`, with a host selector (`self-hosted:<host>`,
host = an enrolled host id or SSH alias); Kubernetes is a runner mode of that target
(`deploy.server.runner: "k8s"` on the host's enrollment), not a fourth target. Unverified apps may
deploy to a self-hosted target only when the enterprise's admin allows it
(`apps.selfHosted.unverified on|off`, default off), because it is the customer's own machine.

## 9. Team sharing and shared live instances

- **Team install.** An admin installs for the team: `TeamDO` records it, members get it installed
  by default (V9 already: `installed: team`, member's hide overlay in `UserDO`).
- **One instance, many viewers.** A `team` instance runs once on the team VM (or a Cloud VM the
  team owns). Its state is the instance's state; members never sync copies (V10: "No app keeps a
  copy of another owner's data").
- **Sharing is a pin in a cloud group.** A pin inside a cloud group is visible to every member of
  the group; sharing the group shares the app, its instance and its layout. Guests get the pin
  with read scopes only (teammate-access-DESIGN).
- **Links.** Every pin has a durable link `cmux://pin/pin_…` (durable-links) and, for
  `remote.web`, an https link that works in any browser after sign-in, with the identity asserted
  at the edge (the exe.dev model; vm-identity-edge-auth.md for the machine side).
- **Private by default, two share levels** (exe.dev Web and Root): **Use** = the app's panes and
  `remote.web` through the edge; **Operate** = also `remote.terminal` into the instance, its logs
  and agents on it. Shares go to a person, to the team (follows current membership, through
  `TeamDO`), or to a link (Use only). Team admins set `apps.sharing off|admins|members` and
  `apps.publicLinks on|off` in team settings.
- **Identity at the edge.** The edge sends the instance `X-Cmux-User`, `X-Cmux-Email`,
  `X-Cmux-Team` and the member's role, signed, so an app needs no login code of its own
  (exe.dev's `X-ExeDev-UserID`); it refuses any request that did not come through the edge.
- **Per-member grants.** A member's grants intersect the team's grants; a member can only narrow.
- **Presence.** Members viewing the same instance appear on the pane's tab (the presence service),
  as in shared browser tabs.

## 10. Trust and sandboxing

| Layer | Rule | Owner |
| --- | --- | --- |
| Tiers | first-party, Verified, unverified; no fourth tier (app-platform 10) | store registry |
| Scope classes | standard, sensitive, restricted, elevated (app-platform 12.5, 18) | `scope-classes.json` |
| Handles | files, connections, credentials, documents are handles the user creates; secrets never enter app code (V6) | credential broker, session host |
| Where code runs | scene JS: QuickJS app host, OS sandbox, 32 MiB, 250 ms per entry. web: WebContent process, strict CSP, bounded bridge. native server: Verified only, signed, sandboxed. **Unverified server code: never on the Mac; it deploys to a VM** (Cloud or team). | supervisor, deploy targets |
| Secrets | an instance never holds a user's secret: its egress proxy adds the credential of a granted handle on the way out (exe.dev Integrations "inject secrets on the network"), so a compromised app cannot read or copy it | credential broker, Cloud egress proxy |
| Egress | the instance's network is limited to `permissions.egress` by the VM firewall (exe.dev `--egress=integrations` is the strict form); scene and web code reach the network only through `cmux.net.fetch` with declared hosts | Cloud control plane, supervisor |
| Agents | agents call granted ops with `actor = agent:<id>`; install, grant widening, deploy and money need the native sheet | daemon actor stamp |
| Supply chain | pinned commit and digest, signature for native artifacts, re-review on scope growth, lookalike checks | module store, registry |
| Budgets | Slowed, Paused, Off ladder for every app (extensibility 6); instances have size limits and an idle stop | supervisor, target owner |
| Revocation | a revoked grant fails the next call; a revoked member loses the pin and the edge refuses the link | supervisor, `TeamDO`, edge |
| Audit | install, grant, deploy, pin and every elevated call go to the team audit chain | `TeamDO` |

bb runs third-party code "with full trust" and asks only for a confirmation. cmux does not copy
that: the app platform already decided declared scopes enforced by the host (app-platform 10).
Default picked: declared capabilities from the first release; bb's model is the warning, not the
template.

The VM rule is the exe.dev lesson applied to trust: an app the user does not trust gets its own
computer, not a seat in the user's.

## 11. Billing

- The manifest carries facts, not prices: `free`, `seat` (per member per month), `instance` (per
  instance-hour, by size), `usage` (a named meter the instance reports).
- Compute for instances is charged through the existing credits ledger (pricing-DESIGN, a205) at
  Cloud prices; the store shows the estimate in the sheet.
- Records follow the billable-facts pattern already in usage-billing.md: the store records facts,
  a reconcile worker computes the number for Stripe.
- Decided (Lawrence, 2026-10-30, Chief log 17766): **free apps only**. There are no paid apps, no
  publisher accounts with payouts and no store revenue share; `billing.model` is `free` and the
  validator refuses any other value. The only charge is instance compute on cmux Cloud, at Cloud
  prices; a self-hosted instance costs nothing from cmux.

## 12. How today's cmux-next pieces map onto it

| Piece today | In the ideal | Change |
| --- | --- | --- |
| Panes (terminal, browser, agent chat, page tabs) | built-in implementations of `cmux.pane/1`; terminals are `remote.terminal` when on another host | none for terminals; browser and agent panes keep native renderers behind the interface |
| Home chat (`cmux/home`, native page) | an app with a native pane and a scene fallback; Home chat tools are a place (`cmux.chat.tool/1`) other apps fill | remove the `TopPageRoute` id switch (ratchet) |
| App Store (`cmux/app-store`) | the store is a rendering of manifests; React page over `cmux.apps.*` | already planned (app-platform 15) |
| Cloud VMs (`cmux/cloud`) | a deploy target (`cloud-vm`) and the provider of `remote.terminal`, `remote.web` | add the instance record and container run to the Cloud ops |
| Team VM (`TeamVmDO`, team app servers) | the `team-vm` deploy target; Tasks is the first team instance | S7 is the first proof |
| Cloud groups | the unit of sharing: pins in a group are shared | add pin records to the group's layout |
| Chief tool packs (`pack.toml`) | `agentTools` section; packs import as apps with no UI | importer; `chief pack` verbs become `cmux apps` verbs with aliases |
| Harness profiles (acpmux TOML) | `agentTools.harness`; the ACP Registry is a store source | importer; the Agents settings list stays |
| Config packs (`cmux.pack.json`) | an app with only `contributes` (actions, commands, UI defaults) | importer |
| Skills and MCP servers (`cmux/skills`) | `agentTools.skills`, `agentTools.mcpServers`; an instance can serve MCP | none |
| Modules (git-distributed web tabs) | an unverified app with `web` or `remote.web` only | none; the threat model holds |
| First-party apps (search, inbox, notes, diffs, ...) | apps; each passes the fork check | add the check |
| Features tab (49 settings switches) | not apps; stays in Settings | already proposed (extensibility 7) |

## 13. Comparison

| | bb | exe.dev | VS Code | Raycast | cmux ideal |
| --- | --- | --- | --- | --- | --- |
| Unit | plugin (npm package, `bb` key in `package.json`) | VM (any Docker image) | extension (`package.json` + `contributes`) | extension (`package.json` commands) | app (one manifest) |
| UI model | React slots: composer actions, banners, side-panel tabs, sidebar footer, homepage sections, renderers | the VM's own HTTP UI at `vmname.exe.xyz`, browser terminal | webviews, tree views, contribution points | React reconciler to native `List`, `Detail`, `Form`, `ActionPanel` | scene everywhere, web/native upgrades |
| Clients | desktop, web, CLI (`bb <name>`), HTTP (`/api/v1/plugins/<id>/http/`) | browser, ssh, HTTP `/exec`, MCP | desktop, web (vscode.dev, limited) | Mac (Windows beta) | Mac, iPhone, web, TUI, CLI, MCP |
| Runs where | in bb's server and app processes | a persistent VM (local NVMe) | extension host (Node), local or remote (`extensionKind`) | Node worker on the Mac | sandboxed app host; servers on a chosen target |
| Sandbox | none: "full trust", confirm prompt only | VM isolation, egress allowlist | none (full Node) | none (review only) | OS sandbox + scopes + handles; untrusted servers in VMs |
| First-party privilege | zero (stated rule) | n/a | proposed APIs for Microsoft | private APIs for built-ins | zero, ratcheted |
| Fork | import lint + CI "Plugin Fork Check" (38 plugins) | n/a | fork the repo | "Fork extension" | Fork button + CI fork check |
| Multiplayer | no | private by default; Web or Root shares to email, team or link; edge identity headers | Live Share (separate) | no | team instances, pins in cloud groups |
| Agents | `bb.agents.registerTool`, operators by vision | Shelley agent per VM; `suggest` links for human approval | Copilot APIs, MCP | AI tools from extensions | every op is an MCP tool; agent proposes, user confirms |
| Store | index repo get-bb/marketplace (entries JSON, PR + maintainer review, decay ranking) | none ("Deploy on exe.dev" button) | Marketplace (Microsoft review) | GitHub repo, PR review | registry + git sources, tiers |
| Billing | none | plans $15-$155/month; Work $75 + $0.105 per unit-hour | none for extensions | Pro subscription | facts in manifest; compute via credits |

What we take, and what we do not:

- **Take from bb:** zero first-party privilege as a stated, tested rule; forkable built-ins with an
  import lint and a CI fork check; declarative presentation that every client renders; users and
  agents as equal operators; one CLI verb and HTTP routes per app; the store as an index of pinned
  sources with PR review; `engines` ranges with rollback; crashed-slot isolation; `experimental`
  APIs with an audit list; a fake host for app tests; local first.
- **Take from exe.dev:** a computer per app is the unit of deploy and of trust; private by
  default; Web/Root share levels (our Use/Operate) to a person, the team or a link; identity
  headers at the edge; secrets injected on the network; `suggest` links for agent proposals; a
  Deploy button; persistent state on the instance; Reflection (already taken).
- **Take from VS Code:** UI-side vs workspace-side split (`extensionKind`) maps to scene on the
  client vs server on the instance; contribution points as data.
- **Take from Raycast:** semantic native components; a small, reviewed store; fork from the UI;
  extension commands as agent tools.
- **Do not take:** bb's full-trust installs; in-process plugins with full Node or system access
  (bb, VS Code, Raycast); a
  listing format separate from the code (VS Code Marketplace metadata); unlimited customization
  hooks into the core, which is what makes a host slow (the "BB story" in extensibility-DESIGN).

## 14. Phased plan

| Phase | What | Done when |
| --- | --- | --- |
| 0 | `app_id_special_cases` ratchet row; fork check over the bundled apps | gate counts the current id switches; every bundled app forks and passes its own tests (or the failing ones are listed as gaps) |
| 1 | **First slice** (section 15): `deploy` block, `remote.web` pane kind, install = deploy + pin for user tenancy on a Cloud VM, pin shared through a cloud group | the slice's tests and one live run on a non-production Cloud account |
| 2 | Manifest v3: importers for `pack.toml`, harness TOML, `cmux.pack.json`; `agentTools`; `permissions` block; derived "Works on" | every shipped pack and harness loads as an app; `chief pack list` and `cmux apps list` agree |
| 3 | `remote.scene` over the pane protocol; team tenancy on the team VM (Tasks as the first team instance) | a scene app on the team VM renders on Mac and TUI for two members with the same live state |
| 4 | Scene renderers for iPhone, web and TUI with the semantic components; text projection for agents | the fork-check apps render on all four clients in screenshot tests |
| 5 | Verified tier review and publisher identity (free apps only: no paid apps, no payouts) | a review policy and the first Verified apps |

## 15. The smallest first slice

Goal: prove install = deploy + pin with a remote pane and team sharing, on pieces that exist.

1. **Manifest:** add `deploy {server: {kind: "container", image, port, health}, tenancy: ["user"],
   targets: ["cloud-vm"]}` and `implements["cmux.pane/1"].remote = "instance"` to the v2 schema
   (validator + fixtures), with no other new fields.
2. **Deploy:** `cmux.apps.install` with `deploy` picks the target and calls its owner: for
   `cloud-vm` the Cloud control plane creates or reuses the user's VM; for `self-hosted:<host>` the
   enrolled host's session host is used directly (no cmux Cloud call). Both then run the same
   runner: build and run the container, check `health`, publish; the instance record lives with
   its owner (the VM record, or the self-hosted session host). The two targets share one code
   path behind a `DeployTarget` seam; only "get a machine" differs.
3. **Pin:** the pane kind `remote.web` opens the publication through the edge with the user's
   identity in the browser engine under a per-app profile; the edge sends signed identity
   headers and the publication is private (Use share to the owner only) by default; the pin record (`pin_…`, app,
   instance) goes into the workspace layout, so a cloud group shares it.
4. **Entry points:** App Store Get sheet, `cmux apps install <git-url> --deploy cloud --pin pane`,
   palette **Install App…**; MCP only as `apps_propose_install`, which returns a
   `cmux://suggest` link the user clicks. `--deploy cloud` and `--deploy self-hosted:<host>` take
   the same steps.
5. **Proof:** failing tests first (validator refuses `remote` without `deploy`; install rolls back
   the VM work when the pin fails; a guest sees the pin read-only); one sample app
   (`samples/apps/hello-deploy`, a 30-line HTTP server); one live run on a non-production Cloud
   account and one on a self-hosted Linux host (an enrolled fleet Linux box, no cmux Cloud);
   a test that the self-hosted install makes no cmux Cloud request; before/after screenshots in
   light and dark. The phase 0 ratchet lands first.

Out of the slice: team tenancy, `remote.scene`, iPhone/web/TUI renderers, billing beyond the
existing VM charge, Verified review.

## 16. Defaults picked (the user can override)

1. One manifest; existing pack, harness and config formats are imported, not deleted.
2. Scene is required for every place; web and native are upgrades.
3. Unverified apps with servers never run on the Mac; they deploy to a VM.
4. Agents propose installs; only the native sheet installs.
5. First slice = user tenancy on a Cloud VM with `remote.web`; team tenancy and `remote.scene`
   come next.
6. Free apps only (decided by Lawrence, 2026-10-30); instance compute is charged at Cloud prices;
   self-hosted instances cost nothing from cmux.
7. Declared, host-enforced capabilities from the first release; bb's full-trust install model is
   not copied.
8. The registry is an index repo of pinned sources (bb's marketplace shape); a moved tag is
   refused.
9. Instances are private by default; shares are Use or Operate, to a person, the team or a link
   (exe.dev's Web and Root).
10. Self-hosted is a target from the first slice (Lawrence, 2026-10-30): one `self-hosted` target
    with a host selector; Kubernetes is a runner mode of it; unverified apps on a self-hosted host
    need the enterprise admin's switch (default off); nothing in the path needs cmux Cloud.
