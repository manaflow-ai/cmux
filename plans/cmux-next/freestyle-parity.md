# Freestyle parity matrix for cmux Cloud

Owner: a639 (matrix and missing rows). Started 2026-10-24. Branch: `feat-cmux-next`.
Goal (Lawrence): cmux Cloud covers every Freestyle VM feature, except where exposing it makes no
sense for a multi-tenant product (section "Deliberately not exposed", one reason per row, for the
user to check).

Freestyle source: <https://www.freestyle.sh/docs/llms.txt> (read 2026-10-24: lifecycle, files, base
snapshots, ssh, client sessions, domains, verification, dns, wildcards, vpcs, firewall, tls
inbound/outbound, tunnels, pty, forward auth, pricing and limits, cli, vm cli, domains cli, and the
guides for S3 mount, user-computer egress, router-VM egress, Docker, private git).

## The cmux surfaces (columns refer to these names)

| Name | What it is | Code |
| --- | --- | --- |
| **App API** | cmux Cloud on cmux.com. Stack Auth sessions, teams, plans, credits, PlanetScale state. Routes under `/api/vm`. | `web/app/api/vm`, `web/services/vms`, `web/services/vm-publications` |
| **Tenant API** | Tenant-scoped REST on `vm.cmux.dev` (Cloudflare Worker). API keys `cmuxvm_sk_`, scopes, resource allowlists, per-tenant 404 on foreign ids. Contract `workers/cmux-vm/openapi.json`. Its Freestyle coverage ledger is `workers/cmux-vm/upstream/coverage.json` (wrapped / planned / denied per upstream operation). | `workers/cmux-vm/src` |
| **CLI main** | `cmux vm …` and `cmux cloud …` (classic app CLI). | `docs/cloud/cli` page; `CLI/` on `main` |
| **CLI tenant** | Rust `cmux-vm` operator CLI for the Tenant API. | `workers/cmux-vm/cli` |
| **App** | cmux-next app: action catalog `cloud.*`, palette, MCP, code-mode `CloudClient`. | `Packages/macOS/CmuxNextCloud`, `cmux-tui/bindings/typescript/code-mode/cloud.ts`, `backend/catalog/cloud-relay-operations.json` |
| **SDK** | `@cmux/vm` typed client (openapi-fetch over `schema.d.ts`). | `workers/cmux-vm/sdk` |
| **Chief VM** | Cloud Chief's own sandbox tool `chief-vm`. Separate matrix: `chief-vm-freestyle-parity.md`. | `backend/chief-cc`, `backend/apps/api/src/chief-brain-cc` |

Status words: **done** (code read, tests exist, route reachable), **partial** (works for a subset; the
gap is named), **missing** (no code), **unverified** (code exists, nothing proved it against the live
provider). Every status below comes from reading code on `feat-cmux-next` `ed48ac2f9fe`. Live
checks done so far: see "Verification log". No row is marked done on a guess.

Owner column: **a638** = Freestyle cloud sessions (cmux-next `vm` CLI scope, TS SDK, acpmux in the
image). **a640** = tenant isolation test (cross-account). **a641** = cmux-next docs site. **a639** =
this matrix. Rows owned by a638 are listed, not worked, here.

## Matrix

