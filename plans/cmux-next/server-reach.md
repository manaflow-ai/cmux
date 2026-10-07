# cmux next: the `server` reach (a paired server's Chief session in the sidebar)

Status: G1, built on branch feat-cmux-next-chief-server-reach (spec proposal; the coordinator owns the spec).
Related: data-model.md 1.1-1.2 (sessions, ownership), server.md 6 (pairing), transport.md 12 and 15 step 5 (overlay), state-ownership.md.

## 1. What it does

A Chief placed on a paired server (`chief.brain_place {host, install}`, set by Add Server with "Run my Chief on this server") runs headless there: the brain's own cmux-tui daemon (`~/.cmux/brains/chief/daemon/cmux.sock`, optchat-chief `deploy/brain/install.sh`) owns the workspaces it opens for subagents. The app now adds that daemon's session to `MachineRegistry` as a fourth reach next to local, SSH and Cloud VM. Its sidebar section is named after the server (`Host.name`) and lists the brain's workspaces, so a subagent workspace appears as soon as the brain creates it.

Ownership (data-model.md 1.2): the workspaces, their layout and terminals belong to the brain's session (shared state on its home daemon). The registry record, sidebar order and groups for it are personal state in the app's home session, as for any remote session. The app writes nothing personal to the server.

## 2. Which servers show

`ServerReachService` (app) reads, as the signed-in user, `chief.list` (which servers run a chief) and `team.hosts.list` (which servers are still paired). A server shows while some chief of the user is placed on it and its host is in the directory (kind not `device`). Reads happen at sign-in, when the app becomes active, after Add Server places a chief, and on `refresh()`. There is no timer. A failed read changes nothing.

