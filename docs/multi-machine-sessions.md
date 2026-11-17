# Working across your own machines

Status: Draft design, October 2026. The [next PRs](#next-prs) section lists
the order and what's in review.

A user with a personal Mac, a Linux dev VM and a second build box should be
able to say "start Claude in `~/src/api` on cosmic-gray" from any of them and
have it happen. Today that takes Remote Login, hand-copied SSH keys, a
tailnet policy edit the user may not be allowed to make, a per-app SSH
connection entry, and, when the policy can't change, a hand-run reverse
tunnel. This doc proposes one machine list, one way to ask a machine to start
a session, a cmux-owned path back to the user's own machine that opens no
ports, and per-host trust that keeps a less trusted host from gaining the
user's reach.

## What happened on 2026-10-18

The motivating setup, kept here because each step is a design input:

| Machine | What it is | Tailnet identity |
| --- | --- | --- |
| cosmic-gray | Personal Mac, Tailscale GUI app, user `leoli` | Owned by the user's personal login |
| Huge Blue | Freestyle VM (KVM guest, Ubuntu 24.04), user `leo` | Tagged device `tag:huge-blue` |
| cmux16 | Linux build host | Saved SSH connection |

1. Both machines were on the team tailnet and `tailscale ping
   cosmic-gray` worked over DERP.
2. SSH failed: port 22 on the Mac was closed. The GUI Tailscale app can't
   run Tailscale SSH on macOS, so Remote Login had to be turned on by hand
   and Huge Blue's ed25519 key added to `authorized_keys`.
3. It still failed. TSMP ping worked but ICMP and TCP:22 to the Mac's
   100.x address timed out: the tailnet policy gives `tag:huge-blue` no
   access to the user's devices. The user can't edit that policy.
4. What worked was a reverse tunnel from the Mac over the direction that
   already works (Mac → Huge Blue):
   `ssh -N -R 2222:localhost:22 leo@huge-blue`, then `ssh -p 2222
   leoli@localhost` on Huge Blue, narrowed with `authorized_keys` options.
   That port is open to every local user on Huge Blue.
5. The agent app still needed cosmic-gray added as an SSH connection by hand
   before a session on Huge Blue could start work there.

Steps 3 and 4 are the general case, not an accident: the user's own machine
is usually the one that can dial out but can't be dialed.

## What cmux already has

Most of the pieces exist; they aren't joined up.

- **Device registry.** `devices` / `device_app_instances` in PlanetScale
  ([migration](../web/db/migrations/20260608055850_device_registry/migration.sql)),
  read and written by `RemotesClient` (`GET/POST/DELETE /api/devices`,
  `Packages/macOS/CmuxCloud/Sources/CmuxCloud/Network/RemotesClient.swift`)
  behind `remotes.list/add/remove` and `cmux remotes`. Today it registers
  remote Macs for the iOS device list; routes can come from
  `SystemTailscaleStatusProvider` (`tailscale status --json`).
- **Presence.** [Presence service](presence-service.md): live online/offline
  per `(deviceId, tag)`, team scoped and owner bound. A hint, not authority.
- **cmux-tui remote runtime.** `cmux-tui/crates/cmux-remote`: a daemon with
  its own identity, five-minute enrollment invitations, approval, revocation,
  `known-daemons`, and iroh / relay / WebSocket / SSH / Unix providers
  ([remote.md](../cmux-tui/docs/remote.md)). `machine-agent` already shares a
  machine through Cloud with an outbound-only connection
  ([machines.md](../cmux-tui/docs/machines.md#share-a-local-machine-through-cloud)).
  The native relay (`cmux-relay`, slot tickets for register and connect) and
  the Cloudflare Durable Object relay carry a session between two machines
  that both dial out. One gap: "every enrolled device has full daemon
  authority, including all workspaces".
- **`cmux ssh` and the CLI relay.** [Remote SSH spec](remote-daemon-spec.md):
  `cmuxd-remote`, a reverse-forwarded, HMAC-authenticated relay so `cmux` on
  the remote can call the Mac app, and a default-deny method allowlist in
  `RemoteRelayCommandPolicy` / `RemoteRelayAuthorizationPolicy`
  (`Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/`).
- **Moving sessions.** `cmux session move <id> --to <ssh-destination|local>`
  and acpmux host-qualified session receipts.
- **Routing.** [Machine router](internal/machine-router.md) and the
  [handoff and routing RFC](rfcs/agent-runtime-handoff-and-routing.md),
  whose Phase 4 is cross-machine and presence integration.

The missing parts: Linux hosts aren't in the device list as first-class
targets, nothing asks a machine to start an agent session by name, nothing
carries a request from a host back to the user's machine, and nothing scopes
what one machine may do on another.

## Naming and discovering machines

**One list: "My machines".** It comes from the device registry, scoped to the
signed-in user's personal account, not the selected team. A machine's
identity is its `cmux-remote` daemon key, the key `remote enroll` already
binds and `known-daemons` already pins, on the Mac and on Linux alike. The
display name ("cosmic-gray", "Huge Blue") is a label on that record.
Hostnames, Tailscale names, 100.x addresses, relay slots and
`~/.ssh/config` aliases are reachability hints attached to it; none of them
authorizes anything.

**Discovery sources only suggest; enrollment adds.** During setup cmux reads
three sources and offers what it finds:

1. Registry machines the user already enrolled from another device.
2. `tailscale status --json` peers. Show the user's own devices first, then
   tagged devices; label which is which, since that decides reachability
   (below).
3. Concrete `Host` entries from `~/.ssh/config` (the cmux-tui picker already
   parses these, including `Include`).

A suggestion becomes a machine only after enrollment (`remote enroll` and
approval on the other machine) binds its key. A matching Tailscale name or a
registry row never grants access by itself.

**Linux joins the same list.** The cmux-tui daemon registers a device row with
its daemon key and `tag` = session name, and heartbeats presence. Huge Blue
and cmux16 then show up beside cosmic-gray everywhere: the Mac sidebar, the
TUI machine rail, and the iOS device list.

**Per-machine facts live on the record**, learned once at setup and
refreshed on connect: login user (`leo` vs `leoli`), home path, OS, which
transports worked last, and whether the machine is a VM. No more
user-maintained mapping.

## First-run setup: "Add a machine"

One flow in Settings › Devices and `cmux machine add`, run from either side.
Every probe is non-destructive, and every step that changes the system is
shown before it runs.

### Steps

| Step | What cmux does | Needs the user? |
| --- | --- | --- |
| 1. Pick | List suggestions from the three sources; the user picks a machine or pastes a pairing code. | Picks. |
| 2. Pair | Exchange cmux endpoint keys: a QR or one-time code shown on the other machine (existing enrollment invitation), approved there. | Approves on the other machine. |
| 3. Probe routes | From each side, try each transport toward the other (table below) and record what worked. | No. |
| 4. Fix or route around | If a direct path is blocked, explain why and offer the fix *or* use the reverse/relay path, which needs no change. | Only to apply a fix. |
| 5. Map identity | Read login user, home and OS over the paired channel; store them on the record. | No. |
| 6. Set trust | Choose what each machine may do on the other ([trust tiers](#per-host-trust)). Default: nothing back toward the user's personal machine. | Chooses. |
| 7. Register | Write the registry row; optionally export a `Host` alias to a cmux-owned `~/.ssh/config.d/cmux` include that the user wires up once. | Confirms the include. |

A paired connection through the cmux relay works without SSH, Remote Login or a
tailnet policy change. SSH setup (keys, Remote Login) is offered only when the
user wants a plain SSH login as well, for example for tools outside cmux.

### Reachability probe and diagnosis

The probe distinguishes the failures that look the same from a terminal:

| TSMP `tailscale ping` | TCP to :22 | SSH auth (`BatchMode=yes`) | Diagnosis shown |
| --- | --- | --- | --- |
| fails | – | – | Not on the same tailnet, or the peer is offline. Use the cmux relay path. |
| works | refused (RST) | – | The tailnet allows it; SSH is off on the target. On macOS: turn on Remote Login. |
| works | times out | – | **The tailnet access policy blocks this direction.** Show the rule that would allow it, and use the reverse or relay path now. |
| works | connects | rejected | The key isn't authorized for that user. Offer the key step. |
| works | connects | works | Direct SSH OK. |

"TSMP works, TCP times out" is the case from 2026-10-18. cmux never edits a
tailnet policy. It shows the change for whoever can make it, for example:

```jsonc
// grants (preferred): let this tagged host reach one user's devices on 22
{ "src": ["tag:huge-blue"], "dst": ["user@example.com"], "ip": ["tcp:22"] }
```

and says the reverse/relay path is already working without it.

### Steps that need the user

- **macOS Remote Login** (only for plain SSH): System Settings › General ›
  Sharing › Remote Login. The command-line form (`sudo systemsetup
  -setremotelogin on`) needs sudo and Full Disk Access for the terminal, so
  cmux links to the pane; it doesn't run it.
- **Tailscale SSH**: not available with the macOS GUI app. On Linux,
  `sudo tailscale set --ssh` needs sudo plus an `ssh` rule in the tailnet
  policy. cmux suggests it on Linux targets and never on the Mac app variant.
- **`authorized_keys`**: cmux generates a dedicated per-pair key
  (`~/.ssh/cmux_<machine>_ed25519`) and shows the exact line it will append,
  with `from=` and `no-agent-forwarding,no-port-forwarding,no-X11-forwarding`
  options; the user confirms.
- **Tailnet policy edits**: shown, never applied.

### Tagged vs user-owned joins for personal dev hosts

A tagged device (Huge Blue's `tag:huge-blue`) has no owner after
registration. Default policies give tags less access, and the key doesn't
expire with the user's login. That's right for shared or CI hosts and is why
it couldn't reach the Mac. A user-owned join gets the user's own-device
access, but the VM can then reach every device the user owns on the tailnet
at the network level. For a personal but less trusted VM, cmux recommends
staying tagged and using cmux's paired channel for the specific things it
needs, rather than widening network access. The setup screen says which kind
of join each machine has, and why it matters.

## Asking a machine to start a session

```sh
cmux machine run cosmic-gray --agent claude --cwd ~/src/api [--prompt -]
```

and the same action from the sidebar's "New session on…" menu and from an
agent's own `cmux` call.

1. **Resolve** the name to a registry record and endpoint key. Ambiguous
   names fail; nothing falls back to DNS.
2. **Pick a route** in order: an already-open cmux connection to that machine
   (including the reverse channel below), SSH if the record says it works,
   then the cmux relay. Presence is only used to
   say "offline" early.
3. **Send a typed request**, never a command string:

   ```text
   machine.session.request {
     request_id      // UUID, idempotent
     agent           // closed enum: claude | codex | opencode | pi
     cwd             // must match one of the target's allowed folders
     prompt?         // data, delivered through agent hooks, never as keystrokes
     model?, effort? // validated against the target's own options
   }
   ```

   The target's cmux chooses the launcher from its own configuration. Command
   fields (`command`, `initial_command`, `initial_input`, launcher overrides,
   env) don't exist in the schema, so nothing can sneak one through.
4. **The target admits or refuses**, using its own trust record for the
   caller ([below](#per-host-trust)). If the grant says "ask", the target shows
   a prompt to the user there, or on a device the user is using, and the
   request waits with a bounded deadline.
5. **Reply with a receipt**: `{ machine, workspace_id, surface_id, session_id,
   state }`, the host-qualified receipt acpmux already uses. The caller's
   sidebar shows the session under that machine, and `cmux session move`
   can move it later.

Starting a session on Huge Blue from cosmic-gray is the easy direction: the
Mac already trusts the host it SSHes into. The request still goes through the
same typed method so there's one path.

## Reaching the user's machine from a host

Use what already works: the connection the user's machine opened. When
cosmic-gray runs `cmux ssh huge-blue` or opens Huge Blue in the machine rail,
that connection already carries the HMAC-authenticated CLI relay back to the
Mac. The **back channel** is a new, narrow method family on that relay.

- **On the host**, cmux creates a per-connection Unix socket in an owner-only
  directory (`$XDG_RUNTIME_DIR/cmux/back/<slot>.sock`, dir `0700`, socket
  `0600`), checks the peer's uid with `SO_PEERCRED` / `getpeereid`, and
  still requires the relay's per-slot HMAC credential. That replaces the
  shared loopback TCP port that `ssh -R 2222:localhost:22` exposes to every
  local user. It's torn down when the connection drops or the workspace
  closes, and a reconnect makes a new slot and credential.
- **Over the wire**, back-channel requests ride the existing relay stream, so
  there's no second SSH process, no `-R`, and no dependence on
  `AllowStreamLocalForwarding`.
- **On the Mac**, the relay server dispatches only `machine.session.request`
  and read-only `machine.self.describe`, and only for a host whose trust tier
  allows them. Everything else stays denied.

**When no connection is open** (Huge Blue wants to start work on the Mac
while the user is away from it), the host connects through the cmux relay.
The Mac keeps an outbound registration there, the same outbound-only shape as
`cmux machine-agent`, so no port opens and no tailnet change is needed. The
relay only forwards bytes: the host still authenticates to the Mac's pinned
daemon key, and the same enrollment and trust tier apply. Iroh could later
add a direct path for latency (`cmux-remote` already has an Iroh provider),
but nothing here depends on it. If the Mac is asleep or offline, the
request fails with "cosmic-gray is offline". Waking it is out of scope.

**Plain SSH back to the Mac** (the 2026-10-18 workaround) stays a
user-configured option for tools outside cmux, not the built-in path. If cmux
manages it at all, it tunnels to a `0600` Unix socket on the host, not a TCP
port, and only at the "shell" tier below.

## Per-host trust

Reach is not symmetric. The user can do anything on Huge Blue. Huge Blue, a
VM the user doesn't control end to end, shouldn't be able to do the same on
the user's Mac. Each machine keeps its own trust record for every peer, set
only locally on that machine (never from the peer, never from the registry):

| Tier | The peer may | Default for |
| --- | --- | --- |
| **None** | See that this machine exists. | A personal Mac, toward any host. |
| **Ask** | Send `machine.session.request`; each one waits for the user's approval on this machine. | Offered first when enabling back-reach. |
| **Folders** | Start sessions without asking, but only for listed agents in listed folders (`~/src/api`, not `~`). | Hosts the user trusts for specific projects. |
| **Shell** | Open a terminal on this machine. | Never by default. Needs a separate security review before it ships (see below). |

The trust record holds the tier, the folder allowlist (realpath-resolved, no
symlink escape), allowed agents, an optional expiry, and whether the peer is
a VM. The setup flow asks about trust in the direction the user is setting up,
and defaults to None toward the user's personal machine.

**Audit trail on the target.** Every back-channel request, admitted or not,
is logged locally with time, peer, method, folder, agent and decision, and
shown under the machine in Settings › Devices. A session started by a peer is
labelled "Started by Huge Blue" in the sidebar. Revoking a peer, or dropping
its tier, closes its live back-channel slots right away.

## Security model

**Identity.** Machines are endpoint keys bound in the device registry to the
user's personal account. Names, IPs, Tailscale identities, presence rows and
SSH aliases are hints and never authorize. A peer is admitted only by key
possession (the `cmux-remote` Noise handshake against a pinned daemon key)
plus an enrollment the target approved.

**Authority is local and narrow.** An enrollment says two machines belong to
the same user. It doesn't say what they may do. The target's local trust
record decides that, and a peer can't change it. The cmux-tui daemon's
current "every enrolled device has full authority" becomes the Shell tier,
and paired machines start at None.

**Relay authorization rules** ([remote relay authorization](../skills/cmux-socket-policy/references/remote-relay-authorization.md)).
The back channel is a relay path, so the PR that adds it must answer the
three questions:

- *Does it execute commands or open content locally?* `machine.session.request`
  starts a local agent process, so the method is reshaped rather than
  allowlisted as-is. Its schema has no command-bearing params at all: the
  agent is an enum, the launcher is the target's own, the prompt is data
  delivered through hooks, and the cwd must be in an allowlist the user set
  on this machine. At the Ask tier, a local user action launches it, not the
  remote request. The general rule stays: `command`, `initial_command`,
  `tmux_start_command` and `pane_start_command` stay denied on every method.
- *Does it touch objects the remote doesn't own?* Requests can't name
  existing workspaces or surfaces. The created session is owned by this
  back-channel slot, and later calls are scoped to that ID set, using the
  same scoping as `RemoteRelayAuthorizationPolicy`.
- *Does it expose local state?* `machine.self.describe` returns only display
  name, OS and the allowed folder list for that peer. It doesn't list
  workspaces, sessions, windows or paths outside the allowlist.

The Shell tier is a terminal spawn on the Mac driven by a remote, which the
rules forbid allowlisting. It ships only after its own design and review, and
isn't part of the first PRs.

**Credentials never cross.** Stack bearer and refresh tokens, SSH keys and
agent sockets don't travel over the back channel. Agent forwarding stays
opt-in, as it is for `cmux ssh` today.

**Bounds.** Back-channel requests reuse the relay's connection cap, handshake
deadline and response bounds. Ask prompts expire after five minutes, and
admitted requests are idempotent by `request_id`.

**Residual risks.** A compromised host at the Folders tier can start agents in
the allowed folders with prompts it writes. That's the reason for the tier,
the folder scope, the audit trail and the default of None. The relay
operator sees connection metadata (which machines talk, when, how much) but
not content.

## Next PRs

Each is independently reviewable. Relay-touching PRs carry the full
authorization analysis and policy tests.

1. **Reachability doctor.** `cmux remote doctor HOST` runs the TSMP, TCP and
   `BatchMode` SSH probes and prints the diagnosis table above. No state
   changes. In review as manaflow-ai/cmux#21831.
2. **Linux in the device registry.** The cmux-tui daemon registers a device
   row keyed by its daemon key and heartbeats presence; `RemotesClient`
   lists Linux rows. Touches `web/` (BSL, CLA rules apply).
3. **Trust records and audit log** (`cmux-remote`, surfaced in the Mac app).
   Local-only per-peer tier, folder and agent allowlist, expiry, and an
   append-only audit log with a Settings › Devices view. Paired peers
   default to None. No new remote method yet. The `cmux-remote` store and
   `cmux remote trust` CLI are in review as manaflow-ai/cmux#22031; the
   Mac view follows.
4. **`machine.session.request` on a live connection.** The typed schema, the
   admission path through the trust record, and the receipt, behind a
   PostHog flag. First direction: client → host it's connected to.
5. **Back channel on the CLI relay.** Per-slot `0700`/`0600` Unix socket with
   a peer-uid check on the host; `machine.session.request` (Ask and Folders
   only) and `machine.self.describe` added to the relay policy with
   deny-case tests (unmapped IDs, command params, tier None, folder outside
   the allowlist, symlink escape). Includes live verification that a request
   from Huge Blue starts on the Mac only after approval.
6. **"Add a machine" flow.** Settings › Devices and `cmux machine add`:
   suggestions from registry, Tailscale and ssh_config; pairing; probe;
   identity mapping; trust; optional `~/.ssh/config.d/cmux` export and
   restricted `authorized_keys` line.
7. **Offline-of-connection route.** Host → Mac through the cmux relay, with
   the Mac registered outbound, when no cmux connection is open.
8. **`cmux machine run` and "New session on…"** in the sidebar and TUI rail,
   picking the route automatically, plus `session move --to <machine name>`.

Out of scope here: an Iroh direct path (an optional latency improvement
later), waking a sleeping Mac, the Shell tier, and team-shared
machines (this doc covers one user's own machines).