| # | Freestyle | cmux API route | cmux CLI | cmux-next app / MCP | SDK | docs | status | owner | next step |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **VM lifecycle** | | | | | | | | | |
| 1 | Create VM (size, metadata/labels, idle, ttl, ephemeral, image/snapshot) | App: `POST /api/vm`. Tenant: `POST /v1/vms` (labels, idleTimeoutSeconds, idempotency, creation receipts) | main `vm new`; tenant `create` | `cloud.machine.create` | `@cmux/vm` POST /v1/vms | cloud/machines | partial | a638 (CLI scope, SDK) | App API has no ttl/maxRun/ephemeral knobs; Tenant API has labels + idle. Add `ttlSeconds`, `maxRunSeconds`, `maxRunTotalSeconds` to both (row 1a) |
| 2 | Running → Paused (memory kept) | App `POST /api/vm/[id]/pause`, `resume`; Tenant `pause`, `resume` | `vm pause/resume`; `cmux-vm pause/resume` | `cloud.machine.pause/start` | yes (generic) | cloud/machines | done | a638 (cmux-next `vm` scope) | none |
| 3 | Stopped (fresh boot, disk kept) | Tenant `stop`/`start`; App `restart` | `cmux-vm stop/start`; main: `vm` has no `stop` verb | none (`pause` only) | yes | none | partial | a638 | add `stop` to App API + `cloud.machine.stop` |
| 4 | Snapshot / fork / restore | App `snapshots`, `snapshot`, `fork`, `restore`; Tenant `snapshots`, `fork` | `vm snapshot/fork/restore`; `cmux-vm snapshot/fork` | `cloud.snapshot.*` (no fork action) | yes | cloud/machines | partial | a638 | catalog entry `cloud.machine.fork` |
| 5 | Deleted / ttl auto-delete | App `DELETE /api/vm/[id]`; Tenant `DELETE /v1/vms/{id}`, `retire` | `vm rm`; `cmux-vm delete/retire` | `cloud.machine.delete` | yes | cloud/machines | partial | a639 | ttl: see row 1a |
| 6 | Resize (up-only, live) | App `resize`; Tenant `resize` | `vm resize`; `cmux-vm resize` | `cloud.machine.resize` | yes | cloud/machines | done | a638 | none |
| 7 | Idle timeout (pause on no traffic) and run limits | App `PUT /api/vm/[id]/idle-pause` (15/30/60/120 min or off). Tenant create field `idleTimeoutSeconds` | main (idle policy) | `cloud.machine.idle_policy.set` | yes | none | partial | a639 | App API takes 4 fixed values only; Freestyle takes any seconds and `-1`. Accept seconds; add maxRun fields (row 1a) |
| 8 | Update VM after creation (name, metadata, idle, ttl) | App: `PATCH` rename only; Tenant: no update route (coverage ledger: `update_vm` planned cx-b4h.2) | `vm rename` | `cloud.machine.rename` | no | none | partial | a639 | Tenant `PATCH /v1/vms/{id}` (name, labels, idle, ttl, maxRun) |
| **Base snapshots / images** | | | | | | | | | |
| 9 | Ready-to-boot public base images (ubuntu etc.) | Tenant `GET /v1/vm-images` (approved list); App `/api/vm/base/open`, `reset` (cmux Base) | `cmux-vm image list`; `vm base` | none | yes | none | partial | a639 | Tenant create takes operator-approved images only. List approved sizes/images on a public docs page |
| 10 | Docker preinstalled in every Ubuntu snapshot | devbox image `web/services/vms/images/devbox/Dockerfile` (Docker is mentioned; a daemon running at boot not proved) | none | none | none | none | unverified | a639 | boot a test VM, run `docker run hello-world`, record in log; add to image CI smoke |
| 11 | S3 FUSE mount | none | none | none | none | none | missing | a639 | See "Plan" W6: bake `geesefs`/`mountpoint-s3` into devbox + docs recipe; credentials only through outbound TLS injection (row 31) |
| **Files** | | | | | | | | | |
| 12 | Read / write / list / stat / mkdir / remove files | App `/api/vm/[id]/fs/{dir,read,write,mkdir,remove,stat}` (write ≤16 MiB). Tenant `files/{content,entries,stat}` (read, write, list, stat; no mkdir, remove, exists) | `vm push/pull`; `cmux-vm file stat` only | `cloud.fs.*`, `cloud.file.push/pull` | generic | none | partial | a639 | Tenant: add `mkdir`, `remove`, `exists`; CLI tenant: `file read/write/ls/rm/mkdir` |
| 13 | Streaming and chunked upload up to 16 GiB, ranged read | Tenant `files/content` PUT streams the body, GET honours `Range`. App write capped 16 MiB, no chunked upload | `vm push` (transfers) | `cloud.file.transfer.*` | generic | none | partial | a639 | App API: resumable upload (begin/chunk/commit) or route large files to Tenant API |
| 14 | Browse files of a **paused/stopped** VM without compute | Tenant `files/stat` works without start (CLI help says "running, paused, stopped or retired"); `files/content` and `entries` answer 409 "not running" on provider 409. App `fs/*` passes straight to provider, no resume | none | none | none | none | unverified | a639 | Live check on a test VM: pause, read, list. Then make `entries` and `content` read from the saved disk and never resume (W2) |
| **Access: PTY, SSH, sessions** | | | | | | | | | |
| 15 | PTY sessions, reattach after disconnect | App `/api/vm/[id]/attach-endpoint`, `sessions`; Tenant `terminal`, `terminals`, `terminals/{id}` | `vm shell/terminal *` | `cloud.shell.open`, terminal panes | none | cloud/workspaces | done | a638 | none |
| 16 | SSH with scoped identity tokens | App `scp-endpoint`; driver mints scoped SSH identities (`openSSH`, `revokeSSHIdentity`, work user only). Tenant `client-session` returns provider token + SSH host (`beta-ssh.freestyle.sh`) | `vm ssh`/`scp` (main) | none | none | none | partial | a639 | App API has no `ssh-endpoint` route in the tree; document the Tenant `client-session` as the SSH path and add `ssh` CLI verb on Tenant |
| 17 | Client sessions: identity, per-VM grant, Linux user, token | Tenant `POST /v1/vms/{id}/client-session` (one identity per VM+user, token once), `DELETE …/client-sessions/{id}`; agent keys (`/v1/agent-keys`) | none | none | generic | none | partial | a639 | W1: end-user identities |
| 18 | Client sessions: list/get/update grants, list and revoke tokens, list/get/delete identities | Tenant `GET /v1/vms/{id}/client-sessions` and `DELETE …/client-sessions/{id}`; branch `codex/vm-api-parity-identity` (cx-b4h.6) adds `GET /v1/client-sessions` (team-wide, reach-filtered), `GET …/client-sessions/{id}`, `PUT …/client-sessions/{id}/linux-user` (exactly one user), `GET/POST …/client-sessions/{id}/tokens`, `DELETE …/tokens/{tokenId}` (hashed `vct_` ids, never provider ids). Ledger: `list_identities`, `describe_identity`, `list_vm_permissions`, `describe_vm_permission`, `revoke_vm_permission`, `update_vm_allowed_linux_users`, `list_access_tokens`, `revoke_access_token` wrapped | none | none | schema regenerated | none | partial | a639 | Not deployed. Next: CLI tenant `identity`/`session` verbs and `cmux-vm ssh VM` over `createClientSession` (`ssh <ssh.user>@<ssh.host>`, token as password); per-end-user identity grouping many VMs stays out (one identity per VM+user by design) |
| 19 | Web terminal in the browser | No browser terminal page in `web/app` (only `app/vm/desktop`); Tenant `terminal` WebSocket exists | none | terminal pane (native) | none | none | missing | a641/a639 | Expose a browser terminal page (xterm.js over Tenant `terminal`) with end-user token (W1) |
| **Domains** | | | | | | | | | |
| 20 | Free `*.style.dev`-style name routed to a VM port | App `POST /api/vm/publications` (managed hostname `managedPublicationHostname`, zone from `CMUX_VM_PUBLICATION_GENERATED_DOMAIN`); `PATCH/DELETE publications/[id]`; `GET /api/vm/publications` lists | `cmux cloud domains publish/list/rm` | none | none | cloud/cli | done | a639 | live check on staging; add Tenant API route (row 24) |
| 21 | Custom domain + ownership verification | App `/api/vm/domains`, `domains/[name]/verify`, `publications/[id]/verify` | `cmux cloud domains verify/zones` | none | none | cloud/cli | done | a639 | live check |
| 22 | Domain DNS records / certificate status | App `publications/[id]/verify` returns DNS instruction (`FREESTYLE_WEB_EDGE_HOST`, certificate nameserver) | `cmux cloud domains verify` | none | none | cloud/cli | done | a639 | live check |
| 23 | Wildcard domains (every subdomain, wildcard cert) | App: wildcard cert requested for verified domains (`requestWildcardCertificateStatus`, `publicationWildcardRoutingDnsInstruction`) for the managed zone; user custom wildcard routing not exposed | none | none | none | none | partial | a639 | W3: accept `*.example.com` on publish for a verified domain; the Tenant coverage ledger has `request_wildcard`, `list_certificates` planned |
| 24 | Domains through the tenant (API-key) API | none (ledger: `list_domains`, `create_verification`, `verify_domain`, `*_tls_rule` planned cx-b4h.6) | none | none | none | none | missing | a639 | W3: `/v1/domains`, `/v1/vms/{id}/publications` |
| 25 | Forward auth (authorise public requests at the edge before wake-up) | App `api/freestyle/forward-auth` (cmux login/team/grant per publication; access modes team, grants) | `cmux cloud domains access/grant/ungrant` | none | none | cloud/cli | done | a639 | Tenant API: custom forward-auth URL per rule (ledger planned) |
| **Network** | | | | | | | | | |
| 26 | VPCs (private networks, attach VMs) | App: one private network per (user, provider) via `privateNetwork.ts`; `/api/vm/network`. No user-defined VPCs | `vm route` | none | none | cloud/networking | partial | a639 | W5: Tenant VPC CRUD; list, rename and addresses are wrapped as mesh routes (`GET /v1/meshes`, `PATCH /v1/meshes/{id}`, `GET /v1/meshes/{id}/addresses`) |
| 27 | Firewall (VM ↔ VM ↔ range ↔ internet) | App `/api/vm/firewall` GET/POST/DELETE; per-machine egress policy (exact hosts, 443 only, IP ranges). Tenant: mesh ACL compiles to firewall rules | settings; `vm route` | Settings > Cloud | none | cloud/networking | partial | a639 | Wildcard hosts and non-443 ports (docs say "not supported yet"); compiled rule list/get and evaluate are wrapped as `GET /v1/meshes/{id}/acl/rules[/{ruleId}]` and `POST /v1/meshes/{id}/acl/evaluate` |
| 28 | WireGuard tunnels to private networks | App `/api/vm/tunnel` POST/GET/DELETE, `tunnel/network/{attach,detach,rotate-key}`. Tenant mesh: devices, enrollment, rotate-key, overlay servers | `cmux cloud` tunnel via app hub | `CloudTunnelHub` | none | cloud/networking | done | a639 | tunnel list/rename wrapped (`GET /v1/tunnels`, `PATCH /v1/devices/{id}`); attach/detach of another network denied (see below) |
| 29 | Inbound TLS: web apps | = rows 20–23 | | | | | done | | |
| 30 | Inbound TLS: **non-HTTP** (database, mail, game) at a public domain | App publications: `protocol: "https"` only (`workflows.ts` fixes it). `accessMode` team/grants | none | none | none | none | missing | a639 | W4: publish TCP (postgres, imap, minecraft, raw tcp) via TLS rules with `protocol` |
| 31 | Outbound TLS (VM → API/DB/storage/proxy) | Tenant `PUT /v1/vms/{id}/https-proxies/{hostname}` (existing proxy rules only; operator-approved destinations); App egress policy exact hosts; coderouter alias rule | none | none | none | none | partial | a639 | W4: tenant-defined outbound rules to approved or user-verified destinations |
| 32 | Edge credential injection: **model providers** (OpenAI/Anthropic/OpenRouter) | coderouter model plane: per-VM JWT injected at the edge (`vm-coderouter-edge.md`, `web/services/coderouter/vmModelPlane.ts`) | automatic on devbox | automatic | none | cloud/machines | done | a639 | none |
| 33 | Edge credential injection: HF, Neon, Tigris, Exa, Firecrawl, PostHog, Git (private repo), generic header/basic/Postgres/SOCKS5 | none for tenants (App: GitHub sign-in token via Chief only) | none | none | none | none | missing | a639 | W4: `credentials` on outbound rules, write-only, per team; vault-backed (`web/app/api/vault`) |
| 34 | Egress routing via a proxy server | none | none | none | none | none | missing | a639 | W5 (needs VPC + tunnel exit route + firewall) |
| 35 | Egress routing via **the user's computer** (tunnel exit with fallback) | Tunnel hub exists (row 28) as the way a Mac joins the network; no exit-route attachment | none | none | none | none | missing | a639 | W5: attach "exit via device" to tunnel route; fallback to Freestyle egress |
| 36 | Egress routing via a **router VM** | none | none | none | none | none | missing | a639 | W5 after VPC CRUD |
| **Developer surface** | | | | | | | | | |
| 37 | CLI `freestyle` main (vm, snapshot, vpc, tunnels, firewall, tls, domain, identity, tokens, skill) | = rows above | main `cmux vm` forwards every tenant verb; tenant `cmux-vm`: `vpc`/`mesh`, `tunnel`/`tunnels`, `firewall get/set`, `session`, `https-proxy set` (table below) | catalog | | cloud/cli; `workers/cmux-vm/README.md` "Operator CLI verbs" | partial | a638 | `tls`, `domain`, `identity <subcommand>` and `update` verbs wait for their tenant routes; `tokens` stays denied (cmux `api-key`) |
| 38 | CLI `vm`: exec, ssh, pty, fs, scp, snapshot | tenant `cmux-vm exec`, `ssh`, `file`/`fs ls/read/write/stat`, `push`/`pull`/`scp`, `terminal list/close`, `snapshot` | `cmux vm` forwards all of them | `cloud.*` | | | partial | a638 | `fs mkdir/rm`, `vm update` and `snapshot update` need tenant routes; `scp -r` (directories) not yet |
| 39 | CLI `domains` | `cmux cloud domains …` | | | | cloud/cli | done | a639 | none |
| 40 | TypeScript SDK (`freestyle` npm: vms, identities, domains, tls, vpc…) | `@cmux/vm` is a thin typed HTTP client with no helpers (`vm.exec`, `fs.readFile`, `identity.tokens`, `pty.open` …) | n/a | n/a | partial | none | partial | a638 | a638 owns SDK; a639 supplies routes the SDK needs (W1–W5) |
| 41 | Pricing and limits page (per-plan concurrent VMs, saved VMs, sizes) | cmux.com `/pricing`; limits enforced in `entitlements.ts` (5 active VMs, shared vCPU/memory pool, size caps) | `vm status` | `cloud.plan.get` | none | `/pricing` mentions Cloud; no per-plan limits table | partial | a641/a639 | W7: public limits page from `entitlements.ts` constants (generated, so it cannot drift) |
| 42 | Docs: guides per use-case (Claude Code, Docker, Postgres, VS Code, Chromium, GNOME…) | cmux.com `/docs/cloud/*` (5 pages: machines, cli, networking, workspaces, troubleshooting) | | | | 5 pages | partial | a641 | W7: Tenant API reference (generated from `openapi.json`), identities, domains, files, recipes |