- Removing the pairing (`server.revoke` deletes the host) or moving the chief away closes the session, removes it from `MachineRegistry` and forgets its registry record (`forget-session`, with its personal organization). It is picked up at the next read (activation or sign-in); a revoke from another device is not pushed yet (open item 6.3).
- Sign-out closes every server session; records stay for the next sign-in's read to keep or forget.
- Launch: records the registry holds (written by `SessionRegistrar` after the first connect, transport kind `server`) come back before the first read, so an offline server shows at once.
- Offline: connecting never blocks the UI. The header shows unreachable, sign-in failed or offline from the link; there is never an install offer (the brain's binaries belong to its installer).

## 3. Routes

The registry transport is `{kind: "server", host, install, name, route, ...}`, never a secret.

| Route | When | How |
| --- | --- | --- |
| `ssh` (dev-only) | the server is another machine | the bundled `cmux-tui remote connect ssh://<server> --session chief --remote-binary ~/.cmux/brains/chief/bin/cmux-tui --remote-mux-socket ~/.cmux/brains/chief/daemon/cmux.sock --no-install`; on the server `remote-link --stdio --mux-socket <brain socket>` starts a sidecar that talks to the brain's daemon over its Unix socket as the same user. With an explicit `--mux-socket`, remote-link only attaches: a down brain is an error, never a second daemon at the brain's path. The destination is the server's name as a DNS label (`cmux-lawrences-Mac-mini` -> `cmux-lawrences-mac-mini`), resolved by the user's `~/.ssh/config` and tailnet DNS. |
| `unix` | the server is this Mac (this Mac's link install, from `cmux link show`, equals the `brain_place` install, or with no link install its short host name equals the server's name; and the brain socket exists here, a stat, nothing is read) | the app's `DaemonService` connects to the brain's socket directly; a socket that answers as this Mac's own home daemon is refused |

Why SSH now: it is the existing trusted carrier (the remote daemon sees a local Unix client of its own user, full tree, as the coordinator and the remote ACP agent G2 agreed), it works today, and the pairing transport for clients to reach a server (transport.md 15 step 5) is not built. **SSH is a dev-only carrier**: it needs the user's own SSH login on the server, which pairing does not give. Real users' paired servers need the overlay route below; only the route changes, not the reach, the registry record or the sidebar.

### 3.1 What the overlay route (transport.md 15 step 5) needs for servers

1. Backend: a host-scoped connect read and dial token for a paired server (today `cloud.machine.connect_info` and `cloud.machine.link_token` answer only for Cloud machines; `CloudConnectInfo.machine` is required): peer `{wg_public_key, overlay_address}`, the server's chosen `HostDO` relay object, candidates, the epoch, and a token minted for the server's owner (install principal, owner-only grant) with audit.
2. `TeamDO`: the server's peer map and `HostDO.setReachability` compiled for the owner's device installs (`autogroup:self`; default network policy has no `src: tag:server` rule, which stays), and relay tickets from `UserDO` for client sockets.
3. Server: the `link` role of `cmux host run` on a paired server: its WireGuard key from pairing, the hibernating host socket to `HostDO`, the overlay listener on 4100, `hello` token check (deny by default, `cmux-link` `token`), and a peer map pushed by `TeamDO`.
4. The trusted-owner path: a `hello` from the server's owner user (not an agent, not a team member) is handed to the session over the trusted local path (full tree, like the SSH carrier), while every other principal keeps the stamped remote entry (conversations only, `ConversationGate` default deny). This is a policy decision for the coordinator; without it the overlay gives only the remote entry and the sidebar cannot show the brain's workspaces.
5. Which daemon: the link role must reach the brain's daemon (today a separate launchd daemon at the brain path), or the brain must run inside the server's `session` role daemon. One of the two must be decided with optchat-chief (a9bd3e7da0cb7535a).
6. Client: `cmux link` dials a server host over `do_relay` first (then `direct_lan` and `direct_wan` as built) and returns a local Unix socket that speaks the daemon protocol; `ServerReach.Route` gains `overlay {host}` and `ServerMachineSession` starts the daemon on that socket. The in-process WireGuard upload limit (transport.md 0 item 10) must be fixed before it carries terminals.
7. Revocation push: `server.revoke` already removes the host; the client should also get a `cloud.link.changed`-style event so a shown server leaves at once instead of at the next activation.

## 4. Remote relay policy analysis (AGENTS.md "Remote CLI relay")

This change adds no relay and no allowlist entry. `RemoteRelayPolicy.allowed` stays empty (`denyAll`).

- Local command or content execution: the app dials the server; nothing on the server gets a connection back to this Mac. The ssh the app runs keeps `SSHCommandLine.enforcedOptions` (no agent, X11 or port forwarding, `ClearAllForwardings`, `BatchMode`), so the server cannot reach this Mac's control socket or local resources. Browser records from the server's tree load only through `RemoteRelayPolicy.remoteBrowserURL` (http, https, about:blank), as for SSH machines. No method spawns or respawns a terminal on this Mac for the server: terminals in the server's workspaces run on the server (data-model.md 1.2a).
- Access to unowned objects: commands from the app for a server's workspace, pane or tab go only to the server's daemon (`MachineRegistry` resolves each object to exactly one daemon by identity), so the server's session never receives ids of this Mac's or another machine's objects. The `unix` route refuses a socket that answers as this Mac's home daemon.
- Local-state exposure: the server receives only what the app sends to any attached client of its tree. Personal state (registry, order, groups, windows) stays in the home session (data-model.md 1.2c). The registry transport holds routing only, never a token, key or password; the SSH account is the user's own OpenSSH identity.
- Command-bearing params: none are added; the remote command line is built from validated plain words (`RemotePath.isSafe` on the binary, socket and state dir, `SSHDestination` parsing), and the server-side `remote-link` rejects anything but shell-safe words.
- Policy tests: `RemoteRelayPolicyTests` (unchanged, deny by default), `ServerReachTests` (unsafe sockets and foreign ids refused, transport without secrets), `SSHCommandLineTests` (the socket flag only when named), Rust `explicit_mux_socket_is_attach_only` and `remote_link_command_attaches_to_an_explicit_mux_socket`.
- G2 (remote ACP attach) adds agent-session verbs to the daemon for trusted Unix connections only; they reach the server through this trusted path and stay off any remote relay allowlist.

## 5. Tests and proof

- Rust (Testbox): remote connect `--remote-mux-socket` reaches remote-link `--mux-socket`; remote-link with an explicit mux socket starts neither a mux owner nor a sidecar when the daemon is down.
- Swift: `ServerReachTests` (model), `ServerReachAppTests` (discovery, sidebar section with the brain's workspaces under the server name, revoke, chief moved, failed read, offline status), `SSHCommandLineTests`.
- Live proof: a test brain on cmux-lawrence-2 itself (own brain home and daemon, `unix` route), paired by Add Server in a tagged app on the same host, a test chief placed on it, a subagent workspace created by the brain, visible in the sidebar under the server's name. The real cmux-lawrence brain is not touched.

## 6. Open items

1. The overlay route (3.1).
2. A per-server route override in the UI (today the record's route comes from the server's name; a user whose SSH alias differs edits `~/.ssh/config`).
3. Push removal on `server.revoke` from another device (3.1 item 7).
4. The SSH destination follows `Host.name`; whoever can rename the host moves where the app's SSH (with the user's identity) goes. The overlay route removes this; until then it is the owner's own name.
5. Two names that reduce to the same DNS label (`Lawrence's Mac`, `lawrences-mac`) both match this Mac; the `unix` route only ever opens this Mac's brain socket, so only the section title can be wrong.
6. remote-link reuses a live sidecar of the `chief` carrier session without checking which mux socket it serves; only the server reach starts that session, always with the brain socket.

## 7. Overlay route plan (next G1 step; protocol parts go through the coordinator WINDOW)

What exists: `cmux link` slice 1 (cmux-tui `link/`, crate `cmux-link`) dials paired peers directly over `cmux-wg` (`cmux link peer add` records, written by `cmux server pair`), sends a `ServiceHello {service: daemon}` and hands the stream to the session daemon's remote entry with a verified stamp (ClientTransport::Remote, conversations only). `HostDO` relays datagrams (first slice). Cloud VMs use `connect_info` plus `link_token`.

Steps, smallest first:

1. App route `overlay {host}`: `ServerMachineSession` asks the app-side link (`link.dial {host, service}` on the link's local socket) for a stream and starts `DaemonService` on a local socket that forwards it, the same shape as `remote connect` today. No protocol change. Works at once for a server on the same LAN (direct path).
2. Trusted owner service (WINDOW: `cmux-link` dial types, daemon entry): a new `Service::OwnerSession`. The receiving link accepts it only when the stamp's user is the server's owner (the pairing record's `user`, later the `TeamDO` peer map) and the stream comes from one of that user's device keys; it hands the stream to the session's local trusted entry (full tree, as the SSH carrier gives today). Every other principal keeps `Service::Daemon` (remote entry). Policy analysis as in section 4, plus: the owner check is the authorization, the WireGuard key only reachability (transport.md 0 item 7).
3. Which daemon (with optchat-chief): the server's link hands `OwnerSession` to the brain's daemon socket named in `server.json` (a `session_socket` field), so the brain keeps its launchd daemon; or the brain moves into the `session` role daemon of `cmux host run` (hq-6d's role supervisor). RECOMMEND the `server.json` field: no brain migration.
4. Relay path: the app link dials `do_relay` through the server's `HostDO` when no direct path answers (relay tickets from `UserDO`, reachability compiled by `TeamDO` for the owner's devices). Backend work in the backend lead's DO base.
5. Peer map instead of the pairing file: `TeamDO` pushes the owner's device keys to the server and the server's key to the owner's devices (transport.md 15 step 4).
6. Remove the SSH route for servers once 1-4 are live; keep it only behind a dev setting.
