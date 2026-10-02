# cmux next: cmux server and VM software

Status: draft 1, 2026-10-02 (server lead, lane 10). Spec owner: the coordinator (only the coordinator edits the spec repo; this file is the spec proposal "server"). Decided input: SV1 (soft self-hosting: "Make This Mac a Server" in the app, `cmux server up` on Linux and Windows, one install command, pairing over our WireGuard network, servers and the team VM share one design), SV2 (Postgres per server, unique port, local-only listener, per-app auth, no default passwords), SV3 (enforce power, sleep and lock where allowed; alert on battery, no internet, low disk, pending lock; one-click fixes, admin once), N10 to N13 (one feed, typed verbs, official apps with servers), D5 (install keys, tokens, device flow), D20 (agent classes), D3/D37 (WireGuard via Freestyle tunnels now, own control plane later), A14/A15/R7 (tier-2 automations host, default Postgres for apps). Related: spec/team-vm.md, spec/app-platform.md, spec/network-policy.md, spec/browser-use.md, plans/cmux-next/vm-image.md (lane 1, read at origin/feat-cmux-next-vm-image 216c3ff0738), plans/cmux-next/automations-runtime.md, plans/cmux-next/app-platform.md.

Binding: OWNERSHIP-PRINCIPLES.md, architecture.md (no polling, 0% idle CPU), skills/cmux-next-feature.

## 1. Goals and non-goals

Goals:
- One software model, called **VM software**, that runs the same way on three kinds of machine: a Mac that the user makes a server, a Linux or Windows box that runs `cmux server up`, and the team VM (and any cmux Cloud machine with the `team` or `server` role).
- A server hosts: terminals (session host), apps with persistent server processes (app manifest `services`), a browser (headless Chromium), automations (tier-2 host), a Postgres cluster for apps, and installed software from the signed cmux store.
- One install command per platform that just works: verified before it runs anything, idempotent, no root unless the user asks for a system install, a user service (systemd, launchd, Windows), upgrade, rollback, uninstall, version pins.
- Pairing from any signed-in device by short code or QR, with a written trust model.
- Health: hold power assertions, prevent idle sleep and idle lock where the platform and policy allow, alert into the feed, one-click fixes that need admin rights once.
- About 0 idle CPU: every probe is event-driven or a one-shot deadline.

