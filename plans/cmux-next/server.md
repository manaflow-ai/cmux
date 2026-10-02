# cmux next: cmux server and VM software

Status: draft 2, 2026-10-02 (server lead, lane 10; coordinator, lane 1 and lane 3 input applied). Spec owner: the coordinator (only the coordinator edits the spec repo; this file is the spec proposal "server"). Decided input: SV1 (soft self-hosting: "Make This Mac a Server" in the app, `cmux server up` on Linux and Windows, one install command, pairing over our WireGuard network, servers and the team VM share one design), SV2 (Postgres per server, unique port, local-only listener, per-app auth, no default passwords), SV3 (enforce power, sleep and lock where allowed; alert on battery, no internet, low disk, pending lock; one-click fixes, admin once), N10 to N13 (one feed, typed verbs, official apps with servers), D5 (install keys, tokens, device flow), D20 (agent classes), D3/D37 (WireGuard via Freestyle tunnels now, own control plane later), A14/A15/R7 (tier-2 automations host, default Postgres for apps). Related: spec/team-vm.md, spec/app-platform.md, spec/network-policy.md, spec/browser-use.md, plans/cmux-next/vm-image.md (lane 1, PR 16815 at b1342a5fbbb; section 4.5 here), plans/cmux-next/automations-runtime.md, plans/cmux-next/app-platform.md.

Binding: OWNERSHIP-PRINCIPLES.md, architecture.md (no polling, 0% idle CPU), skills/cmux-next-feature.

## 1. Goals and non-goals

Goals:
- One software model, called **VM software**, that runs the same way on three kinds of machine: a Mac that the user makes a server, a Linux or Windows box that runs `cmux server up`, and the team VM (and any cmux Cloud machine with the `team` or `server` role).
- A server hosts: terminals (session host), app servers (manifest `server` block, single writer per team), a browser (headless Chromium), automations (tier-2 host), a Postgres cluster for apps, and installed software from the signed cmux store.
- One install command per platform that just works: verified before it runs anything, idempotent, no root unless the user asks for a system install, a user service (systemd, launchd, Windows), upgrade, rollback, uninstall, version pins.
- Pairing from any signed-in device by short code or QR, with a written trust model.
- Health: hold power assertions, prevent idle sleep and idle lock where the platform and policy allow, alert into the feed, one-click fixes that need admin rights once.
- About 0 idle CPU: every probe is event-driven or a one-shot deadline.

