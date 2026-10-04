# cmux Cloud as a first-party app (`cmux/cloud`): plan

Status: step 1 proposal, R71 Cloud app lead, 2026-10-04. Not approved. No product code exists for it yet.
Inputs: spec `spec/cloud-app-and-terminal-backends.md` (section 4 decisions), decisions UI-STACK,
REACT-PAGES, ONE-CATALOG, PAGE-SCHEME-CEF, APP-R1, D11, T1; plans `cloud-parity.md`, `cloud-ios.md`,
`app-platform.md` (sections 12 to 16), `pane-protocol.md`, `server.md`, `ghostty-next.md`,
`transport.md`, `react-pages.md`, OWNERSHIP-PRINCIPLES.md.

## 0. Summary

1. cmux Cloud is the app `cmux/cloud` (namespace `cmux.cloud`). It uses only public app APIs: a
   manifest v2, a catalog fragment, a native app server, a React page, and two public interfaces
   for terminals. If the app needs something that is not public, that is a platform gap. We
   record the gap and do not add a private path.
2. Cloud machines keep their own model. The machine record stays with the control plane that
   owns it today: the VM service of the main web backend (`/api/vm/*`, Freestyle driver, Postgres
   `cloud_vm_*`), per D11. The app does not move that owner in v1.
3. The work on the two backends in parallel shows that there are two terminal backend kinds,
   not one:
   - **Session host connector.** The backend gives a byte carrier to a remote cmux-tui session
     host. The tree and terminals come from that host. A Cloud VM runs cmux-tui, so normal Cloud
     attach uses this kind.
   - **Terminal byte backend.** The backend owns each terminal (open, input, resize, close,
     output bytes). The local cmux-tui daemon wraps each terminal as a session-host terminal
     (ghostty-vt state, history, snapshot, sizing, archive). The third-party sample (plain SSH
     to any host, with no cmux-tui on that host) uses this kind. Cloud also uses it for the
     rescue shell (`vm ssh` or `vm exec` through the control plane when the VM daemon is down).
   The ghostty-next lead owns both interfaces (section 5). Our two implementations are the test
   of those interfaces.
4. Live-VM work is stopped. No non-production Freestyle key exists (`~/.secrets/freestyle-nonprod.env`
   does not exist on 2026-10-04). The dev backend can only use the production key. All slices
   test against a fake control plane and recorded fixtures. Live-VM verification is UNVERIFIED
   until Lawrence creates the non-production account
   (`.cmux-scratch/nx-worker/freestyle-nonprod-account-steps.md`).

## 1. Layers and owners

| # | Layer | Owner (single writer) | Code | Reuse or rewrite |
| --- | --- | --- | --- | --- |
| L1 | Control plane: machine records, lifecycle, snapshots, resize, exec, fs, scp endpoint, attach endpoint, domains, publications, VPC/tunnel/firewall, plan limits, billing | main web VM service (D11) | `web/app/api/vm/**`, `web/services/vms/**`, `web/app/api/billing`, `web/app/api/stripe` | reuse as is; HTTP bindings already in `backend/catalog/cloud-relay-operations.json` |
| L2 | Cloud catalog fragment: every Cloud op, its scope, risk, idempotency, surfaces (palette, CLI, MCP, menus) | Cloud app lead | `first-party-apps/cloud/catalog/cloud-catalog.json` | rewrite: one fragment replaces the Swift `CloudActionCatalog` entries and is an IR input (ONE-CATALOG) |
| L3 | Cloud app server: runs the ops, keeps the machine projection on this machine, owns one link per machine, port forwards, browser proxy routes, the connector and byte backends | Cloud app lead | `first-party-apps/cloud/server/` (Rust, `server.kind: native`, `instances: machine`) | rewrite in Rust of the Swift `CmuxNextCloud` package (2.2k lines) and `CloudService`/`MachineRegistry` cloud parts |
| L4 | Terminal backend interfaces `cmux.terminal.connector/1` and `cmux.terminal.backend/1`, their daemon side (manual-IO layer in cmux-tui) | ghostty-next lead | `cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.*`, daemon code in `cmux-tui-core` | new; we give requirements (section 5) and conformance users |
| L5 | Transport: overlay endpoint, WireGuard key per install, Freestyle tunnel session, path selection | lane 12 (transport) | `cmux-tui/crates/cmux-wg`, `cmux-transport`, `cmux link` | reuse; the app asks `cmux link` for a carrier and never holds a WireGuard key |
| L6 | VM session host: workspaces, terminals, notifications ledger on the VM | the cmux-tui daemon on the VM | baked image (`images/cmux-vm`, lane 1) | reuse; bake-gated (cloud-ios.md R5) |
| L7 | Cloud page (machines, create, plans, snapshots, domains, network, billing, usage) | Cloud app lead | `webviews/src/pages/cloud/`, `cmux-page://cmux.cloud/` | rewrite in React (UI-STACK) |
| L8 | Native glue: install, delete and billing confirmation sheets, sidebar machine sections, the terminal surface | sidebar lead (sections), Mac app shell | existing Swift (`MachineRegistry` sections, `PageWebView`) | keep; Swift Cloud code is deleted after parity (section 4) |
| L9 | Credentials (Stack session for `/api/vm`) | the Mac app credential provider (Keychain) | `CloudAuth` today; `cmux.credential.provider/1` | keep in the host; the app server never reads the bearer (section 3.2) |
| L10 | iOS attach | iOS lead (lane 14) | iOS app | iOS uses the same catalog through a generated Swift client and its own overlay endpoint; we own the contract only |