Non-goals (phase 1 to 3):
- Public internet exposure of app services (later: an edge route per app, its own design).
- A no-account mode with remote access. Without an account, a server is local only (plus SSH, which we never configure).
- Changing the host's SSH, firewall or VPN configuration. The overlay is in-process userspace WireGuard.
- Running untrusted third-party native code as app services in phase 1 (first-party and `local/` apps only, like the app host).
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
| service | one persistent app server process declared by an app (`contributes.services`, section 7) |

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
| store, profiles, current | `~/.local/share/cmux/` | `/opt/cmux/` | app bundle (binary) + `~/Library/Application Support/cmux/store` | `~/Library/Application Support/cmux/` | `%LOCALAPPDATA%\cmux\` | `%ProgramData%\cmux\` |
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

## 5. Roles on a server

| Role | What | Default on a server | On the team VM |
| --- | --- | --- | --- |
| `session` | cmux-tui daemon (terminals, agents, presence) | on | on |
| `link` | HostDO link, overlay peer, local reverse proxy for app services | on after pairing | on |
| `apps` | service supervisor (section 7) | on | on (Tasks and team apps) |
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
- Who may use a server: the owner and team admins (everything); other team members only through network policy rules and grants (default none for a member's server; team servers: `autogroup:member` may reach app services the app exposes to `team`). Agents: the owner's mux has full reach (D20); ordinary agents only on the server they run on; runs per their automation grant.
- App services are reachable only through the server's reverse proxy, which maps the overlay peer to a principal and checks the app's `expose` rule and the caller's grant before forwarding (section 7.3).

### 6.5 Keys, tokens, revocation

- Tokens: account-mode JWTs of a few minutes (D5); refresh signs a fresh `TeamDO` challenge with the install key.
- Revocation: `host.revoke` (owner, team admin), `cmux server unpair` on the server, removal of the owner from the team, or uninstall. `TeamDO` marks the host revoked, refuses refresh, drops it from peer maps, deletes its Freestyle tunnel and firewall rules, and `HostDO` closes the link at once. Outstanding tokens expire within minutes. The server shows "Unpaired" and stops remote listeners; local terminals, apps and databases keep working.
- Lost or stolen server: revoke from any client; its keys become useless for the account. Data on its disk is the owner's responsibility (FileVault, LUKS, BitLocker; the health role warns when disk encryption is off).
- Key rotation: `cmux server rotate-keys` makes new install and WireGuard keys and registers them with a signature by the old key; a compromised old key is handled by revoke and re-pair.

### 6.6 Strongest objection

"A short code lets an attacker trick a user into approving the attacker's machine into the user's team, which then sits inside the team network." Answer: the approver sees the server's facts and the four words; QR approvals bind the key fingerprint; a server is a destination with no default outbound reach; servers get `tag:server`, which no default rule grants as a source; approval is user-origin only; every enrollment posts a feed item to the owner and the team admins with "Revoke".

## 7. Apps with persistent servers (N13)

### 7.1 Manifest proposal (to the app platform lead)

Add `contributes.services` to `cmux-app.json` (spec/app-platform.md section 3, which lists server-side apps as a non-goal; N13 makes them a goal):

```jsonc
"services": [{
  "id": "web",
  "runtime": "node@24" | "bun@1" | "workerd" | "exec",   // exec: a binary in the bundle (first-party and local/ only in phase 1)
  "entry": "server/index.js",
  "listen": "auto",                 // the supervisor allocates a port (or a Unix socket) and passes it as PORT / CMUX_SERVICE_SOCKET
  "health": { "http": "/healthz", "timeoutMs": 2000 },
  "database": { "engine": "postgres", "mode": "database" | "schema" },   // optional
  "expose": "owner" | "team" | "none",                                  // who may reach it through the proxy
  "restart": "always" | "on-failure",
  "resources": { "memoryMiB": 512, "cpuPercent": 100 },
  "scopes": { "workspace:read": "…" }                                   // catalog scopes for its cmux calls, like app JS
}]
```

### 7.2 Supervisor

- System mode on Linux and the team VM: each service is a systemd unit from the template `cmux-app@<app>.<service>.service`, running as OS user `app-<app>` (no login), with `MemoryMax`, `CPUQuota`, `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`, state in `/var/lib/cmux/apps/<app>/` (0700). Units survive a `cmux` restart.
- User mode and macOS: the supervisor spawns each service as a child with an OS sandbox (macOS seatbelt profile: no file access outside the app's bundle and state directories, network only to loopback and granted hosts; Linux Landlock + seccomp; Windows job object with a restricted token), restarts with `Backoff`, and re-adopts running services after its own restart by pid files plus start-time checks.
- Logs: journald (system mode) or a bounded ring file per service; `cmux server app logs <app> --follow`.
- Deploy: the same contract as spec/team-vm.md "Self-modifying team software" (`cmux server app deploy <app> <ref>` runs the app's contract tests in a throwaway copy, switches, health-checks, rolls back on failure). Tasks on the team VM is one app with a `services` entry.

### 7.3 Reverse proxy and identity

- Services listen on loopback ports from the install's port block (section 8.2) or on Unix sockets. Nothing listens on a public address.
- The `link` role's reverse proxy serves `https://<app>.<host>.<team>.cmux.internal` on the overlay address. It maps the WireGuard peer to a principal (`TeamDO` peer map), checks `expose` and the caller's grant, and adds a short-lived signed identity assertion (`Cmux-Identity`, JWT, 60 s, audience = app id) that the service verifies with the server's local key set (`cmux` SDK helper). Services never see user tokens.

## 8. Postgres (SV2)

### 8.1 Binaries and cluster

- One cluster per install, created at first use, never in an image (lane 1, vm-image.md 5: the image bakes binaries only; a cluster in the snapshot slows `vms.create`).
- Version: PostgreSQL 17 everywhere (lane 1 bakes PGDG 17 in L1 on VMs; the automations research verified 16, superseded). Servers get a relocatable PostgreSQL 17 build as a store package `postgresql-17` (our CI, per target); Windows uses the same package built for Windows.
- Data directory on local disk: `<state>/postgres/17/data` (never on JuiceFS or a network filesystem). `initdb --data-checksums --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=reject --username=cmux_admin` (Windows: `--auth-local=scram-sha-256` with a random admin secret in a DPAPI file, because Windows has no peer auth). No role has a password unless section 8.3 requires one, and every password is random and generated by the server.

### 8.2 Unique port and local-only listener

- Port: deterministic first candidate `15432 + (fnv1a(install_id) mod 10000)`, then the next free port in that range; never 5432 or any port in use; persisted in `server.json` (`postgres.port`) so it never changes. The install reserves a block of 32 ports starting there: `+0` Postgres, `+1..+31` app services. A user can set `postgres.port` explicitly.
- Listener: `listen_addresses = ''` (Unix socket only). Socket directory `<state>/postgres/run`, mode 0700 (user mode) or `/run/cmux/postgres` 0750 group `cmux-db` with the app users as members (system mode). TCP on `127.0.0.1` is enabled only when a service declares that it cannot use a Unix socket (Windows always), with `host … 127.0.0.1/32 scram-sha-256` and nothing else. Remote access is never a listener change: `server.db.expose {app, to}` (admin, user origin) opens a proxied, authenticated overlay stream.

### 8.3 Per-app auth and isolation

| Mode | App process runs as | Auth | Secret |
| --- | --- | --- | --- |
| system (Linux, team VM) | OS user `app-<app>` | `local sameuser app_<app> peer map=cmuxapps` with `pg_ident` `cmuxapps app-<app> app_<app>` | none |
| user (Linux, macOS, Windows) | the installing user, sandboxed per app | `local sameuser app_<app> scram-sha-256` | a random 32-byte password in `<state>/apps/<app>/pgpass` (0600), passed as `PGPASSFILE`; never in env, argv or logs |