### Provider CLI command to cmux verb (rows 37-38)

`cmux vm X` forwards to `cmux-vm X`. "route pending" means the tenant route does not exist yet; the
verb slots into the named group when it lands. Every verb takes `--json` (provider `--output=json`).

| Provider command | cmux verb |
| --- | --- |
| `vm create/get/list/delete/start/pause/resize` | `create` (`new`), `get`, `list` (`ls`), `delete` (`rm`), `start`, `pause`, `resize`; also `stop`, `resume`, `retire`, `fork` |
| `vm update` | route pending (`update`) |
| `vm exec` | `exec VM -- CMD` |
| `vm ssh` | `ssh VM [--linux-user U] [-- CMD]` (client session, revoked on exit) |
| `vm scp` | `scp SRC DST`, `push LOCAL VM:PATH`, `pull VM:PATH LOCAL` (single files) |
| `vm fs ls/read/write/stat` | `file ls/read/write/stat` (alias `fs`) |
| `vm fs mkdir/rm` | route pending (`file mkdir/rm`) |
| `snapshot create/list/get/delete` | `snapshot create/list/get/delete` |
| `snapshot update` | route pending |
| `vpc create/list/get/delete` | `vpc create/list/get/delete` (alias `mesh`) |
| `vpc update`, `vpc ips` | route pending |
| `vpc tunnels` | `vpc tunnels MESH` (also `vpc devices`) |
| VM membership | `vpc attach/detach MESH VM` |
| `firewall create/list/get/delete` | `firewall get` (alias `list`) and `firewall set --file` (whole mesh ACL, versioned) |
| `firewall evaluate` | route pending |
| `tunnel create/list/get/rotate/delete` | `tunnel create --request`, `list MESH`, `get tun_…\|dev_…`, `rotate` (`rotate-key`), `delete`; plus `peers`, `enrollment-code` |
| `tunnel update/attach/detach` | route pending (a tenant device belongs to one mesh at enrollment) |
| `tls` (rules, forward-auth) | `https-proxy set` for outbound proxies; inbound rules route pending |
| `domain` (verify, list, certs, wildcard) | route pending (App API `cmux cloud domains` today) |
| `identity create/list/get/delete/permissions/tokens` | per-VM `session create/list/revoke`; end-user identities route pending |
| `tokens`, `account`, `auth`, `billing`, `skill` | not exposed (see below); cmux keys are `api-key` |