State owners inside the app (OWNERSHIP-PRINCIPLES):

| State | Owner | Others |
| --- | --- | --- |
| machine record (id, name, size, state, snapshot, team) | L1 control plane | app server projection; page and sidebar mirror the app server |
| machine projection on one Mac | Cloud app server on that Mac | cache only; rebuilt from L1 |
| link (carrier) to one machine | Cloud app server on that Mac; at most one per machine per install | daemon client and sidebar use the socket it returns |
| VM workspaces and terminals | the VM daemon (L6) | Mac and iOS are clients |
| VT state of a byte-backend terminal | local daemon session host | Ghostty surface renders |
| port forwards and browser proxy routes | Cloud app server | browser host reads the route |
| WireGuard private key, Freestyle tunnel for this install | `cmux link` (L5) | Freestyle and the control plane see the public key only |
| page view state (selection, filter, draft create form) | the page (client) | — |

## 2. Manifest of `cmux/cloud` (draft)

`first-party-apps/cloud/cmux-app.v2.json`:

```json
{
  "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
  "manifestVersion": 2,
  "id": "cmux/cloud",
  "name": { "en": "Cloud", "ja": "クラウド" },
  "version": "0.1.0",
  "publisher": { "name": "cmux", "url": "https://cmux.dev" },
  "license": "GPL-3.0-or-later",
  "icon": "assets/icon.png",
  "categories": ["developer-tools"],
  "engines": { "cmux": "^2.0" },
  "catalog": "catalog/cloud-catalog.json",
  "presentation": {
    "sidebarItem": { "section": "top", "order": 30 },
    "screen": "app",
    "tab": true
  },
  "server": {
    "kind": "native",
    "binaries": { "darwin-arm64": "cmux-cloud", "darwin-x64": "cmux-cloud", "linux-x64": "cmux-cloud", "linux-arm64": "cmux-cloud" },
    "instances": "machine",
    "hosts": ["local", "cmux-server"],
    "data": [{ "name": "projection", "class": "ephemeral" }],
    "lifecycle": { "start": "onDemand" },
    "scopes": {
      "op:cmux.terminal.connector.register": "Gives the daemon a link to each Cloud machine.",
      "op:cmux.terminal.backend.register": "Serves the rescue shell.",
      "op:cmux.link.connect": "Opens the private link to a machine."
    }
  },
  "implements": {
    "cmux.pane/1": { "native": "cloud", "title": { "en": "Cloud", "ja": "クラウド" } },
    "cmux.terminal.connector/1": { "server": true, "options": { "kinds": ["cloud-vm"] } },
    "cmux.terminal.backend/1": { "server": true, "options": { "kinds": ["cloud-vm-rescue"] } },
    "cmux.fs.provider/1": { "server": true, "schemes": ["cloud-vm"] }
  },
  "handles": {
    "credential": { "reason": "Calls the cmux Cloud API as you.", "kinds": ["cmux-cloud-session"] },
    "connection": { "reason": "Connects to your Cloud machines.", "kinds": ["cloud-vm"] }
  },
  "scopes": ["cloud:read", "cloud:write", "terminal:read", "terminal:input", "net:cmux.com"],
  "files": ["assets/", "catalog/"]
}
```

Manifest fields (checked against the v2 schema, 2026-10-04): `darwin-*` binaries already exist in
the schema. The projection uses the existing class `ephemeral` (it is rebuilt from L1), so no `cache`
class is needed. `cmux.pane/1` follows the App Store pattern (`native: "cloud"`, a view that hosts
`cmux-page://cmux.cloud/`). Two items wait for approval (sent to the coordinator): (A) manifest
schema `implements.<interface>.server: true` (the app server implements the interface; exactly one of
export, web, native, server; needs a top-level `server` block); (B) interface option `options.kinds`
(array of localId, 1 to 16) on `cmux.terminal.connector/1` and `cmux.terminal.backend/1`, owned by
the ghostty-next lead. C1 does not use A or B before approval; the three `server: true` entries above
are the target shape.