- `pg_hba.conf` is generated in full and owned by the server; the first rule is `local all cmux_admin peer` (system mode) so only the service user is superuser; the last rule is `reject`.
- Per app: role `app_<app>` (`LOGIN`, `CONNECTION LIMIT 20`, `statement_timeout 30s`, `idle_in_transaction_session_timeout 60s`, `temp_file_limit 1GB`), database `app_<app>` owned by it (or schema `app_<app>` in a shared database when the manifest says `mode: schema`), `REVOKE ALL ON DATABASE … FROM PUBLIC`, `REVOKE CREATE ON SCHEMA public FROM PUBLIC`. App ids are validated (`[a-z][a-z0-9_]{0,40}`) before they become identifiers, and every identifier is quoted.
- The service gets `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `DATABASE_URL` without a password.
- Agents never get superuser. `cmux server db shell <app>` opens `psql` as the app role for the owner and their mux.
- Size: Postgres cannot cap a database; the health role reports `pg_database_size` per app and alerts at 80% of `postgres.appQuotaGiB`, and `server.db.limits.set {app, readOnly}` sets `default_transaction_read_only` when a hard cap is passed.

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
| Linux | logind inhibitor `sleep:idle:handle-lid-switch` (mode `block`) through D-Bus, held as a file descriptor | headless boxes rarely need it; laptops do |
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
| `linger.off` | Linux user mode without linger | critical | `loginctl enable-linger` (sudo once) |
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
| app services | `contributes.services`, supervisor 7.2 | the same; Tasks is one app |
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
| app service processes | the `apps` role on that server | |
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
| `server.app.list|start|stop|restart|logs|deploy` | local `apps` | `cmux server app …` | per app | app row | list/logs default; others opt_in |
| `server.software.list|install|remove|system_install` | local | `cmux server software …` | Install Software… | — | list default; others approval |

Settings (cmux.json, Settings > Server, MDM-lockable): `server.enabled`, `server.roles`, `server.channel`, `server.autoUpdate`, `server.pinnedVersion`, `server.health.allowDisplaySleep`, `server.health.alerts.<check>` (on/off, thresholds), `postgres.port`, `postgres.backupWindow`, `postgres.backupRetention`, `postgres.appQuotaGiB`, `postgres.offsiteBackup`. Team policy: `servers.enabled`, `servers.memberEnroll`, `servers.allowedRoles`.

## 14. Prototypes (DEV/NIGHTLY, Debug Settings > Server)

Swift module `CmuxNextServer` renders a projection of `server.status` with a mock source until the Rust role exists.

| Tunable | Variants |
| --- | --- |
| `server.panel.style` (menubar panel) | `compact`: status line, on/off switch, four rows (Terminals, Apps, Database, Health); `dashboard`: cards per role with counts and the pairing code; `list`: grouped list (Services, Health, Devices) with inline actions |
| `server.pairing.style` | `code`: large code, small QR, the four words; `qr`: large QR, code below; `words`: the four words as the primary check and the code in a field (for reading aloud) |
| `server.health.style` | `checklist`: every check with state and Fix; `summary`: one status line, only the open issues; `timeline`: alerts over time with resolve markers |

Screenshots and the recommendation are in the lane report.

## 15. Steps

| # | Step | State |
| --- | --- | --- |
| 1 | This plan | draft |
| 2 | `cmux-server-core` pure crate: layout, ports, Postgres plan (conf, hba, ident, per-app SQL), pairing code and words, health reducer, unit renderers, channel manifest verification; tests on the testbox | in progress |
| 3 | Headless Linux prototype on a Freestyle VM: installer script with checksum and signature refusal, user systemd service running the real session host, idempotent rerun, upgrade, rollback, uninstall; Postgres plan applied for real; headless Chromium | in progress |
| 4 | `CmuxNextServer` Swift prototypes (panel, pairing, health; three variants each) with screenshots | in progress |
| 5 | `cmux-server` I/O crate: `cmux host run` roles, probes, assertions, supervisor, Postgres runner; mounted as `cmux server …` after #16174 | next |
| 6 | `PairingDO`, `server.pair.*`, `host` kind `server` in `TeamDO`; network policy `tag:server` | next (backend) |
| 7 | macOS: launchd agent via `SMAppService`, privileged helper with the fix allowlist, menubar wiring | next |
| 8 | Windows: installer, service, probes | later |

## 16. Risks

- Relocatable PostgreSQL builds per target are new CI work; a distro package fallback makes the server depend on root.
- Unprivileged user namespaces for the Chromium sandbox vary by distribution.
- macOS LaunchAgents stop at logout; headless Macs need the LaunchDaemon variant (admin) to survive a reboot without login.
- Freestyle tunnel and firewall propagation time bounds revocation latency (spec/network-policy.md).
- The feed API (lane 9) and the app manifest `services` (app platform) are external dependencies.