Non-goals (phase 1 to 3):
- Public internet exposure of app servers or HTTP routes (later, its own design).
- A new no-account remote mode. Without an account, a server is local only, plus the tailnet mode of D5 (the daemon checks the peer's tailnet identity against a local allowlist, `cmux tailnet allow`), plus SSH, which we never configure.
- Changing the host's SSH, firewall or VPN configuration. The overlay is in-process userspace WireGuard.
- Native app servers from apps outside the first-party and Verified tiers.
- GPU and remote desktop streaming (spec/computer-use.md owns the `streaming` host class).

## 2. Vocabulary

| Term | Meaning |
| --- | --- |
| host software | the roles of the one `cmux` Rust binary that run on a machine: `session`, `link`, `apps`, `postgres`, `browser`, `automations`, `health`, `updater` |
| server | a host whose owner turned on the `server` role set (Mac, Linux, Windows); it is a host record of kind `server` in `TeamDO` |
| team VM | a Freestyle machine with the `team` role set (spec/team-vm.md); same host software, extra team roles (reconciler, mailbox, memory, audit) |
| install mode | `user` (no root, runs as the installing user) or `system` (root once, dedicated service user and per-app OS users) |
| store | lane 1's content-addressed package store (`store/<sha256>/`, `profiles/<generation>/`, `current`), updated by a signed channel manifest |
| pairing | the device flow that binds a server's install key to a team and an owner |
| app server | the one process per team that runs an app's `server` block and owns its catalog ops (section 7) |

## 3. Architecture

```
                  TeamDO (host directory, network policy, grants)   PairingDO (pending codes)
                         ▲                     ▲                            ▲
                         │ link (wss, outbound) │ overlay peer map           │ pair.begin / approve
 ┌───────────────────────┴─────────────────────┴────────────────────────────┴──────────┐
 │ cmux host run   (one supervisor process; frozen unit command, lane 1)               │
 │   ├─ session   cmux-tui daemon: terminals, agents, presence                          │
 │   ├─ link      HostDO socket + userspace WireGuard (cmux-wg) + local reverse proxy   │
 │   ├─ apps      service supervisor: one process (or systemd unit) per app service     │
 │   ├─ postgres  one cluster per install: unique port, Unix socket only, role per app  │
 │   ├─ browser   cmux browser host + chrome-headless-shell (pipe, sandboxed)           │
 │   ├─ automations  workerd harness (tier 2), scheduled by SchedulerDO over the link   │
 │   ├─ health    power/lock assertions, event-driven probes, alerts to the feed        │
 │   └─ updater   signed channel manifest, store, profile flip, rollback                │
 └──────────────────────────────────────────────────────────────────────────────────────┘
        ▲ Unix socket (same uid)                       ▲ macOS only
   cmux CLI, MCP, local agents                 cmux.app: menubar server panel, palette, pairing,
                                               health view (a projection of `server.status`)
```

Rules:
- All server logic is Rust (two crates: `cmux-server-core`, pure; `cmux-server`, I/O) mounted in the `cmux` binary as the `server` role set and `cmux server …` verbs. The macOS app renders a projection and registers the launchd agent and the privileged helper; it owns no server state.
- The unit's command line is frozen as `cmux host run` (lane 1, vm-image.md 4.5). Roles come from the machine's config (`server.json`), so behavior moves with the binary in the store.
- Split with lane 1 (VM image): lane 1 owns the `cmux host run` supervisor, instance bind, per-clone identity, the store and the updater; this lane owns the server roles (`apps`, `postgres`, `health`, the server parts of `link`), the installer, pairing and the `server.*` ops. The `browser` and `automations` roles belong to their leads; this lane only enables them.
- One code path for the VM and servers: `cmux host run` with role `team` on the VM and role `server` on servers enables the same `apps`, `postgres`, `browser`, `automations` roles. Differences are listed in section 11.

## 4. Install

### 4.1 Commands

```
curl -fsSL https://cmux.com/server/install.sh | sh                      # Linux, macOS (headless)
curl -fsSL https://cmux.com/server/install.sh | sh -s -- --version 1.4.2 --system
irm https://cmux.com/server/install.ps1 | iex                           # Windows (PowerShell 5.1+)
```

On a Mac with the app: palette "Make This Mac a Server" or the menubar item. No command.

### 4.2 Trust chain (nothing runs before it is verified)

1. The script is served over HTTPS from our domain, generated per release by CI, and wraps everything in `main` called on the last line, so a cut download runs nothing. It is also published with a detached signature (`install.sh.sig`) and a SHA-256 for users who download, check and then run.
2. The script embeds, per target (`x86_64-linux`, `aarch64-linux` (static musl), `aarch64-darwin`, `x86_64-darwin`, `x86_64-windows`, `aarch64-windows`), the URL, size and SHA-256 of one bootstrap archive containing the `cmux` binary, plus the two release public keys (current and next).
3. The script downloads the archive to a private temporary directory (`umask 077`), checks size and SHA-256 with the first tool found (`sha256sum`, `shasum -a 256`, `openssl dgst -sha256`) and refuses on any mismatch or missing tool. On macOS it also requires `codesign --verify --strict` and our Developer ID team identifier. On Windows the PowerShell script checks `Get-FileHash` and `Get-AuthenticodeSignature` (status `Valid`, our publisher certificate thumbprint).
4. Only then it runs the verified binary as the current user: `cmux server install [flags]`. From here the binary does the work: it fetches the signed channel manifest (lane 1 format: package list with URL, SHA-256, size, roles; sequence; expiry; minimum `cmux` version), verifies the Ed25519 signature against its baked keys, refuses an expired manifest or a sequence lower than the last applied one, and installs packages into the store with streaming hashes.
5. Root: never by default. With `--system`, the script runs `sudo <verified binary> server install --system` on the file it already verified. It never pipes downloaded content into a root shell, never runs a downloaded script as root, and never asks for root to install a user mode server.

### 4.3 Layout (one store layout everywhere; lane 1 section 4.5)

| | Linux user | Linux system and team VM | macOS (app) | macOS (headless) | Windows user | Windows system |
| --- | --- | --- | --- | --- | --- | --- |
| store, profiles, current | `~/.local/share/cmux/` | `/opt/cmux/` (root-owned) | app bundle (binary) + `~/Library/Application Support/cmux/store` | `~/Library/Application Support/cmux/` | `%LOCALAPPDATA%\cmux\` | `%ProgramFiles%\cmux\` |
| state (keys, Postgres, apps) | `~/.local/state/cmux/server/` | `/var/lib/cmux/` | `~/Library/Application Support/cmux/server/` | same | `%LOCALAPPDATA%\cmux\server\` | `%ProgramData%\cmux\server\` |
| config | `~/.config/cmux/server.json` | `/etc/cmux/server.json` | `~/.config/cmux/server.json` | same | `%APPDATA%\cmux\server.json` | `%ProgramData%\cmux\server.json` |
| service | `systemd --user` unit `cmux-server.service` + linger | system unit `cmux-server.service`, user `cmux` | `SMAppService.agent` (bundled plist) | `~/Library/LaunchAgents/com.cmux.server.plist` | Scheduled Task at logon | Windows service `cmux-server` (virtual account) |
| CLI shim | `~/.local/bin/cmux` | `/usr/local/bin/cmux` | app's bundled CLI | `~/.local/bin/cmux` | `%LOCALAPPDATA%\cmux\bin` on user `PATH` | `%ProgramFiles%\cmux\bin` |

User mode on Linux needs `loginctl enable-linger` to run without a login session. Where polkit refuses it, the installer says so and offers the one command that needs `sudo`; it never runs it silently. A headless Mac with a LaunchAgent runs only while the user is logged in; the health role reports "This Mac is not logged in after restart" (section 9.3).

### 4.4 Idempotent, upgrade, pin, rollback, uninstall

- Re-running the same command with the same version is a no-op that prints the current state (store hit, same profile, unit unchanged, service running). A different version is an upgrade.
- `cmux server upgrade [--version V | --generation G] --wait`: apply a manifest or a pinned version; a profile flip with one `rename(2)`; services restart through their handoff contracts (the session host keeps terminal hosts across restarts).
- Updates arrive with no timer: at boot, at resume, and when the control plane pushes "channel changed" over the link (lane 1). `server.autoUpdate` (default on) and `server.channel` (`stable`, `beta`) are settings; `cmux server pin V` sets `server.pinnedVersion` and stops automatic updates; team policy and MDM can lock all three.
- `cmux server rollback [--generation G]` flips back (lane 1 measured 70 ms).
- `cmux server uninstall` stops and removes the service, the shim and the store, and keeps state (keys, Postgres, app data, backups). `--purge` also deletes state after it takes a final Postgres base backup into the current directory unless `--no-backup` is given. Uninstall also unpairs (section 6.5).

### 4.5 Alignment with lane 1 (vm-image.md, PR https://github.com/manaflow-ai/cmux/pull/16815 at b1342a5fbbb)

- One store and one updater: servers use lane 1's content-addressed store (`store/<sha256>/`, `profiles/<generation>/`, `current`), the same signed channel manifest and the same updater role (`cmux host update`), so VM software is one package set with one SBOM. The store **root** depends on the install mode only because a user-mode install has no root: `--system` installs and the team VM use `/opt/cmux` exactly; user mode uses `~/.local/share/cmux` (Linux), `~/Library/Application Support/cmux` (macOS), `%LOCALAPPDATA%\cmux` (Windows). The updater takes the root as its only input. Forcing `/opt/cmux` for every server would make root mandatory, which SV1's "no root unless required" rules out.
- Generation = the manifest sequence number; CI never signs two manifests with one sequence (the prototype refuses a known generation whose manifest changed).
- Signature format: one format for both lanes, `manifest.json` schema 1 as implemented in `cmux-server-core::manifest` (`schema`, `channel`, `sequence`, `expires_at` RFC 3339 UTC, `min_cmux_version`, `packages[{name, version, url, sha256, size, roles[]}]`) plus `manifest.json.sig`, the raw 64-byte Ed25519 signature over the exact manifest bytes, checked against each baked key (no key id). The verifier refuses a wrong channel, an expired manifest, a lower sequence, and a known sequence with different bytes. The Linux prototype used an earlier field spelling (`expires` in Unix seconds, `minCmux`) with the same signature scheme through `openssl pkeyutl -verify -rawin`. A minisign file is not needed (DECISION in the lane report).
- Postgres: the image bakes PostgreSQL 17 binaries only; the `postgres` role creates the cluster, port, roles and `pg_hba` at first use after bind (section 8). On a VM the role stops the cluster before a snapshot (the bake and `vm.snapshot` call `cmux host prepare-snapshot`) and starts it after bind, because a running cluster in the snapshot slows `vms.create` to about 450 ms.
- Listeners: Postgres and app servers listen only on Unix sockets, so the late private interface does not matter to them. The overlay and any team-network listener of the `link` role bind at start and again on each interface event (netlink on Linux, `nw_path_monitor` on macOS), never to an address frozen at bake.
- Clone identity: on a VM, lane 1's bind agent (a role of `cmux`) regenerates `machine-id`, the random seed, SSH host keys and the WireGuard key per clone at bind. A server can also be cloned (a disk image, a migrated Mac, a copied VM): the `server` role records the platform machine identity (`/etc/machine-id`, the Mac's hardware UUID, the Windows MachineGuid) next to its install key; when it changes, the server discards its install and WireGuard keys, refuses to start the link, and asks for a new pairing (posted to the owner's feed from the old host record as "possible clone"). Two machines never share one install key.

## 5. Roles on a server

| Role | What | Default on a server | On the team VM |
| --- | --- | --- | --- |
| `session` | cmux-tui daemon (terminals, agents, presence) | on | on |
| `link` | HostDO link, overlay peer, routing of app catalog ops to the local app server | on after pairing | on |
| `apps` | app server supervisor and lease holder (section 7) | on | on (Tasks and team apps) |
| `postgres` | one cluster (section 8) | on at first use (first app that declares a database) | on |
| `browser` | `cmux browser host` + chrome-headless-shell | on at first use | on at first use |
| `automations` | tier-2 automations host (workerd harness, plans/cmux-next/automations-runtime.md 4.3) | off; on when the owner targets the host | on |
| `health` | section 9 | on | on (disk, memory, link only) |
| `updater` | store updates | on | on |

`cmux server roles set apps,postgres,...` and Settings > Server toggle them. A role that is off costs disk, not memory or CPU.

## 6. Pairing and trust model

### 6.1 Principals

- The server is an **install** (`inst_…`) with a keypair generated on the server (never leaves it): Secure Enclave or Keychain on macOS, a 0600 file owned by the service user on Linux, a DPAPI-protected file on Windows (TPM-bound key later). A separate WireGuard key, also generated locally.
- After pairing it is a **host** (`host_…`, kind `server`) in `TeamDO`, owned by the approving user, in one team (a personal account is a team of one).

### 6.2 Flow (device flow, RFC 8628 shape, no polling)

1. `cmux server up` (or install) on an unpaired machine calls `server.pair.begin {install_pubkey, wg_pubkey, info: {name, os, arch, version}}` with a proof-of-possession signature. The API Worker creates a `PairingDO` named by a fresh code and returns `{code, verification_uri, expires_at}`. The server holds a hibernating WebSocket to that `PairingDO` and waits; it never polls.
2. The server shows the code, a QR and four fingerprint words. Code: 8 symbols of Crockford base32 shown as `7KQ4-M2XD` (40 bits), single use, 10 minutes, case and `O/0`, `I/1/L` insensitive. Words: 4 words from a 2,048-word list derived from SHA-256 of the install public key (44 bits). QR payload: `https://cmux.com/pair?c=7KQ4M2XD#fp=<first 16 base32 symbols of SHA-256(pubkey)>`.
3. The user approves on any signed-in client: palette "Add Server…" or the menubar on a Mac, scanning the QR with the iPhone app (universal link), or the web page. The client shows the server's name, OS, version, coarse network location (country from the begin request) and the four words, and asks for the team and the display name. A QR scan checks `fp` against the key the `PairingDO` holds and refuses on mismatch, so a swapped code cannot pass.
4. Approve is `server.pair.approve {code, team, name}` with `origin: user` only (never an MCP tool, never from an agent). `TeamDO` checks the approver's right to enroll (6.3), creates the host record (`owner`, `team`, `kind: server`, tags `tag:server`), registers the install public key with class `host`, and starts the network reconcile (Freestyle tunnel in the team VPC for the WireGuard key, spec/network-policy.md). The `PairingDO` sends `{host, team, tunnel_config, first_token}` to the waiting server and deletes itself.
5. The server stores its credentials, starts the link and the overlay, and posts "Server paired" to the owner's feed.

On a Mac that is already signed in, "Make This Mac a Server" skips the code: the app calls `server.enroll_self {team, name}` with its own install key and `origin: user`. The Mac is already a host for its terminals; enrolling adds `kind: server` and `tag:server`.

### 6.3 Who may pair

| Target | Who may approve |
| --- | --- |
| personal team | its owner |
| a team | team admins; members only when team policy `servers.memberEnroll` is on (default off), then only into their own person node |
| any | never an agent (no MCP tool, no mux grant); MDM or team policy `servers.enabled = false` refuses all |

Limits: `PairingDO` creation is rate-limited per source IP and per account; approvals are rate-limited per user; a code can be approved once; the approver sees every fact we know about the server before approving.

### 6.4 What a paired server may do, and what may be done to it

- A server is a **destination**. The default network policy has no rule with `src: tag:server`, so a server cannot open overlay connections to the owner's Macs, phones or other machines. It serves its own streams through `HostDO` and its overlay address.
- As a principal, the server may: refresh its token by signed challenge; serve its session, apps and browser streams; report health; post feed items of kind `server.*` to its owner's feed (and to the team feed for team servers); read the channel manifest. It may not read team data, act as a user, mint grants, or request SSH certificates.
- Who may use a server: the owner and team admins (everything); other team members only through network policy rules and grants (default none for a member's server; team servers: members reach app servers only through their catalog ops, which the app's owner checks per op). Agents: the owner's mux has full reach (D20); ordinary agents only on the server they run on; runs per their automation grant.
- App servers are reachable only through `owner_for` routing of their catalog ops (section 7.1); the op carries the caller's authenticated principal, and the app server checks it per op. App servers never listen on a network address.

### 6.5 Keys, tokens, revocation

- Tokens: account-mode JWTs of a few minutes (D5); refresh signs a fresh `TeamDO` challenge with the install key.
- Revocation: `host.revoke` (owner, team admin), `cmux server unpair` on the server, removal of the owner from the team, or uninstall. `TeamDO` marks the host revoked, refuses refresh, drops it from peer maps, deletes its Freestyle tunnel and firewall rules, and `HostDO` closes the link at once. Outstanding tokens expire within minutes. The server shows "Unpaired" and stops remote listeners; local terminals, apps and databases keep working.
- Lost or stolen server: revoke from any client; its keys become useless for the account. Data on its disk is the owner's responsibility (FileVault, LUKS, BitLocker; the health role warns when disk encryption is off).
- Key rotation: `cmux server rotate-keys` makes new install and WireGuard keys and registers them with a signature by the old key; a compromised old key is handled by revoke and re-pair.

### 6.6 Strongest objection

"A short code lets an attacker trick a user into approving the attacker's machine into the user's team, which then sits inside the team network." Answer: the approver sees the server's facts and the four words; QR approvals bind the key fingerprint; a server is a destination with no default outbound reach; servers get `tag:server`, which no default rule grants as a source; approval is user-origin only; every enrollment posts a feed item to the owner and the team admins with "Revoke".

## 7. App servers (N13; coordinator decision 2026-10-02)

### 7.1 The manifest `server` block

Decided by the coordinator: `cmux-app.json` gets a public `server` block, and `contributes.paneKinds` gets renderer `native` (first-party and Verified apps only). First example: Tasks (`dev.cmux.tasks`, recommended rename `cmux/tasks` in 7.9, Rust `cmux-tasks serve`, plans/cmux-next/tasks.md on feat-cmux-next-tasks).

```jsonc
"server": {
  "kind": "native",                         // later: "node", "bun", "workerd" (the earlier `services` idea folds in here)
  "binary": "bin/cmux-tasks",               // in the app bundle; see gap G3 for per-target binaries
  "args": ["serve"],
  "catalog": "catalog/tasks-catalog.json",  // ops this server owns; catalog owner = app:dev.cmux.tasks
  "hosts": ["team-vm", "cmux-server", "local"],   // allowed host kinds, in preference order
  "data": "durable"
}
```

Rules this lane applies:
- Exactly one host per tenancy key (team by default; user and machine in 7.8) runs an app's server: the **app server** is the single writer of every op in its catalog. `owner_for(op)` resolves `app:<id>` to the host that holds the app's lease (7.2) and routes the op there (over the link and `HostDO`, or the local socket when the caller is on that host).
- `kind: native` runs a binary from the app bundle. This lane recommends first-party apps only (7.9 G13); Verified apps would need a sandboxed kind.
- The server speaks the app's catalog over a Unix socket that the supervisor creates and passes as `CMUX_APP_SOCKET` (JSON lines or `cmux.wire/1`, the Tasks protocol shape: request, reply, `settled {tx, seq}`, events with `after_seq`).

### 7.2 Host election, failover, and no two writers

Owner of the placement: `TeamDO` holds one **app server lease** per (team, app): `{app, host, epoch, state: active|draining|vacant, since, last_host_seen}`. Only `TeamDO` writes it; hosts and clients are projections.

Placement (who runs it):
1. If a team admin pinned a host (`app.server.place {app, host}`, origin user), that host, if its kind is in `hosts`.
2. Else the first kind in `hosts` order that the team has: the team VM if the team has one; else the team's designated default server (`servers.defaultAppHost`, set by an admin; the first paired team server when unset); `local` only for a team of one (the owner's own Mac), because a laptop that sleeps must not be the writer for other people.
3. The chosen host must be paired, not revoked, run the `apps` role, and be able to reach the app's durable data (7.3).