Catalog fragment: family `cloud`, owner `app:cmux/cloud`, canonical names `cmux.cloud.<noun>.<verb>`,
the old relay names (`vm.list`, `vm.create`, ...) as `aliases`, HTTP binding from
`cloud-relay-operations.json`. CLI: `cmux cloud <noun> <verb>` (noun + verb, Rust CLI rule).

| Group | Ops (canonical, short form) | Risk and rule |
| --- | --- | --- |
| auth | `auth.status`, `auth.sign_in`, `auth.sign_out`, `team.list`, `team.select` | sign-in/out origin user; native browser sign-in |
| machine | `machine.list`, `.get`, `.watch`, `.create`, `.rename`, `.start` (alias `resume`), `.pause`, `.resize`, `.delete`, `.stats`, `.idle_policy.set` | create needs an idempotency key; delete origin user + native confirmation; resize shows the plan limit |
| attach | `machine.connect`, `machine.disconnect`, `terminal.new`, `rescue.open` | connect returns the carrier socket for the sidebar tree; rescue = byte backend |
| snapshot | `snapshot.list`, `.create`, `.restore`, `.fork`, `.delete` | delete origin user |
| files | `fs.list`, `.read`, `.write`, `.mkdir`, `.remove`, `.stat`, `file.push`, `file.pull` | through `cmux.fs.provider/1`; write and remove need `fs:write` |
| ports | `port.list`, `port.forward`, `port.close`, `browser.open {machine, port}` | forwards bind 127.0.0.1 only |
| domains | `domain.list`, `.verify`, `publication.list`, `.create`, `.update`, `.delete`, `.verify` | create/delete origin user |
| network | `network.list`, `tunnel.attach`, `.detach`, `.rotate_key`, `firewall.list`, `.get`, `.create`, `.delete` | firewall create/delete origin user |
| plan | `plan.get`, `usage.get`, `billing.open` | `billing.open` opens the checkout page in the browser; no card data in cmux |

## 3. How it runs

### 3.1 Process shape

The app supervisor in the local daemon starts `cmux-cloud` on demand (first page open, first
sidebar render of a Cloud machine, first CLI or MCP call). The server registers its connector
and byte backend with the daemon, serves its catalog ops, and stops after the idle timeout when
no link and no page is open. Links stay open while a Cloud tree or terminal is visible
(idle-wakeups.md: no polling; refresh on mutation, page open and app activation, as today).

Strongest objection: a separate Rust process for Cloud adds a hop and a supervisor dependency
that today's in-app Swift code does not have. Answer: the hop is on the control path only.
Terminal bytes go Ghostty surface, local daemon channel, carrier, VM daemon. The app server only
opens the carrier. Without a separate process the app is not on public APIs, and the "bring your
own cloud" path is not proven.

### 3.2 Credentials

The Stack session stays in the Mac app (Keychain). The app server never receives the bearer. It
calls L1 through the host credential relay: the server sends `{op, params}` with a `cred_…`
handle; the Mac app adds the bearer and does the HTTP call (APP-R1 provider channel, same rule as
the code-mode relay in cloud-parity.md: "Bearer credentials stay in the host process"). When
daemons enroll as their own installs (C-BATCH), and when L1 accepts install tokens, the relay moves
to the daemon. Cost: the CLI and MCP Cloud ops need the Mac app to run until then. Headless
servers cannot use Cloud ops until then.

### 3.3 Attach path (connector kind)

1. `cmux.cloud.machine.connect {machine}`: the server reads the projection; if the machine is
   paused, it calls `machine.start` first.
2. The server calls L1 `attach-endpoint {transport: "cmux-remote"}` and gets the route, a short
   token and the VPC addresses.
3. The server asks `cmux link` (L5) for a carrier to that route. Until lane 12 ships `cmux link`,
   the server spawns `cmux-tui remote connect … --wireguard-hub <sock>` as `CloudMachineLink`
   does today (reuse of the argv, moved from Swift to Rust).
