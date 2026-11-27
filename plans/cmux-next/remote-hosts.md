# Remote hosts: any machine's cmux sessions in every client, over the user's tailnet

Status: design + phase 1 implementation, 2026-10-19. Companion:
`plans/cmux-next/object-sync` (the object model hosts plug into).

## 0. Summary

1. A remote host is a machine (macOS, Linux, Windows) that runs the cmux session daemon and
   the host listener `cmux host serve`. Clients see it as one sidebar group per host that
   holds exactly that host's sessions (workspaces, terminals, agents), live.
2. Reach is the user's tailnet. Identity is the tailnet's node identity (WhoIs on the peer
   address), mapped to one owner login. Default: owner only. Teammates: explicit
   `cmux host allow <login>`. Anonymous: never; there is no flag for it.
3. Phase 1 (this lane, landed): system `tailscaled` on all three platforms (the Tailscale
   app or package the user already has). `cmux host enable|disable|status|serve|dial|list`,
   per-user service install (launchd agent, systemd user unit, Windows per-user Run entry), a
   probe/connect preface, discovery from `tailscale status`, the Mac app's
   bridge `cmux host dial`, and `CMUX_HOST=1` in the existing install scripts for macOS/Linux
   (`curl | sh`) and Windows (`irm | iex`).
4. Phase 2: embedded tailnet node (`cmux-tailnet` helper built on tsnet) for machines with no
   Tailscale installed: sign-in URL or auth key, own device name. It plugs into the same
   listener through an attested identity preface, so admission code does not change.
5. Phase 3: hosts become objects of the object-sync model: a host record in TeamDO
   (`host.enroll` with a `reach.tailnet` field), presence and session replicas in HostDO. The
   host list then syncs through the account to every client, and sessions of an offline host
   stay readable. The direct tailnet link stays the data plane and the control path to a
   live host (object-sync principle 7).

## 2. Requirements made testable

| # | Requirement | Testable form |
| --- | --- | --- |
| H1 | hosts and clients on macOS, Linux, Windows | `cmux host serve` admits an owner and splices the daemon on each OS; `cmux host dial` connects from each OS |
| H2 | Mac: download the app, enable in Settings; plus an automated path | Settings "Remote hosting" toggle runs `cmux host enable`; CLI `cmux host enable`; config key `remoteHosting.enabled`; MDM `DisabledFeatures: remoteHosts` still wins |
| H3 | `curl` one binary, checksum-verified, it just works | `CMUX_HOST=1` with `install-static.sh` / `install-static.ps1`: verify SHA-256 from the manifest, install, `cmux host enable`, print status (and the sign-in URL in phase 2) |
| H4 | one sidebar group per host with exactly its sessions, live | the host's `list-workspaces` + `subscribe` through the bridge render as one machine section named after the host |
| H5 | discovery + sync across the user's clients | `cmux host list` returns tailnet peers that answer the probe; phase 3 adds account-synced records |
| H6 | identity and auth | WhoIs login == owner (case-insensitive, untagged node) or in the allow list; everything else refused before any daemon byte; no anonymous mode |

## 3. First principles

1. One home per object (object-sync 3.1). A host's sessions are homed on the host's daemon.
   Clients mirror them. The host listener is a carrier, not a second owner: it adds no state.
2. Identity from the network layer we already trust, checked per connection, before any
   protocol byte. No bearer tokens to leak, no pairing secrets in URLs.
3. The owner path is the trusted local path. An admitted owner gets exactly what an SSH login
   as that user gets (the daemon sees a same-user Unix client), which is the existing
   `server-reach` contract for SSH machines. Every other principal is named explicitly.
4. One protocol. The bridge carries the unchanged daemon protocol (v12 lines, `cmux.protocol/2`
   streams), so every client that speaks to a local daemon speaks to a remote one.
5. Event-driven. Accept and splice block in threads; discovery runs when a client asks
   (app activation, sidebar open, `cmux host list`), never on a timer.
6. Logic in Rust. Swift and React render what `cmux host list` and the bridge return.

## 4. Approaches compared

### 4.1 Tailnet attachment