## Deliberately not exposed (user check list)

| Freestyle feature | Reason (one line) |
| --- | --- |
| Hardware power (`/hardware`, `get/set_hardware_power`, `list_hardware`) | Switches a real power outlet on provider-operated machines; tenants must never reach it (already denied in `coverage.json`). |
| Account-wide placeholder branding (`/domains/placeholder`) | One setting for every verified domain of every tenant; one tenant would change all pages (denied in `coverage.json`). |
| Raw provider transport (`fetch`, `get`, `post`, `authHeaders`, background requests) | Would hand out the provider key or break tenant scoping (denied in `coverage.json`). |
| Freestyle account/auth/billing/tokens CLI (`account`, `auth`, `billing`, `tokens`) | cmux tenants are Stack Auth teams, billed by cmux; cmux issues its own API keys. |
| Handing the **team** provider API key to anyone | The key stays on the server; clients get only per-VM scoped tokens. |
| Raw SSH/identity tokens to the Chief's own sandboxes outside the Worker | Chief VM security model (`chief-vm-freestyle-parity.md`). |
| Unscoped client sessions (`allowedLinuxUsers: null`) | Root on a shared image would cross users; cmux grants one Linux user per session (devbox work user). |
| Several Linux users on one client session, or provider token ids | One session = one VM + one named Linux user (`PUT …/linux-user` replaces it); a second user is a second session. Token ids are one-way `vct_` hashes so no provider id reaches a tenant. |
| Public-domain traffic with no access control for unverified domains | A tenant can only route names it proved to own or names under the managed zone. |
| Arbitrary outbound destinations from the Tenant `https-proxies` route | Destination must be approved by the deployment today (SSRF and abuse control); W4 widens it only to verified or user-owned hosts. |
| Skill installer (`freestyle skill install`) | Local-machine only; cmux ships its own skills. |
| Attaching a network to a tunnel or detaching it (`attach_vpc_to_tunnel`, `detach_vpc_from_tunnel`) | A cmux device is one tunnel in exactly one mesh, with routes, firewall rules and ACL scoped to that mesh; a second attachment would bridge two meshes outside their ACLs. Joining another mesh is a new device enrollment there (denied in `coverage.json`). |