4. The server registers the carrier with the daemon through `cmux.terminal.connector/1`. The
   daemon (or the Mac app, per the interface owner's choice) opens a session-host client on it.
   The sidebar shows the machine section from that client as it does today.

### 3.4 Rescue shell (byte backend kind)

`cmux.cloud.rescue.open {machine}` opens a terminal tab whose bytes come from the control plane
`vm ssh` / exec stream (Freestyle SSH behind L1; the Freestyle key stays server side). The local
daemon owns its VT state and history. This is the same byte path as the third-party SSH sample.

### 3.5 Files, ports, browser proxy

- Files: `cmux.fs.provider/1` with roots of kind `cloud-vm`. Reads and writes go to the VM daemon
  over the carrier when it is up (`workspace-rpc` file ops), else to L1 `fs` routes. `file.push` and
  `file.pull` use the L1 `scp-endpoint` with an ephemeral key made by the server.
- Ports: a loopback stream through the carrier (remote-localhost.md); the forward listens on
  127.0.0.1 and a random port.
- Browser proxy: `browser.open {machine, port}` opens a browser tab whose proxy route the browser
  host gets from the Cloud server (SOCKS through the carrier). Interface need for the browser host
  lead (section 5.3).

### 3.6 Private network, snapshots, domains, billing

Thin ops over L1 routes that exist on main. The page shows them. VPC and tunnel records stay with
the main web owner in v1. Lane 12's `TeamDO` network policy takes them over later (DECISION 3).

### 3.7 iOS attach

The iOS lead uses the same catalog through the generated Swift client with HTTP bindings and its
own overlay endpoint (T1: no iroh in cmux-next). We give the contract: `machine.list/get/start`,
`attach-endpoint` for an iOS install, and the connector semantics. The iOS app does not run the
Cloud app server.

#### 3.7.1 iOS contract (detail)

Owner of this contract: the Cloud app lead. Owner of the iOS client: the iOS lead (lane 14). Status:
proposal, 2026-10-04 (R71 C6).

1. Catalog ops. iOS calls the ops of `catalog/cloud-catalog.json` through the generated Swift
   client. Each op is an HTTP call to the Cloud API (L1) with the iOS install's own Stack
   session; the binding is the route in the op's `docs` (the same route the Cloud app server
   calls). Two exceptions: the `machine` filter of `publication.list` runs in the client, and
   mutations send `Idempotency-Key = sha256(op, canonical args, key)` like the Mac server, so the
   Cloud API dedup matches on both. iOS does not run the Cloud app server and does not keep a
   machine projection; it reads on screen open and after its own change.

   | Group | Ops for iOS v1 | Route |
   | --- | --- | --- |
   | auth | `auth.status` | the iOS session (no route) |
   | machine | `machine.list`, `.get`, `.start`, `.pause`, `.stats` | `GET /api/vm`, `GET /api/vm/:id`, `POST /api/vm/:id/{resume,pause}`, `GET /api/vm/:id/stats` |
   | attach | the attach endpoint (item 2) | `POST /api/vm/:id/attach-endpoint` |
   | network | `network.list` | `GET /api/vm/network` |
   | plan | `plan.get`, `usage.get` | `GET /api/vm` (`limits`) |

   Not for iOS v1: create, resize, snapshots, domains, publications, firewall, the tunnel ops and
   every delete. iOS calls L1 directly, so the server origin check (origin `user` for firewall,
   publication, tunnel attach and rotate_key) does not run on the phone. These ops stay out of the
   iOS build until L1 or `TeamDO` checks them itself.