| | A. System tailscaled (+ WhoIs) | B. Embedded tsnet node | C. `tailscale serve` to a Unix socket |
| --- | --- | --- | --- |
| Install | needs Tailscale on the host (most users who ask already have it) | nothing besides cmux | needs Tailscale and admin rights for `serve` |
| Device name | the machine's own name (`build-box`) | a second device per machine (`cmux-build-box`) unless named | the machine's own name |
| Identity | WhoIs on the peer address (CLI or LocalAPI) | tsnet LocalClient WhoIs | Serve headers (`Tailscale-User-Login`); tagged sources are not identified |
| Headless sign-in | the machine is already signed in | auth key file or sign-in URL | already signed in |
| Platforms | macOS (app or standalone), Linux, Windows | all (pure Go, CGO off) | all, but Serve config is global admin state |
| Build cost | none (Rust + std) | a Go helper per target, ~20 MB, signed and notarized on macOS | none |
| Risks | CLI/LocalAPI version skew; other OS users on the host share the node identity (mitigated: self-address refusal) | a second key store to protect; a second device the user must approve or tag; ACLs must allow it | TLS cert provisioning, HTTP framing, identity missing for tags |

Pick: A first (phase 1), B second (phase 2), not C. A gives the machine the identity the user
already manages, needs no new toolchain and works on every OS today. B is needed for the
"curl one binary on a fresh box" promise when no Tailscale is installed, so it ships as a
separate helper (`cmux-tailnet`, Go, tsnet) that the install script fetches only when no
`tailscaled` answers. The helper terminates the tailnet connection, does WhoIs itself and
passes the identity to `cmux host serve` on a same-user Unix socket as an attested preface
line, so the admission code (section 6) is one function for both modes. C adds HTTP and TLS
for no gain and cannot identify tagged callers.

Why not Tailscale's C library (libtailscale) linked into the Rust binary: it puts cgo, a Go
runtime and Go cross-compilation into every cmux build for all six targets, and a Go panic
takes the daemon carrier down. A helper process isolates both.

### 4.2 Client reach

| | D. Direct per-host connection over the tailnet | E. Routed through Durable Objects (HostDO relay) |
| --- | --- | --- |
| Latency | one WireGuard hop (LAN or DERP) | client to edge to HostDO to host |
| Host off | nothing to read | replica readable (object-sync phase 3) |
| No tailnet on the client (phone off-tailnet, web) | no reach | works |
| Cost | none | DO messages for every byte |
| Exists today | tailnet; daemon protocol | HostDO is a 95-line relay with no route |

Pick: D for phase 1 and for live traffic forever; E as the object-sync control plane later.
They compose: the host publishes its session streams to HostDO (object-sync phase 3), and a
client that can reach the host directly uses D for live terminals and commands
(object-sync section 8, "data plane may take a direct path"). Remote hosts do not wait for
HostDO.

## 5. Object model fit (object-sync)

| Object | Home | Remote-hosts phase 1 | Object-sync target |
| --- | --- | --- | --- |
| Host (machine running a daemon) | TeamDO record + HostDO | a tailnet peer that answers the probe; local config `host/remote.json` | `host_…` in TeamDO with `reach.tailnet {node, port}`; presence in HostDO |
| Host device identity | the host | tailnet node key (WhoIs) | install record `inst_…` kind `daemon` (PairingDO approval) + tailnet node id |
| Host's sessions (workspaces, terminals, agents) | the host daemon | read live over the bridge | `host:<h>/session`, `doc:<ws>`, `host:<h>/acp` streams replicated to HostDO |
| Host list on a client | each client mirrors TeamDO | `cmux host list` (discovery + remembered hosts) | TeamDO `team.hosts.list` mirror; discovery only adds candidates to enroll |
| Access grant | the host (phase 1), TeamDO (phase 3) | owner login + allow list in `remote.json` | TeamDO reach policy compiled to the host (`HostDO.setReachability` analog for tailnet logins) |

## 6. Identity and admission