Lease protocol (event-driven, no renewal timer):
- `TeamDO` grants the lease by sending `app.server.assign {app, epoch}` to the host over its link. The host starts the server only after it receives the assignment and after its storage fence for that epoch succeeds (7.3). Every op routed to the server carries the epoch; the server rejects a different epoch with `owner_moved`.
- The lease is live while the host's link to `HostDO` is connected. `HostDO` reports link close to `TeamDO` as an event. `TeamDO` then sets a one-shot alarm at `close + lease_grace` (default 90 s, team setting `apps.failoverGraceSeconds`).
- The host fences itself: when its link closes, it sets a one-shot deadline at `close + self_fence` (default 60 s, always less than `lease_grace` minus a 15 s clock-rate margin). If the link is not back by then, the supervisor stops the app server (drain, then SIGTERM, then SIGKILL after 10 s). A partitioned host therefore stops writing before any other host can start.
- If the link returns before the alarm, nothing moves. If the alarm fires, `TeamDO` moves the lease: `epoch + 1`, the next eligible host by the placement rules, state `active` only after that host acknowledges the assignment and its storage fence succeeded. While no host holds the lease, `owner_for` returns `owner_unreachable` (U5: nothing queues).
- Planned moves (`app.server.move {app, host}`, admin, origin user; or the old host shutting down cleanly): the old host drains (refuses new ops with `owner_moving`, finishes the group commit, flushes durable data, acknowledges `released {epoch}`), then `TeamDO` assigns `epoch + 1`. No grace wait.
- Team VM: the team VM is a stable host identity. A dead team VM is replaced by `TeamVmDO` restore (spec/team-vm.md); the replacement mounts the same zero-loss tier and keeps the lease under a new epoch. Failover to a cmux server happens only if the app lists `cmux-server` and the admin turned on `apps.failoverToServers` (default off), because the team VM normally comes back in minutes.