2. Attach endpoint for an iOS install. `POST /api/vm/:id/attach-endpoint` with
   `{transport: "cmux-remote", deviceFingerprint: <iOS install id>}`. The answer gives the route
   (the VM's VPC address and port), a short token and `networkAddresses`. The phone opens the
   carrier, sends `hello {token}`, and speaks the session host protocol (the same protocol as the
   `cmux.terminal.connector/1` host mode, section 5). The phone keeps at most one carrier per
   machine. On carrier `down` the phone shows the disconnected state and queues no input.
   A paused machine is started with `machine.start` before the attach call.

3. Overlay transport (T1: no iroh in cmux-next). The iOS app runs its own WireGuard endpoint in the
   app process (transport.md decision 8; no Network Extension, no VPN slot). The app makes its
   WireGuard key on the device and keeps it in the Keychain (`ThisDeviceOnly`). Only the public key
   leaves the phone. v1 enrolls one tunnel for the install with `POST /api/vm/tunnel`
   (`clientPublicKey`, `deviceFingerprint`, `deviceId`, `tunnelPurpose: "terminal"`); enrollment
   also attaches the owner's network. A new public key on the same route rotates the key in place.
   A rotation also changes the server public key (the old one stops after about 2.8 s,
   transport.md section 7), so the phone takes the new `[Peer]` key from the answer. The path is the
   device's Freestyle tunnel into the VPC. Freestyle drops traffic that no rule allows: a rule
   from the phone's tunnel to the VM (UDP 4101) must exist, and its owner is lane 12's reconciler
   (transport.md section 7); v1 has no owner for it (gap). Direct IPv6 and the Durable Object
   relay come with lane 12 (`TeamDO`, `network.device.join`), which then replaces the v1 tunnel
   calls (DECISION 3). The same `POST /api/vm/tunnel` key change is open to any caller with the
   user's session; only `TeamDO` with a device-signed request closes that.

4. What the iOS lead owns: the generated Swift client in the iOS build, the in-process WireGuard
   endpoint and its Keychain key, the session host client on the carrier, the screens, and the
   iOS confirmation sheets. What we own: the catalog ops, their routes and errors
   (`cmux.cloud.*`), this contract, and fixtures the iOS tests can reuse
   (`first-party-apps/cloud/server/tests/fixtures/`).

Gaps: the generated Swift client does not exist yet (IR owner). The attach-endpoint call is not a
catalog op (it is `machine.connect` inside the app server, C2). An iOS-safe op for it
(`machine.attach_endpoint`, read-only for the caller's own install) needs a decision.

## 4. Reuse, rewrite, delete

| Thing | Decision | Why |
| --- | --- | --- |
| `/api/vm/*`, Freestyle driver, `cloud_vm_*` tables, image bake | reuse | owner per D11; no production schema change in this plan |
| `cloud-relay-operations.json` HTTP bindings | reuse as the binding of the catalog fragment | already fixture-tested (#16956, #16948, #16961) |
| `cmux-tui remote connect`, `wg hub`, `cmux-wg` | reuse | transport is lane 12's; Cloud is a client |
| VM cmux-tui daemon and its argv | reuse | bake-gated; upgrades reach running VMs only as the binary |
| Swift `CmuxNextCloud` (`CloudAPIClient`, `CloudAuth`, `CloudTunnelHub`, `CloudMachineLink`, models) | rewrite in Rust (`first-party-apps/cloud/server`), except `CloudAuth`, which becomes the credential provider | UI-STACK; one implementation |
| `CloudService`, `CloudPresenter`, Cloud parts of `MachineRegistry`, `CloudActionCatalog` | delete after parity; `MachineRegistry` keeps generic connector machines | catalog fragment generates every surface |
| `SSHService` (cmux-tui `remote ssh` to hosts that run cmux-tui) | keep; becomes a second connector user | proves the connector kind outside Cloud |
| main `CmuxCloud` (23.5k lines), `Sources/Cloud`, `Sources/Surfaces` | do not port | cloud-ios.md 3.5 |

## 5. Interface needs (for the ghostty-next lead, through the coordinator)

Chosen by the ghostty-next lead (2026-10-04, via the coordinator; text in plans/cmux-next/ghostty-next-switch.md
after the freeze): two interfaces. `cmux.terminal.connector/1` (host mode): the far end runs its own
session host; the local host relays the viewer protocol (GHOSTSNP snapshot + bytes, size state,
input, presence) and does not parse. `cmux.terminal.backend/1` (bytes mode): `open`, `resume`,
`write`, `resize`, `signal`, `close`; events `output`, `exit`, `lost`; the local host parses and owns
snapshots and the journal. Rust traits `TerminalConnector` and `TerminalBackend`, one registry with ids
`app:<app>/<id>`, `options.kinds` (1 to 16 unique localIds) on both, default deny. The lists below are
our original needs; where they differ, the chosen shape wins.

### 5.1 `cmux.terminal.connector/1`

1. `register {kinds}` from an app server; the daemon refuses kinds outside the app's manifest.
2. `connect {kind, target}` call from the daemon or client to the app: the app answers with a
   carrier (a socketpair fd passed by the supervisor, or a stream id on the provider channel). No
   filesystem socket path crosses an app boundary.
3. Carrier events: `up`, `down {retryable}`, `revoked`. On `down` the daemon shows the disconnected
   state and refuses changes (nothing queues). Reconnect is one `connect` call; the app keeps at
   most one carrier per target.
4. Identity: the machine id is the app's `target`; the sidebar section key is `<app>/<target>`.

### 5.2 `cmux.terminal.backend/1`

1. `open {kind, target, cols, rows, env?}` -> `{terminal}`; `input {terminal, bytes, seq}`;
   `resize {terminal, cols, rows}`; `close {terminal}`; stream `output {terminal, bytes, offset}`;
   event `exited {terminal, code?}`.
2. The local daemon owns the VT state (ghostty-vt), answers terminal queries, keeps history and
   snapshots, applies the sizing rule (ghostty-next.md section 6), and records the terminal like a
   local one (archive, hibernation, key dispatcher rules).
3. Byte flow is credit based (pane-protocol.md streams), so a flood cannot stall the app server.
4. Ordered input with attribution: `seq` per terminal, actor stamped by the daemon.
5. The backend may declare `answersQueries: false` (plain SSH) so the daemon replies to DA/DSR.

### 5.3 Other leads

- App platform lead: the two interface files, `kinds` on implements, `darwin-*` server binaries,
  the `cmux-cloud-session` credential kind, the host credential relay op, a `cache` data class.
- Lane 12 (transport): `cmux.link.connect {route}` -> carrier for Cloud VMs (VPC route, token), and
  the date when `cmux link` replaces `remote connect --wireguard-hub`.
- Browser host lead: a per-tab proxy route op (`browser.tab.open {url, proxy: {app, route}}`).
- Rust CLI owner: generated `cmux cloud …` verbs from the fragment (`cli.path`).
- Sidebar lead: a connector machine section keyed `<app>/<target>`.
- iOS lead: the iOS client contract in 3.7.

## 6. Fan-out (4 to 6 subagents, disjoint files)

Every package: red test commit first, then the fix; fast gates (check-no-godfiles all languages,
check-l10n, check-concurrency, check-crash-safety, check-theme-scope, check-app-platform);
safe-push.sh; Rust only on a Blacksmith Testbox; Swift only through nx-remote on
cmux-lawrence-2. All packages use the fake control plane (`first-party-apps/cloud/server/tests/fixtures/`,
recorded `/api/vm` responses). None creates a Freestyle resource.

| Pkg | Scope | Files owned | Red tests (first commit) | Needs a window | Start |
| --- | --- | --- | --- | --- | --- |
| C1 core | manifest, catalog fragment, app server skeleton, control-plane client over the credential relay, machine ops, snapshots, plan and usage reads | `first-party-apps/cloud/{cmux-app.v2.json,catalog/,README.md}`, `first-party-apps/cloud/server/{Cargo.toml,src/main.rs,src/api/,src/ops/machine*,src/ops/snapshot*,src/ops/plan*,tests/}` | manifest and fragment pass `cmux-app-manifest`; `machine.create` without a key is refused; a retried create with the same key returns the same machine; `machine.delete` from origin `mcp` is refused; a 401 maps to `cmux.cloud.auth_required`; the fixture list maps to typed records | no cmux-tui window (crate outside `cmux-tui/`, DECISION 1); regenerated `cmux-app-host/generated/*` in the same push (allowed exception) | now |
| C2 attach | connector, link supervisor (reuse of `remote connect` argv), rescue byte backend | `first-party-apps/cloud/server/src/{link/,connector/,rescue/}`, `tests/attach_*` | two `connect` calls for one machine give one carrier; a paused machine is started first; carrier `down` gives the disconnected state and no queued input; rescue input order is kept; resize and exit reach the client | the daemon side is the ghostty-next lead's window, not ours | after the interface draft (5.1, 5.2) |
| C3 sample | third-party SSH byte backend: any host, host key check, no cmux-tui on the host | `samples/apps/ssh-terminal/` (publisher `com.example`, own Cargo workspace or Go with the Go SDK) | conformance vectors of `cmux.terminal.backend/1` pass; an unknown host key is refused before any byte; a closed SSH channel gives `exited` | none | now (against the draft interface and a local fake), then rebase on the final interface |
| C4 page | React Cloud page: machines, create sheet, plans, snapshots, domains, network, billing, usage; strings en and ja; mock PageClient | `webviews/src/pages/cloud/**`, its strings generator output | the list renders from the mock; create sends one idempotency key on double submit; delete calls the native confirmation op, never `machine.delete` directly; no handler for Cmd or Ctrl chords; ja strings complete | none (webviews; safe-push checks bundles) | now |
| C5 files and ports | `cmux.fs.provider/1` for `cloud-vm`, push/pull, port forward, browser proxy route | `first-party-apps/cloud/server/src/{fs/,ports/,proxy/}`, `tests/fs_*`, `tests/ports_*` | fs list/read/write/stat against the fake; a forward binds 127.0.0.1 only; the proxy refuses hosts that are not the machine | none | waits for C1 and C2 |
| C6 network, domains, iOS contract, Swift removal | network, tunnel, firewall, domain, publication ops; iOS contract doc; delete Swift Cloud code after parity | `first-party-apps/cloud/server/src/ops/{network*,domain*}`, `plans/cmux-next/cloud-app.md` iOS section, later the Swift deletions in `Packages/macOS/CmuxNext/Sources/{CmuxNextCloud,CmuxNextApp/Cloud,CmuxNextActions/Catalog/CloudActionCatalog.swift}` | firewall create from origin `agent` is refused; op results are typed; after removal, `check-action-surfaces` shows no lost surface | Swift deletion touches `MachineRegistry` (sidebar lead) | waits; last |

Start order with limited capacity: C1, C4 and C3 now (three helpers, at most two at a time per
lead rules, so C1 + C4 first, C3 when one finishes). C2 starts when the ghostty-next lead publishes
the interface draft. C5 and C6 wait. The lead integrates (catalog regeneration, server
`main.rs` wiring, shared fixtures) and is the only writer of `server/src/main.rs` and
`server/src/ops/mod.rs` after C1 lands.

Windows and holds: no package pushes under `cmux-tui/` (HOLD active). The generated
`cmux-app-host/generated/*` files are the one allowed exception. GUI dogfood runs only on
cmux-lawrence-2 with a unique tag. A review subagent runs before C1, C2 and C5 land (protocol and
security).

## 7. Decisions (for the coordinator and Lawrence)

1. DECISION: where does the Cloud app server crate live? RECOMMEND `first-party-apps/cloud/server/`
   as its own Cargo workspace that depends on cmux-tui crates by path, because it stays outside the
   cmux-tui landing queue and it proves that an app outside the core tree can be a backend.
2. DECISION: credentials in v1? RECOMMEND the host credential relay (3.2), because L1 accepts only
   Stack sessions and APP-R1 keeps user credentials out of the daemon. Cost: CLI and MCP Cloud ops
   need the Mac app until install tokens work on L1.
3. DECISION: VPC and tunnel records in v1? RECOMMEND the main web owner (`privateNetwork.ts`), with
   lane 12's `TeamDO` policy later, because parity v1 must match main and two owners at once break
   the single-writer rule.
4. DECISION: live-VM tests? RECOMMEND that Lawrence creates the non-production Freestyle account
   (steps file above), because the only key today is the production key and the brief forbids it in
   dev and staging. Until then every Cloud slice is fixture-only and live attach is UNVERIFIED.
5. DECISION: machine change feed? RECOMMEND that L1 (or `UserDO` later) publishes machine events,
   because v1 refreshes on mutation, page open and app activation, like today. That is a known gap
   (a machine paused by idle policy shows late), not polling.

## 8. Shortcuts and risks (flagged)

- The link step reuses the `remote connect --wireguard-hub` process spawn until `cmux link` ships.
  It is the current code moved to Rust, not the target transport.
- Machine list freshness depends on refresh events (DECISION 5).
- The rescue shell depends on the L1 SSH route, which the main app uses only for scp today; C2
  must confirm the route before it relies on it.
- iOS v1 depends on lane 14 and lane 12; this plan gives only the contract.
- The billing page opens checkout in the browser; plan limits come from L1 entitlements as they
  are on main. No price or plan logic moves.

## 9. Status and integration queue (lead, 2026-10-04)

Landed on feat-cmux-next: this plan (37b964a7c33); C1 core (c427a0f5207..7d0d1d313dd) and the R73 CLI path fix (c244866fee1).
Side branches: C4 page `feat-cmux-next-cloud-c4` (ab89c64ad39), relay restore fix `feat-cmux-next-cloud-relayfix`
(f3906196d68, waits for a cmux-tui window), C2 attach and C3 SSH sample in progress.

Integration before C4 lands (one slice, lead or the next free helper):
1. Page types (`webviews/src/pages/cloud/ops.ts`) follow the landed catalog: camelCase fields (`displayName`,
   `createdAt`, `imageVersion`, stats `cpuPercent`, `memoryUsedMb`...), plan (`planId`, `maxActiveVms`,
   `memoryOptionsMb`, `lockedMemoryOptionsMb`) and usage (`vmHoursUsed`, `vmHoursIncluded`, `activeVmCount`,
   `savedVmLimit`) as C1 returns them; create takes `displayName`, `memoryMb`, `kind`; "create from snapshot" calls
   `snapshot.restore`. Op names stay `cmux.cloud.*` (the server accepts them; canonical names wait for the IR).
2. Server: `cloud.machine.watch` stream (upsert/removed with the projection revision) and `revision` on machine
   mutation results, so page intents settle without a refetch. Owner: the server crate (after C2 lands, to avoid
   conflicts in `ops/mod.rs`).
3. Host: `cmux.app.action.run` with native confirmation for the destructive and money ops the page lists in its
   README, and the `cloud.machines.layout` debug setting on `<html>`. Owner: Mac app shell (request through the
   coordinator).

Open outside this lane: snapshot create dedup in the web route (needs a stored key; production schema), the
reserved CLI word `cloud` for this app (R73 CLI owner), catalog `aliases` and namespace-qualified names (IR owner).

## 10. Status (lead, 2026-10-04, later)

Landed on feat-cmux-next: C1 core, C2 attach, C3 SSH sample (+ C3b host-owned channel), C4/C4i page and
server integration, C5 files/ports/browser route, C6 network/domains/publications, C7 idempotent delete
retry + rescue mirror, C8 page shapes, relay restore route fix. Main: PR 17244 (snapshot idempotency)
merged and deployed; PR 17246 (rescue shell endpoint) is a draft until one live test on a machine we own.

Route audit (2026-10-04): the file routes (#16936) and the network/firewall/tunnel routes (#16948) exist
only on feat-cmux-next, not on main, so production answers 404 for `cloud.fs.*`, `cloud.firewall.*`,
`cloud.network.list` and `cloud.tunnel.*`. The backend lead owns their main ports.

Queue:
1. C9 (running): the serve loop wakes on link events; connector mirror LocalId 64; rescue red redo by
   mutation; delete retry counts only each kind's own not-found code (`vm_not_found` machine,
   `vm_firewall_rule_not_found` firewall, `vm_snapshot_not_found`, `vm_file_not_found`,
   `vm_publication_not_found`).
2. Next server slice: file transfers on a worker thread with completion events.
3. Next page slice: a route 404 shows "Not available yet" (localized), not "gone"; full webviews
   `bun test` before the push.
4. C10 (waits for the apps lead's choice between a host-only op such as `cloud.link.configure` and
   AppHostCapabilities; no code before that answer): remove `Attach::from_env` and every env read outside
   the allowlist `CMUX_APP_ID`, `CMUX_APP_DATA_DIR`, `TMPDIR`, `LANG` (hits: serve.rs:13, link/mod.rs:73-88,
   link/spawner.rs:81, fs/openssh.rs:125). Child processes get an env built only from configured values
   (absolute binary path, a private HOME under `CMUX_APP_DATA_DIR`, TMPDIR, LANG). OpenSSH children take
   their config and known_hosts paths explicitly (`-F <path>`, `-o UserKnownHostsFile=<path>`), never an
   implicit `~/.ssh`; a test proves the ssh child gets no implicit `~/.ssh` path. File transfers move to a
   worker thread in the same slice. Red tests first.
   Apps lead decision (2026-10-04): link details come from the host-only op `cmux.host.link.get {}` ->
   `{binary, hub_socket, state_dir, socket_dir, device_name}` (answered by the supervisor; scope
   `op:cmux.host.link.get`, server-only, first-party only) and the event `cmux.host.link.changed` (same
   shape). Wire on the server JSON-lines channel, one shape for every host-only op: request
   `{"t":"host.request","id":n,"op":...,"params":{}}`; reply `{"t":"host.result","id":n,"value":{}}` or
   `{"t":"host.error","id":n,"code":...,"message":...,"retryable":bool}`; event
   `{"t":"host.event","op":...,"data":{}}`. The credential relay (`cmux.credential.relay`) uses the same
   frames later. `connect` answers `link_unavailable` until `link.get` answers; `link.changed` makes the
   server re-read and respawn or rebind. Every ssh/scp child gets `-F <data>/ssh/config -o
   UserKnownHostsFile=<data>/ssh/known_hosts -o GlobalKnownHostsFile=/dev/null -o
   StrictHostKeyChecking=yes`; new host keys only through the user's host key sheet; anything that needs
   the user's own SSH identity goes through the host-owned SSH channel.
5. C13 (after C12 and the `cmux-tui/crates/cmux-terminal-iface` crate land): swap the mirror traits for
   the crate (sync, pull-based; one credit data plane: `data{channel, offset, bytes}`,
   `credit{channel, direction, bytes}`, `end{channel, exit|lost}`; `push(Frame)` and `take_frames()`;
   no filesystem path crosses the app boundary; the host assigns every channel id). Connector open goes
   APP SERVER -> HOST: a user gesture runs a Cloud op with origin user; the supervisor stamps
   `open_token` into the op line (the client never holds it; cli, mcp, script and remote origins get
   none); the Cloud server opens its carrier and sends `host.request cmux.terminal.connector.open {kind,
   target, open_token}`; the host consumes the token (any attempt burns it), checks the kind, assigns
   the channel and answers `{channel, window_bytes}`; frames then flow on that channel; close is a
   `host.event connector.close {channel}` or an app `end` frame. A second open for the same (app, kind,
   target) while the channel is up answers the same channel (the token is still consumed). The wire
   method `connect` is removed; `close {channel}` stays. After a daemon restart a restored Cloud tree
   shows "disconnected, click to connect" (no auto-reconnect in v1). The Cloud server runs a per-channel
   pump between the cmux-tui link's local socket and the frames (credit window, backpressure, end
   exactly once). Server-side tests: a client-supplied `open_token` on the op line is not used unless
   the supervisor stamped it; a non-user origin with no token is refused before any host request; a
   second open answers the same channel; a refused (burned) token surfaces the host's typed error; after
   a restart the machine shows the disconnected state.