- On accept, the listener has the peer's tailnet address. It refuses at once when the address
  is one of the host's own tailnet addresses (a process of another OS user on the host would
  otherwise be identified as the host's node and owner).
- WhoIs (phase 1: `tailscale whois --json <addr>`; the CLI handles each OS's LocalAPI
  transport: Linux Unix socket, macOS app or standalone port with its same-user proof,
  Windows named pipe). Result: login, node name, tags.
- Admit when:
  - the login equals the owner and the node is not tagged; or
  - the login is in the allow list (`cmux host allow <login>`, explicit, full access, printed
    warning).
- Tagged peers (CI runners, servers) have no login; they are never admitted in phase 1.
- Owner: `--owner <login>` when given; else the host node's own login (untagged node).
  A tagged host has no login: `enable` refuses without `--owner`.
- Mapping to the cmux account (phase 3): the host's enrollment stores the tailnet login next
  to the account; a client signed in as account U is shown hosts whose owner login is one of
  U's verified emails. Until then the mapping is the tailnet login itself.
- No anonymous mode, no plain non-tailnet listener, no `--insecure` flag.
- Teammate access (scoped, consented grants for an allowlisted login, audit log): see
  [teammate-access-DESIGN.md](teammate-access-DESIGN.md).
- Admission reply is a single JSON line; a refused peer learns only `not_allowed`.

## 7. Wire

TCP on each tailnet address of the host, port 7319 (override with `--port`, stored in
`remote.json`). The client sends one preface line, the host answers one line:

```
client: {"cmux_host":1,"op":"probe"}
host:   {"ok":true,"host":{"name":"build-box","os":"linux","version":"…","session":"main","owner":"…","access":"owner"}}

client: {"cmux_host":1,"op":"connect"}
host:   {"ok":true,"access":"owner"|"allowed"}   then raw daemon protocol both ways (the daemon's Unix socket)
host:   {"ok":false,"error_code":"not_allowed"|"session_down"|"bad_preface"}   then close
```

The preface has a 5 s read bound and a 4 KiB cap. The probe needs the same admission as
connect, so discovery never shows a host the caller cannot use.

`cmux host dial <host> [--port N]` connects, sends `connect`, prints the DaemonBridge dial
line on stderr (`{"ok":true,…}` / `{"ok":false,"error_code":…}`) and splices stdin/stdout.
The Mac app uses it as `DaemonEndpoint.bridge`, the same contract as `cmux link dial`.

## 8. Host lifecycle (CLI)