No two hosts run at once, three independent fences:
1. One lease owner: `TeamDO` is the single writer of the lease and assigns a strictly increasing epoch.
2. Time fence: the old host stops at `self_fence` after it loses the link; `TeamDO` waits `lease_grace` > `self_fence` + margin before it reassigns. This needs only bounded clock rate, not synchronized clocks.
3. Storage fence (holds even if 1 and 2 fail): every durable write carries the epoch (7.3). A host with an old epoch cannot commit.

Verification: a TLA+ model `formal/AppServerLease.tla` (hosts, link loss and return, partitions, slow clocks within the margin, crashes; invariant "at most one host commits under any epoch, and commits are totally ordered by epoch"), plus a mutant without the self-fence that must fail.

### 7.3 `data: durable`: storage and backups

The supervisor gives every app server two stores. Each is fenced by the lease epoch.

| Store | Where | Durability | Fence |
| --- | --- | --- | --- |
| data directory `CMUX_APP_DATA` (files: the Tasks op log, snapshots) | team VM: `/srv/team/apps/<app>/data` on the zero-loss tier; cmux server: local disk `<state>/apps/<app>/data`, with each committed segment shipped to the team's R2 prefix `apps/<app>/epoch-<n>/` | team VM: zero loss (acknowledged writes are in R2); cmux server: zero loss only when the app commits through `cmux app data commit` (below), else bounded by its shipping lag | conditional create of `apps/<app>/lease/<epoch>` in R2 at start; segment objects are written with conditional create under the epoch prefix, so a stale host's writes land in a dead prefix that restore ignores |
| Postgres schema `app_<app>` in the host's cluster (section 8), when the app asks for it (gap G1) | the lease host's cluster | WAL archived to R2 every 60 s at most (R7: up to 60 s loss); synchronous archive on commit is not offered | the archive prefix includes the epoch and the Postgres timeline; a new host restores from the newest epoch's base backup + WAL and starts a new timeline |

- Zero-loss on a cmux server: `cmux app data commit <path>` (and the same op on the SDK) uploads the file or appended range to R2 with a conditional create keyed by `(epoch, seq)` before the app acknowledges its client. Tasks' group commit calls it once per batch (one R2 PUT per group commit, about 30 to 120 ms estimate), which is the same cost the Tasks plan accepted for the no-FUSE fallback. Apps that skip it get bounded loss and the manifest must say so (gap G1).
- Failover restore: the new host fetches the newest snapshot and every segment of the newest epoch prefix (Postgres: base backup + WAL), verifies the hash chain, starts the server, then acknowledges the assignment. Measured restore time is the failover time; target under 60 s for 100k tasks (UNVERIFIED).
- Backups: R2 object versioning on the prefix, daily base backups for Postgres (section 8.4), and for files a daily snapshot manifest; restore is `server.app.restore {app, at}` (admin, user origin), which takes a new epoch.
- Postgres schema per app: in the host's cluster, role `app_<app>`, schema `app_<app>` in the shared database `cmux_apps` (`mode: schema`, the coordinator's default for app servers; schema mode lets an app see other apps' table names and function source through the catalogs, so this lane recommends `mode: database` for apps with sensitive schemas), owned by the role, `REVOKE ALL ON SCHEMA … FROM PUBLIC`, role `search_path = app_<app>`; auth as section 8.3. A second host never has the schema live: the schema exists only in the lease host's cluster and is restored on move.

### 7.4 Supervision

- System mode on Linux and the team VM: the store under `/opt/cmux` is root-owned and read-only to the service user; updates run as the root oneshot `cmux-update.service`, triggered by `cmux-update.path` when the supervisor writes `/run/cmux/update-request` (no timer, no root in the long-running process). The main unit `cmux-server.service` (`Type=notify`, `User=cmux`, `Group=cmux`, `KillMode=process`) is not hardened with `ProtectHome` or `NoNewPrivileges`, because hosted terminals need home directories and `sudo`; app servers get the strict hardening. Windows system mode installs binaries under `%ProgramFiles%\cmux` and keeps state under `%ProgramData%\cmux\server` with an owner and ACL check at every start.
- App servers in system mode: a systemd unit from the template `cmux-app-server@<app>.service`, OS user `app-<app>` (no login), `MemoryMax`, `CPUQuota`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `ReadWritePaths=` only the app's data and run directories. The unit is started only by the supervisor after the lease assignment, never `WantedBy` a boot target (a reboot never starts a writer without a lease).
- User mode and macOS: a child process with an OS sandbox (macOS seatbelt: files only in the bundle, data and run directories, network to loopback and granted hosts; Linux Landlock + seccomp; Windows job object + restricted token). After a supervisor restart it re-adopts the process by pid file plus process start time, and only if the lease epoch is unchanged.
- Readiness: the server is ready when it answers the catalog's `ping` (gap G2) on `CMUX_APP_SOCKET`; only then does the host acknowledge the assignment. Liveness is the process and the socket (no periodic probe; a request deadline miss counts as a failure).
- Restarts: `Backoff` (1 s doubling to 5 min). Five crashes in 10 minutes is a crash loop: the supervisor stops, posts a `server.app.crashloop` feed item to the team admins, and keeps the lease (a crash loop on one host usually repeats on the next; moving needs an admin `app.server.move`).
- Environment: `CMUX_APP_ID`, `CMUX_APP_VERSION`, `CMUX_APP_EPOCH`, `CMUX_APP_SOCKET`, `CMUX_APP_DATA`, and for Postgres `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSFILE` (user mode). No secrets in env or args; integration calls go through the gateway.

### 7.5 Upgrades