## Verification log

2026-10-24 (a639), no authenticated provider calls yet:

- `https://vm.cmux.dev/healthz` 200; `GET /v1/vms` without credentials 401 `Unauthorized` (auth gate live).
- `https://cmux.com/api/vm` without credentials 401; `/docs/cloud`, `/docs/cloud/networking`, `/docs/cloud/cli`, `/pricing` all 200.
- Freestyle docs (23 pages) fetched and read; cmux code read at `ed48ac2f9fe`.
- Not yet done (rows marked unverified): paused-VM file read (14), Docker (10), publication create against staging (20–23).

## Plan: closing missing rows, biggest first

| W | Rows | Work | Tests first | Prod gate |
| --- | --- | --- | --- | --- |
| W1 | 17, 18, 19 | End-user client sessions on the Tenant API: list, revoke by token id, update Linux users, identity delete; browser terminal page | fake-upstream worker tests: foreign VM 404, revoke, one VM only | staging deploy, then prod |
| W2 | 14 | Paused/stopped VM file browse without start | worker test: paused VM entries/content never call start; live check on one test VM | staging |
| W3 | 23, 24 | Wildcard publish, Tenant `/v1/domains` | publication tests | staging |
| W4 | 30, 31, 33 | Non-HTTP inbound TLS; outbound rules with edge-injected credentials (write-only, vault) | rule-compiler tests; secrets never in responses or logs | staging |
| W5 | 26, 34–36 | VPC CRUD, egress via proxy / user's computer / router VM | policy-compiler tests | staging |
| W6 | 11 | S3 FUSE image + docs | image smoke | image ladder |
| W7 | 41, 42 | Public limits page and API reference | doc-drift test | docs deploy |

Isolation: every new route is tested by a640's cross-account suite (foreign ids answer 404, no
cross-tenant listing). a639 tells a640 which route names to add as each lands.