| Verb | Effect |
| --- | --- |
| `cmux host enable [--owner L] [--session S] [--port N] [--no-service] [--no-spawn]` | checks tailscaled and the owner, writes `<state>/host/remote.json` (0600), installs and starts the per-user service (`--no-service`: config only), prints status |
| `cmux host disable` | stops and removes the service, sets `enabled: false` |
| `cmux host status [--json]` | config, service state, tailnet addresses, owner, allow list, session socket. On a Cloud machine whose supervisor status file exists, it stays the supervisor's status (unchanged contract); `cmux host status --remote` always shows remote hosting |
| `cmux host serve` | the listener (what the service runs); foreground |
| `cmux host allow <login>` / `deny <login>` | edit the allow list; the running listener rereads the file on each connection |
| `cmux host list [--json] [--all]` | discovery: online tailnet peers (owned by the caller's login, or tagged), probed in parallel with a 1.5 s connect bound; `--all` also lists peers that did not answer, with the reason |
| `cmux host dial <host>` | the bridge (section 7) |

Services: macOS `~/Library/LaunchAgents/com.cmuxterm.host-remote.plist` (launchctl
bootstrap gui/UID, KeepAlive on failure); Linux `~/.config/systemd/user/cmux-host-remote.service`
(`systemctl --user enable --now`; root installs `/etc/systemd/system/cmux-host-remote@<user>`
is not done: hosting runs as a user, never root; headless boxes need `loginctl enable-linger`,
which `enable` prints); Windows a per-user Run value `cmux-host-remote` under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (`cmux host serve-detached`, no
admin rights; `enable` also starts it at once as a detached, windowless process).

The session: `--session` names the daemon session to expose (default: the CLI default
session). `serve` runs `cmux --session S --json daemon ensure` for the socket. With
`--no-spawn` (the Mac app passes it for its own session), `serve` never starts a daemon, it
only connects, and answers `session_down` when the app is not running.

## 9. Clients

- CLI: `cmux host list`, `cmux --session <host>` federation later (`cli/federation.rs` has no
  remote transport yet).
- Mac app (phase 1b): `RemoteHostSource` runs the bundled `cmux host list --json` at launch,
  activation and sidebar open (no timer); each listed host becomes a `MachineRegistry` entry
  with route `.host(name)` and `DaemonEndpoint.bridge = cmux host dial <name>`. The sidebar
  shows it as a machine section (`SidebarMachine.Kind.server` look, title = host name, status
  from the link). The section draws even when the list is flattened by computer
  (`sidebar.groupByComputer` off), because a remote host is a group, not a row decoration.
  Settings: Accounts > Machines gains "Remote hosting" (toggle `remoteHosting.enabled`,
  status line, owner, "Allow a teammate…"). The toggle calls `cmux host enable --no-spawn
  --session <app session>`; the MDM `remoteHosts` kill switch hides both.
- iOS: the same shape as cnx's Mac list: a remote host is one more machine in the mixed inbox
  with its workspaces tagged by host; an offline or unreachable host folds into one line. The
  phone reaches the host directly when it is on the tailnet; otherwise it needs the HostDO
  path (object-sync phase 3/6). No Swift sync logic: the phone uses the Rust mirror.

## 10. Install

- `curl -fsSL https://cmux.com/tui/install-static.sh | CMUX_HOST=1 sh`: the existing static
  installer picks the target, downloads the manifest and the binary from `files.cmux.com`,
  verifies SHA-256, installs `cmux`, then runs `cmux host enable` (`CMUX_HOST_OWNER=<login>`
  for a tagged box). The script change reaches cmux.com only after a main merge; until then
  feature-branch users run the script from the branch. Without tailscaled it stops with the reason in
  phase 1; phase 2 downloads `cmux-tailnet` and prints the sign-in URL, or uses
  `CMUX_TAILNET_AUTH_KEY_FILE`.
- Windows: `$env:CMUX_HOST=1; irm https://cmux.com/tui/install-static.ps1 | iex` does the
  same with `Get-FileHash` and the Run entry. Windows binaries are published only under
  `cmux-tui-windows/<sha>` today, with no `latest` manifest (open).
- macOS app users: Settings toggle (above), or `cmux host enable` from the app's bundled CLI,
  or the config key in `~/.config/cmux/cmux.json` for managed fleets.

## 11. Security

- Threats: a tailnet peer that is not the owner (refused by WhoIs), a tagged CI node (refused),
  another OS user on the host (refused by the self-address rule; the daemon's socket is 0600
  and same-user checked), a process on the owner's own laptop (admitted: tailnet identity is
  per node, the same trust as the owner's SSH key on that laptop; phase 2 can add the cmux
  device key from `cmux-remote` enrollment as a second factor (open)).
- The listener binds only tailnet addresses (100.64.0.0/10, fd7a:115c:a1e0::/48), never
  0.0.0.0. The existing `private_listen_address` rule in cmux-server-core agrees.
- WhoIs failure (tailscaled down, CLI missing) refuses the connection.
- The allow list grants full access and says so; restricted teammate access waits for the
  remote-entry share gate (server-reach 3.1 item 4).
- Logs carry login and node name, never tokens. No secret is stored by phase 1.

## 12. Phases

| Phase | Work | Done when |
| --- | --- | --- |
| 1a | Rust: `cmux host enable|disable|status|serve|dial|list|allow|deny`, admission, services, install scripts | owner admitted and a stranger refused on a Linux host and a Windows host; dial carries `list-workspaces` |
| 1b | Mac app: remote host sections via `cmux host list` + dial bridge; Settings toggle | a tagged app shows a remote Linux host's workspaces as one sidebar group |
| 2 | `cmux-tailnet` helper (tsnet): sign-in URL, auth key, attested identity preface; install script fallback | a fresh VM with no Tailscale joins with an auth key and serves |
| 3 | object-sync: `host.enroll` with `reach.tailnet`, account-synced host list, HostDO replica of sessions | a second Mac shows the host without discovery; host off shows `offline since` |
| 4 | teammate share gate (restricted remote entry), cmux device key second factor | a teammate sees only shared workspaces |