- The app version comes from the team install (`TeamDO`, spec/app-platform.md); the supervisor downloads the bundle, checks SHA-256 and the attestation, and unpacks into the content-addressed cache.
- Order: run `<binary> check-data --data $CMUX_APP_DATA` from the new version in a read-only sandbox (gap G4: data format version); drain the running server (refuse new ops with `owner_moving`, finish the group commit, flush); take a data snapshot (R2 snapshot manifest; Postgres: a restore point); start the new version under the same epoch; wait for `ping`; resume routing. Failure at any step restarts the old version on the old data.
- Downgrade: refused when the data format version moved forward, unless the admin restores the pre-upgrade snapshot (`server.app.restore`).
- Updates follow `apps.autoUpdate` (spec D49: `sameScopes`); a version whose catalog grows needs consent like scope growth.

### 7.6 Logs

- stdout and stderr: journald with `SYSLOG_IDENTIFIER=cmux-app-<app>` (system mode) or a bounded ring file per app, 16 MiB x 4 (user mode). JSON lines are parsed into the structured record of spec/automations-runtime.md section 6 (`ts, team, app, version, epoch, level, msg, attrs, trace_id`).
- `cmux server app logs <app> [--follow] [--since T] --json`, the app's Logs view in the App Store window, and forwarding over the link to the team telemetry store when paired.
- Every lease change, start, stop, crash, upgrade and restore is an audit record in `TeamDO` with actor and epoch.

### 7.7 Gaps in the `server` block (recommendations)

- G1. `data: durable` does not say what is stored or how much loss is allowed. RECOMMEND `data: {files: true, postgres: "schema" | "database" | false, durability: "zero-loss" | "bounded"}`; Tasks = `{files: true, postgres: false, durability: "zero-loss"}`. The supervisor refuses `zero-loss` on a host that cannot provide it (no `commit` path).
- G2. No readiness or health contract. RECOMMEND a required catalog op `<app>.ping` (or a fixed `server.ping` every server implements) and `drain` / `released` handshakes for planned moves and upgrades.
- G3. `binary` is one path, but servers run on x86_64 and aarch64 Linux, macOS and Windows. RECOMMEND `binaries: {"<target>": {path, sha256}}`, each covered by the bundle attestation; a host whose target is missing is not eligible.
- G4. No data format version. RECOMMEND `dataVersion` (integer) plus `check-data` and `migrate-data` subcommands, so the supervisor can refuse downgrades and run migrations under a snapshot.
- G5. `hosts` mixes placement preference and permission. RECOMMEND keeping it as the allowed list in preference order, and adding `failover: "auto" | "manual"` (Tasks: auto) so an app that cannot restore fast can opt out.
- G6. `local` contradicts single writer for teams larger than one (a sleeping laptop would hold the lease). RECOMMEND `local` = eligible only for a team of one or an explicit admin pin.
- G7. No resource or network declaration. RECOMMEND `resources {memoryMiB, cpuPercent}` and `net: ["host:port"]` (default none), enforced by the sandbox.
- G8. Name: `cmux-server` as a host kind is spelled `server` in `TeamDO` host records. RECOMMEND `hosts: ["team-vm", "server", "local"]`.

### 7.8 Tenancy: team, user and machine app servers