## 13. Conflicts with object-sync

1. Host identity. Object-sync section 9 makes the host an install (`inst_…`, kind `daemon`)
   enrolled through PairingDO, with cmux WireGuard keys and HostDO admission compiled by
   TeamDO. Phase 1 uses the tailnet node identity and a local allow list instead, with no
   account. Resolution: phase 3 enrolls the host into the account and records its tailnet
   node next to the install; TeamDO becomes the source of the allow list and pushes it to the
   host. Until then the local file is the policy and there is no account-side record. This is
   a second identity system for the same machine for one phase; it is deleted (moved) in
   phase 3, not kept as a twin.
2. Transport. Object-sync section 8 makes `HostDO` the control path and keeps a direct path
   only for live bytes. Remote hosts send commands (not only bytes) directly to the host
   daemon over the tailnet. No conflict in ownership (the daemon is the home of those
   objects, so a direct op is an op to the home), but there are two control paths to one
   home. Resolution: the direct path is legal because it reaches the single writer; HostDO
   forwards ops to the same writer when there is no direct reach. Both carry the same
   daemon protocol frames, so the client state machine is one.
3. Discovery vs directory. Object-sync's host list is TeamDO; remote hosts discovers tailnet
   peers. Resolution: discovery only proposes candidates; in phase 3 the directory is the
   list and discovery feeds `host.enroll`.
4. No replica in phase 1: an offline remote host shows "unreachable", not its last state.
   Object-sync R4 is met only after phase 3.
5. Two service installers. `cmux server install` (cmux-server crate) already writes systemd
   and launchd units that run `cmux host run`; `cmux host enable` writes its own per-user
   units for the listener. They do different jobs today (daemon owner vs tailnet listener),
   but a host can end with two units. Resolution: when the server lane's supervisor owns the
   daemon on a host, the listener becomes one more role of that supervisor and
   `cmux host enable` writes no unit of its own.
6. Discovery scans the tailnet (object-sync 5.2: "no client scans the network"). Phase 1 asks
   `tailscale status` for the caller's own and tagged online peers and probes only those,
   only when a client asks. This is a pre-account fallback. Once phase 3 lands, the list is
   the TeamDO directory, and the probe only proves reach and fills `reach.tailnet`; it is
   never how a client learns that a host exists. The host record (`host_…` in `team:<t>`) is
   the object and its HostDO is its live part, as 5.2 fixes.


## 14. Verification record

Phase 1a, 2026-10-19 (Linux x86_64, portable release build of the branch):

- Real tailnet, two disposable VMs with ephemeral single-use keys: a tagged host with
  `--owner`, an untagged client of the owner login. `cmux host list` showed the host with
  `access: owner` (real WhoIs); `cmux host dial` returned the ok dial line and the host
  daemon answered `identify` and `list-workspaces` through the tailnet. The listener bound
  only the node's tailnet IPv4 and IPv6 addresses.
- Fake tailnet (a `tailscale` stand-in through `CMUX_TAILSCALE_BIN`, Linux network
  namespaces for 100.x peers): owner admitted; another login, a tagged node, a node shared
  in from another tailnet and the host's own address refused with `not_allowed`; `allow`
  admits as `allowed`, `deny` refuses again; `dial` refuses another user's machine and a
  non-tailnet address before it connects.
- Found and fixed by these runs: a detached start returned before the listener was bound
  (now a readiness pipe); `enable` failed where there is no systemd user manager (now a
  detached start with a note); a detached start through a `cmux -> cmux-tui` link ran the
  wrong CLI surface (now argv[0] `cmux`).
- Not yet verified: macOS launchd and Windows Run-entry services on a fresh machine; the
  Mac app sidebar (phase 1b).