Input from lane 3 (plans/cmux-next/first-party-apps.md section 10, PR https://github.com/manaflow-ai/cmux/pull/16786): Tasks is per team, notes is per user (`cmux-notes serve`), usage is per machine (`cmux-usage serve`); search, coderouter and inbox have no server. Proposed field: `server.instances: "team" | "user" | "machine"` (default `team`). This lane adopts it.

Single-writer election is per **tenancy key**. Exactly one host runs the app server for each key, and the key's owner holds the lease:

| `instances` | Tenancy key | Lease owner | Who may host | Election |
| --- | --- | --- | --- | --- |
| `team` | (team, app) | `TeamDO` | team VM, team servers, `local` only for a team of one (7.2) | 7.2 |
| `user` | (user, app) | `UserDO` | the user's own hosts only: the user's paired servers (owner = user), the user's personal team VM (team of one), the user's Macs | below |
| `machine` | (host, app) | that host's `apps` role | that host only | none: the host is the key; a local `flock` on the data directory stops a second process on the same machine |

Per-user servers (notes) when the user has several devices:
1. Placement order: a user pin (`app.server.place {app, host}` on `UserDO`, origin user); else the user's always-on host (a paired server the user owns, then their personal team VM); else the user's **home Mac** (setting `apps.userHomeHost`; default the first Mac the user made a server, else the Mac where the user installed the app). The server never follows the active device: moving the writer each time the user switches devices would thrash the lease and the data.
2. Other devices (the iPhone, a second Mac, the web) are clients: `owner_for(note.*)` routes their ops through the link to the lease host, like any remote owner.
3. When the lease host sleeps or is offline, the user's ops refuse with `owner_unreachable` (U5: nothing queues), and clients show the last read-only snapshot from `HostDO`'s cache (spec/sync-and-transport.md section 5). This is the same rule as D10 local conversations. The product consequence: a user who wants notes writable from the phone while the Mac sleeps needs an always-on host; the Notes app offers "Keep notes on <server>" when the user has one, and the menubar shows "Notes are on this Mac" while the home host is a Mac.
4. Failover: automatic only between always-on hosts (same lease protocol as 7.2 with `UserDO` as lease owner, same three fences). A Mac never takes or loses a user lease automatically, because sleep is normal for a Mac; the move is `app.server.move` by the user, which drains the old host if it is awake or restores from the R2 copy (7.3) if it is not.
5. Data for `user` apps ships to the user's R2 prefix (`users/<user>/apps/<app>/epoch-<n>/`), never the team prefix, so a team admin or the team VM cannot read it.

Per-machine servers (usage): each machine that has the app installed runs its own server with `data: cache`; catalog ops carry a `host` target (default: the caller's machine), and `owner_for` routes to that host. No election and no failover, because each instance owns only its machine's data.

### 7.9 Lane 3 gaps and this lane's recommendations

These extend 7.7 (G1 to G8):
- Tenancy: adopt `server.instances` as above (G9).
- Catalog-only apps: adopt top-level `catalog` without `server` plus `requires: [op names]`; the supervisor runs nothing for them (G10).
- Data classes: merge with G1 into one object: `data: {class: "durable" | "cache" | "none", files: bool, postgres: "schema" | "database" | false, durability: "zero-loss" | "bounded", sync: "none" | "user" | "team"}`. `cache` is local, lossy, never backed up and deleted on uninstall; `sync` names who may read projections, and the writer stays the lease host (G1).
- Server principal: adopt `app:<id>/server`, acting on behalf of the tenancy key's owner (team, user or machine owner), with its own `server.scopes` shown at consent next to the client scopes; local file reads are listed paths that the OS sandbox of 7.4 enforces (G11).
- Lifecycle: adopt `server.activation: "always" | "onDemand"`. `onDemand` starts the server on the first routed op or subscriber and stops it after the last subscriber leaves and a one-shot idle deadline passes (default 60 s); `always` runs while the host holds the lease. Crash policy, upgrades and logs are 7.4 to 7.6 (G12).
- Per-platform binaries: same as G3.
- Tier rule for native code: RECOMMEND `server.kind: native` for first-party apps only; Verified apps get a server only through a sandboxed kind (`workerd` or WASM, later), because a Verified publisher's native binary is third-party native code that the platform spec excludes. Native panes stay as the coordinator decided (G13; this narrows 7.1).
- Id grammar: RECOMMEND renaming Tasks to `cmux/tasks`. The manifest grammar `<publisher>/<name>` is already implemented, validated and used by the store, the scope ids (`app:<id>`) and global contribution ids (`<app>#<id>`); `cmux` is the reserved first-party publisher; reverse-DNS ids would need a second grammar everywhere. Keep `dev.cmux.tasks` only if a platform bundle id needs it, as a derived value (G14).
- Schema: the manifest schema rejects a `server` key today (unknown top-level keys are errors). The app platform lead adds `server`, `catalog`, `requires` and `data` to `cmux-app.schema.json` with the decisions above; until then lane 3 and Tasks keep their blocks in plans (G15).

## 8. Postgres (SV2)

### 8.1 Binaries and cluster

- One cluster per install, created at first use, never in an image (lane 1, vm-image.md 5: the image bakes binaries only; a cluster in the snapshot slows `vms.create`).
- Version: PostgreSQL 17 everywhere (lane 1 bakes PGDG 17 in L1 on VMs; the automations research verified 16, superseded). Servers get a relocatable PostgreSQL 17 build as a store package `postgresql-17` (our CI, per target); Windows uses the same package built for Windows.
- Data directory on local disk: `<state>/postgres/17/data` (never on JuiceFS or a network filesystem). `initdb --data-checksums --encoding=UTF8 --locale=C --locale-provider=builtin --builtin-locale=C.UTF-8 --auth-host=reject --username=cmux_admin` (the built-in provider, because macOS and Windows may lack an OS `C.UTF-8` locale), with `--auth-local=peer` in Linux system mode only and `--auth-local=scram-sha-256 --pwfile=<admin secret>` everywhere else (section 8.3; on Windows the secret file is DPAPI-protected). No role has a password unless section 8.3 requires one, and every password is random and generated by the server.

### 8.2 Unique port and local-only listener

- Port: deterministic first candidate `15432 + (fnv1a(install_id) mod 10000)`, then the next free port in that range; never 5432 or any port in use; persisted in `server.json` (`postgres.port`) so it never changes. The install reserves a block of 32 ports starting there: `+0` Postgres, `+1..+31` reserved for app servers that need a loopback port. A user can set `postgres.port` explicitly.
- Listener: `listen_addresses = ''` (Unix socket only). Socket directory `<state>/postgres/run`, mode 0700 (user mode on Linux; on macOS `<state>` is too long for the 103-byte socket path limit, so the socket directory is `/tmp/cmux-<uid>/pg-<port>`, created 0700 and owner-checked at every start) or `/run/cmux/postgres` 0750 group `cmux-db` with the app users as members (system mode). TCP on `127.0.0.1` is enabled only when a service declares that it cannot use a Unix socket (Windows always), with `host … 127.0.0.1/32 scram-sha-256` and nothing else. Remote access is never a listener change: `server.db.expose {app, to}` (admin, user origin) opens a proxied, authenticated overlay stream.

### 8.3 Per-app auth and isolation

| Mode | App process runs as | Auth | Secret |
| --- | --- | --- | --- |
| system (Linux, team VM) | OS user `app-<app>` | `local sameuser app_<app> peer map=cmuxapps` with `pg_ident` `cmuxapps app-<app> app_<app>` | none |
| user (Linux, macOS, Windows) | the installing user, sandboxed per app (Linux: bubblewrap mount namespace; macOS: seatbelt; Windows: restricted token) | `local sameuser app_<app> scram-sha-256` | a random 32-byte password in `<state>/apps/<app>/pgpass` (0600), passed as `PGPASSFILE`; the server stores only the SCRAM verifier; never in env, argv or logs |

- `pg_hba.conf` is generated in full and owned by the server; the last rule is `reject`. System mode: `local all cmux_admin peer map=cmuxadmin` (`pg_ident` `cmuxadmin cmux cmux_admin`, because the service OS user is `cmux`) plus `local replication cmux_admin peer map=cmuxadmin` for `pg_basebackup`, so only the service user is superuser. User mode: `local all cmux_admin scram-sha-256` with a random secret in `<state>/postgres/admin.pgpass` (0600), and every app process runs in a sandbox that cannot see `<state>/postgres` or any other app's directory. Reason (measured on Freestyle, 2026-10-02): peer auth in user mode gave every same-user app superuser access, because all apps run as one OS user; Landlock on kernel 6.1 cannot block a connect to the socket. So user mode has exactly one non-app secret, the admin secret, and its protection is the per-app sandbox; system mode has none.
- App ids (manifest grammar) map to Postgres names by one function in `cmux-server-core`: lowercase; `/`, `-` and `.` become `_`; a leading digit gets the prefix `a_`; a name longer than 40 bytes keeps its first 31 bytes plus `_` and 8 hex characters of SHA-256 of the full id (`cmux/tasks` becomes `app_cmux_tasks`). A collision is refused at install.
- Per app: role `app_<app>` (`LOGIN`, `CONNECTION LIMIT 20`, `statement_timeout 30s`, `idle_in_transaction_session_timeout 60s`, `temp_file_limit 1GB`), database `app_<app>` owned by it (or schema `app_<app>` in a shared database when the manifest says `mode: schema`), `REVOKE ALL ON DATABASE … FROM PUBLIC`, `REVOKE CREATE ON SCHEMA public FROM PUBLIC`. App ids are validated (`[a-z][a-z0-9_]{0,40}`) before they become identifiers, and every identifier is quoted.
- The service gets `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `DATABASE_URL` without a password.
- Agents never get superuser. `cmux server db shell <app>` opens `psql` as the app role for the owner and their mux.
- Size: Postgres cannot cap a database; the health role reports `pg_database_size` per app and alerts at 80% of `postgres.appQuotaGiB`, at 100% it sets `default_transaction_read_only` (advisory: an app can override it per session), and past the hard cap `server.db.limits.set {app, blocked: true}` sets the role's `CONNECTION LIMIT 0` and ends its sessions (the only enforceable cap, because the app owns its tables).

### 8.4 Backups and restore

- `archive_mode = on`, `archive_timeout = 60`, `archive_command = '<current>/bin/cmux server db archive-wal %p %f'`: the `cmux` binary copies the segment to `<state>/backups/wal/` (fsync, then rename) and, for paired servers with off-site backup on, uploads it to the team's R2 prefix through short-lived upload URLs from the link (no storage credential on the server).
- Base backup daily at a one-shot deadline in a window (`postgres.backupWindow`, default 03:30 local), `pg_basebackup -Ft -z -X none`, retention 7 daily + 4 weekly (`postgres.backupRetention`). The next deadline is computed after each run; there is no timer loop.
- Up to 60 s of commits can be lost on disk loss (R7 accepted this for app databases); zero-loss apps upgrade to managed Postgres.
- `server.db.restore {app?, at?}` restores the cluster to a point in time into a new data directory, or one app's database by dump from a restored temporary cluster; the old directory stays until the owner confirms. `server.db.backup.status` reports the last WAL and base backup.
- macOS: the data directory is excluded from Time Machine (a live copy is not consistent); `<state>/backups` is included.

### 8.5 Upgrades

- Minor: the store updates the package; the `postgres` role restarts the cluster with a fast shutdown when no transaction is open, or at the next backup window.
- Major: never automatic. A feed item offers it. `server.db.upgrade {to}` takes a base backup, runs `pg_upgrade --check`, then `pg_upgrade --link` into a new directory, analyzes, and keeps the old directory until the owner confirms or 7 days pass (destructive policy at the owner, in the same op record).

## 9. Health (SV3)

### 9.1 Enforcement (no settings change, held while the server role is on)

| Platform | What cmux holds | Notes |
| --- | --- | --- |
| macOS | `IOPMAssertionCreateWithName`: `PreventUserIdleSystemSleep` always; `PreventSystemSleep` on AC power (macOS ignores it on battery); `PreventUserIdleDisplaySleep` on AC unless `server.health.allowDisplaySleep` (prevents idle lock where MDM does not force it) | released when the role stops or the process exits |
| Linux | one logind `Inhibit` file descriptor per kind (mode `block`): `idle` always; `sleep` and `handle-lid-switch` only with the one-time polkit rule (system mode installs it; user mode raises `inhibit.limited`), because logind refuses `sleep` to a lingering user without a session and refuses a combined request | measured on Freestyle 2026-10-02 |
| Windows | `PowerCreateRequest` + `PowerSetRequest(SystemRequired, AwayModeRequired)` | |

### 9.2 Probes (event-driven, no polling)

| Fact | macOS | Linux | Windows |
| --- | --- | --- | --- |
| power source, battery level | `IOPSNotificationCreateRunLoopSource` | UPower D-Bus `PropertiesChanged` | `RegisterPowerSettingNotification` |
| internet | `nw_path_monitor` plus the link to `HostDO` (connected = internet works; captive portals show as link down) | netlink route events plus the link | `NotifyIpInterfaceChange` plus the link |
| disk free | `EVFILT_FS` `VQ_LOWDISK`/`VQ_VERYLOWDISK` events plus a one-shot deadline re-check sized to headroom / observed write rate (clamped 1 to 30 min) | one-shot deadline as macOS | one-shot deadline |
| pending lock | screen lock settings, `com.apple.screenIsLocked` / `screenIsUnlocked`, whether the display assertion is held, MDM-forced lock delay | logind `IdleHint`, `LockedHint` | `WTS_SESSION_LOCK` |
| survives restart | FileVault on and automatic login off (the Mac waits at the unlock screen after a power loss), `pmset autorestart`, pending software update restart | unit enabled, linger on | service start type |
| sleep settings | `pmset -g custom` read at start and on `kIOPMSystemPowerStateCapability` changes | `systemctl is-enabled sleep.target`, logind `HandleLidSwitch` | `powercfg /query` at start and on power setting change events |
| disk encryption | FileVault | LUKS on the state volume | BitLocker |

### 9.3 Checks, alerts and the feed

A pure reducer in `cmux-server-core` turns facts into alerts: `(facts, previous alerts, now) -> (alerts, posts)`. Each alert has a stable check id, a severity, a dedupe key `server:<host>:<check>`, hysteresis and an optional fix.

| Check | Raised when | Severity | Fix |
| --- | --- | --- | --- |
| `power.onBattery` | on battery for 60 s | warning; critical under 20% | none (plug in) |
| `network.offline` | link down and no route for 30 s | critical | none |
| `disk.low` | free < 10% or < 10 GiB (warning), < 5% or < 2 GiB (critical); clears 2 points above | warning, critical | open storage settings |
| `lock.pending` | the display assertion is not held (battery, MDM, user setting) and the idle lock is due within 5 minutes while a GUI workload (computer use, a headful browser) runs | warning | hold the display assertion, or open Lock Screen settings |
| `sleep.enabled` | system sleep on AC is enabled in settings (our assertion covers idle sleep, not a lid close or a scheduled sleep) | info | `pmset -c sleep 0 disksleep 0` (admin once) |
| `restart.noAutoRestart` | `autorestart` off | info | `pmset -a autorestart 1` (admin once) |
| `restart.fileVaultWait` | FileVault on and auto login off | warning | none automatic; `fdesetup authrestart` is used for planned update restarts |
| `restart.notLoggedIn` | macOS headless install: LaunchAgent and no login after boot | warning | install the system LaunchDaemon variant (admin once) |
| `linger.off` | Linux user mode without linger (for example no polkitd) | critical | `loginctl enable-linger` (sudo once) |
| `inhibit.limited` | Linux user mode holds only the `idle` inhibitor | info | the polkit rule (sudo once) |
| `encryption.off` | disk encryption off | info | open settings |
| `postgres.quota` | an app at 80% of its quota | warning | raise quota |
| `backup.stale` | no base backup in 48 h or WAL archive failing for 10 min | warning | run backup now |

Posting: every raise or change of an alert is `feed.notify` through the lane 9 feed API with `{kind: "server.health", host, check, severity, title, body, actions: [{id, title, op, params, needs_admin}], dedupe_key}`; clearing posts `feed.resolve {dedupe_key}`. Until that API exists, the server posts through the local daemon `notify` (source `daemon`) and the menubar shows the alert set directly; the `FeedSink` seam in `cmux-server` switches without other changes.

### 9.4 One-click fixes (admin once)

- macOS: a privileged helper registered once with `SMAppService.daemon` (the user approves it once in System Settings > Login Items). It exposes an XPC interface with a fixed allowlist of fixes (`pmset` sleep, disksleep, autorestart, womp, the LaunchDaemon variant), each one an argv template with validated values, never a free command. Fixes that need the user's password or a settings pane (Lock Screen, FileVault, auto login) open the pane with a deep link instead.
- Linux: system mode installs a polkit rule that allows the `cmux` user the listed `systemctl mask` actions and a logind drop-in; user mode shows the one `sudo` command.
- Windows: system mode service applies `powercfg` changes; user mode asks for elevation once per fix.
- Every fix is the op `server.health.fix {check, fix}` (origin user only; agents may propose it as a feed request, never run it), records the previous value, and has `server.health.revert {check}`.
- Prototypes and tests never apply fixes to a developer's own Mac: the fix executor has a `dryRun` mode that prints the plan; real application is tested only in a VM or a tagged app with the helper in a throwaway user.

## 10. Browser and installed software

- Browser: `cmux browser host` (spec/browser-use.md) with `chrome-headless-shell` from the store (pinned, SHA-256), `--remote-debugging-pipe`, one user data directory per workspace profile, sandbox on. Ubuntu 23.10+ restricts unprivileged user namespaces through AppArmor: system mode installs an AppArmor profile for the store path; user mode reports the browser role unavailable with the one `sudo` command rather than using `--no-sandbox`. macOS servers use the same package when the app is not running and the app's CEF tabs when it is.
- Installed software: `server.software.list|install|remove {package}` installs from the signed store catalog (agents, toolchains, runtimes) into the store, per user or system. System packages (`apt`, `dnf`, `brew`, `winget`) go through `server.software.system_install {manager, package}` with user approval (a feed request) and the privileged path; muxes may request, ordinary agents may not.

## 11. Servers and the team VM: one model

| Aspect | Server | Team VM |
| --- | --- | --- |
| binaries | installer into the store (section 4) | baked into the image L2 store (lane 1), same channel manifest |
| identity | install key made at install; pairing binds it | instance binding by the control plane at create; per-clone keys after bind (lane 1 section 6) |
| unit | `cmux host run` (user or system) | `cmux host run` (system) |
| roles | `server` set (section 5) | `team` set = server set + reconciler, mailbox, memory, audit, JuiceFS mount |
| app servers | `server` block, lease 7.2, supervisor 7.4 | the same; preferred host; Tasks is the first |
| Postgres | store package `postgresql-17`, user or system mode | PGDG 17 from L1, system mode; identical cluster code |
| backups | local + optional team R2 | team R2 (lane 1 and R7) |
| health | full section 9 | disk, memory, link, backup; power and lock checks inactive |
| updates | channel manifest, settings, pins | same; the control plane can pin a team |

## 12. Ownership

| Entity | Owner | Others |
| --- | --- | --- |
| server config (`server.json`: roles, ports, channel, pins, health settings) | config layer on that machine | the app and CLI write through ops |
| host record (kind, owner, team, tags, revoked) | `TeamDO` | projection in clients and PlanetScale `cmux-next` |
| pending pairing | `PairingDO` (one per code, deleted on approve or expiry) | |
| install public key, grants | `UserDO` / `TeamDO` | |
| health facts and the alert set | the `health` role on that server (single writer) | the feed and the menubar are projections |
| feed items | the feed owner (lane 9) | the server posts and resolves through its API |
| Postgres cluster, app roles and databases, backups | the `postgres` role on that server | apps are clients |
| app server lease (host, epoch) | `TeamDO` (team apps), `UserDO` (user apps), the host itself (machine apps) | hosts and `owner_for` are projections |
| app server process | the `apps` role on the lease host | |
| app installs and app grants | `UserDO` / `TeamDO` (spec/app-platform.md) | the supervisor is a projection |
| applied store generation | the `updater` role on that server | reported to the control plane |

All mutations are typed ops with idempotency keys to these owners; destructive ops (uninstall `--purge`, `db.drop`, `db.restore`, major upgrade cleanup) decide their policy at the owner in the same commit.

## 13. Operations and surfaces

| Op | Owner | CLI | Palette | Right-click | MCP |
| --- | --- | --- | --- | --- | --- |
| `server.status` | local `server` | `cmux server status --json` | Server Status | menubar | default |
| `server.up {roles?}` / `server.down` | local | `cmux server up|down` | Make This Mac a Server / Stop Serving | menubar | opt_in |
| `server.install`, `server.uninstall {purge}` | local | `cmux server install|uninstall` | exempt (installer path) | — | never |
| `server.upgrade`, `server.rollback`, `server.pin` | local `updater` | `cmux server upgrade|rollback|pin` | Update Server Software | menubar | opt_in |
| `server.roles.set` | local | `cmux server roles set` | Server Roles… | — | opt_in |
| `server.pair.begin` / `server.pair.status` | local + `PairingDO` | `cmux server pair` (prints code, QR, words; `--wait`) | Show Pairing Code | menubar | never |
| `server.pair.approve {code, team, name}` | `TeamDO` | `cmux servers add <code>` (user TTY only) | Add Server… | — | never |
| `server.enroll_self {team, name}` | `TeamDO` | exempt (app path) | Make This Mac a Server | menubar | never |
| `server.unpair`, `host.revoke` | local / `TeamDO` | `cmux server unpair`, `cmux servers revoke <host>` | Unpair This Server / Revoke Server | server row | never |
| `server.health.get` | local `health` | `cmux server health --json` | Server Health | menubar | default |
| `server.health.fix`, `server.health.revert` | local `health` | `cmux server health fix <check>` | per alert | alert row | never (agents request via feed) |
| `server.db.list|create|drop|url|limits.set|backup|restore|upgrade|expose` | local `postgres` | `cmux server db …` | Server Databases | db row | list/url default; create opt_in; others never |
| `server.app.list|restart|logs|restore` | local `apps` | `cmux server app …` | per app | app row | list/logs default; restart opt_in; restore never |
| `app.server.place|move {app, host}` | `TeamDO` | `cmux apps server place|move` | Move App Server… | app row | never |
| `server.software.list|install|remove|system_install` | local | `cmux server software …` | Install Software… | — | list default; others approval |

Settings (cmux.json, Settings > Server, MDM-lockable): `server.enabled`, `server.roles`, `server.channel`, `server.autoUpdate`, `server.pinnedVersion`, `server.health.allowDisplaySleep`, `server.health.alerts.<check>` (on/off, thresholds), `postgres.port`, `postgres.backupWindow`, `postgres.backupRetention`, `postgres.appQuotaGiB`, `postgres.offsiteBackup`. Team policy: `servers.enabled`, `servers.memberEnroll`, `servers.allowedRoles`.

## 14. Prototypes (DEV/NIGHTLY, Debug Settings > Server)

Swift module `CmuxNextServer` renders a projection of `server.status` with a mock source until the Rust role exists.

| Tunable | Variants |
| --- | --- |
| `server.panel.style` (menubar panel) | `compact`: status line, on/off switch, four rows (Terminals, Apps, Database, Health); `dashboard`: cards per role with counts and the pairing code; `list`: grouped list (Services, Health, Devices) with inline actions |
| `server.pairing.style` | `code`: large code, small QR, the four words; `qr`: large QR, code below; `words`: the four words as the primary check and the code in a field (for reading aloud) |
| `server.health.style` | `checklist`: every check with state and Fix; `summary`: one status line, only the open issues; `timeline`: alerts over time with resolve markers |

Built in PR https://github.com/manaflow-ai/cmux/pull/16840 (module `CmuxNextServer`, mock scenarios: healthy paired Mac, battery + low disk + pending lock, unpaired, Linux headless). Recommendation, now the code defaults: panel `compact` (fits a menubar popover; `list` is the better full Server window), pairing `code` (works on every approval path, the small QR serves the phone, the words stay visible), health `checklist` (shows passing and failing checks with inline fixes; `summary` suits an issues-only area). Lawrence picks after dogfood. The App does not host the views yet (menubar status item and palette actions are step 7).

## 15. Steps

| # | Step | State |
| --- | --- | --- |
| 1 | This plan | draft |
| 2 | `cmux-server-core` pure crate: layout, ports, Postgres plan (conf, hba, ident, per-app SQL), pairing code and words, health reducer, unit renderers, channel manifest verification, op catalog (38 ops); 60 tests, clippy and fmt clean on a Blacksmith Testbox (PR https://github.com/manaflow-ai/cmux/pull/16814) | done |
| 3 | Headless Linux prototype on a Freestyle VM (`server/prototype/linux/`, README has the numbers): installer with checksum, signature, expiry and downgrade refusal; user systemd service running the real pinned session host; idempotent rerun, upgrade with terminal adoption, rollback, uninstall, purge, reboot survival; Postgres 17 user and system mode with PITR; sandboxed chrome-headless-shell; logind inhibitors; idle 0.031 CPU-s/min | done (system mode end to end, aarch64, macOS, Windows UNVERIFIED) |
| 4 | `CmuxNextServer` Swift prototypes (panel, pairing, approver, health; three variants each), 22 tests, 42 screenshots (PR https://github.com/manaflow-ai/cmux/pull/16840) | done (not hosted in the App yet) |
| 5 | `cmux-server` I/O crate: `cmux host run` roles, probes, assertions, supervisor, Postgres runner; mounted as `cmux server …` after #16174 | next |
| 6 | `PairingDO`, `server.pair.*`, `host` kind `server` in `TeamDO`; network policy `tag:server` | next (backend) |
| 7 | macOS: launchd agent via `SMAppService`, privileged helper with the fix allowlist, menubar wiring | next |
| 8 | Windows: installer, service, probes | later |

## 16. Risks

- Relocatable PostgreSQL builds per target are new CI work; a distro package fallback makes the server depend on root.
- Unprivileged user namespaces for the Chromium sandbox vary by distribution (Freestyle's kernel has no AppArmor, so the Ubuntu restriction was not tested); chrome-headless-shell needs its shared libraries bundled in the store package for user mode.
- The session host needs `Type=notify` readiness and a `--state` root under the server state directory (today it uses `~/.local/share/cmux-tui`, which `--purge` misses); units keep `KillMode=process` so a restart keeps terminal hosts.
- macOS LaunchAgents stop at logout; headless Macs need the LaunchDaemon variant (admin) to survive a reboot without login.
- Freestyle tunnel and firewall propagation time bounds revocation latency (spec/network-policy.md).
- The feed API (lane 9), the manifest `server` block gaps (7.7) and `TeamDO` leases (backend) are external dependencies.
- Failover restore time for large apps is unmeasured; the lease grace adds 90 s by default.
