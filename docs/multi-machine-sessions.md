# Your machines and phones, connected

Status: design, 2026-11-05. Replaces the October draft of this file. The
[PRs](#prs-in-order) section lists the order; each PR updates the
[status table](#status).

Leo, 2026-11-05:

> can you potentially propagate the app and the daemon onto a computer you
> already own? Or does the user have to have necessarily installed it on both
> previously? Like, can you SSH into it and then do it? Like, is there a
> formalized way where you can just say, like, okay, it's not even SSH, like
> it's an officially supported way to do this?

> if you own both machines, you can have one go to the other? ... you can send
> the app over and stuff, right? And then do stuff there.

> Carry the remote connectivity bit forward more like connecting to and from
> machines and controlling/being controlled by machines and phones too

> We need to have it end to end be as easy and ergonomic as ChatGPT
> desktop/ios

> Since we have our own rolled wireguard situation and some amount of prior
> art… we can prob get things very fast and reliable

## The experience

The bar is ChatGPT desktop and iOS: sign in, and your devices are there.

1. **A new Mac.** Install cmux and sign in with the same account (or, from a
   Mac that already has cmux, **Set Up cmux on Another Mac…** over SSH you
   already have). It appears in **My Machines** on every Mac and phone of that
   account within a second of signing in.
2. **First contact asks once, on the machine being used.** The first time
   cosmic-gray reaches Air Blue, Air Blue shows "cosmic-gray wants to use this
   Mac" with what it asks for, and the same card reaches the person's phone
   (a signed approval, as phone pairing already does). Allow pins
   cosmic-gray's identity key with the chosen grants. No code, no SSH, no
   Tailscale policy, no port.
3. **Then it just works, both ways.** From any Mac: the sidebar machine picker,
   **New Workspace on Air Blue**, **Continue on Air Blue** (moves the
   workspace with its chats and terminals), **Send This Build to Air Blue**.
   From the phone: the same machines, the same actions, and every approval
   card. From the CLI: `cmux machine air-blue send|run|move`.
4. **Approvals go where the person is.** A grant set to Ask shows its card on
   that Mac and on the person's phone, whichever answers first.
5. **What only a person at that Mac can do is said, never attempted.** Screen
   Recording and Accessibility, and a logged-in desktop to launch an app, are
   shown as one line with a button that opens the right Settings pane there.
6. **Everything is in Activity, on both ends.** Each machine lists what other
   devices did on it and what it did on them; **Remove** on either end ends it.

## One link for every device

The mobile link (`cmux-next-ios/rust/crates/cmux-mobile-link`, PROTOCOL.md) is
the transport for every pair of the person's devices, phone to Mac and Mac to
Mac (and Linux, when hostd runs there). It is the fastest and most tested path
cmux has:

- WireGuard (`cmux-wg`, userspace, a fresh key per session) with hole
  punching from host and STUN-reflexive endpoints, then TURN over UDP, then
  TURN over TLS on 443 when UDP is blocked; roaming keeps every byte
  (`tests/roaming.rs`); no backend relay ever carries data.
- Priority lanes (control, input, bulk) so a 2 GB build upload never delays a
  keystroke or an approval (`class_queue.rs`, the input lane).
- Signaling is the person's own hub (`team-hub.ts`, one Durable Object per
  user). It already admits a dial from any of the user's devices to any of
  their Macs (`admit`), and stamps the sender's device and user; no backend
  change is needed for Mac to Mac.
- Every signed-in Mac already runs `cmux-mobile-host` (hostd) with a warm
  signaling socket. A Mac dials through **its own** hostd (a new `dial`
  control request), so it never opens a second socket under its device id and
  every dial reuses warm signaling and cached ICE.

What this replaces as the way between the person's machines: SSH as the
default route, the `cmux link` overlay's "direct paths only, no relay" slice,
and iroh. SSH stays as a first-contact route and a fallback; see
[What changes](#what-changes-in-existing-code).

Speed targets, measured by `cmux-mobile-dial` and the demo below: link up
under 300 ms warm on the same LAN, under 1 s across networks; ping p50 under
5 ms on a LAN; bulk at the path's line rate (the WireGuard path is a smoltcp
TCP stream with 256 KiB buffers; raise the window for bulk channels if the
demo shows it bound).

## One identity and one list

- **A device is its hostd identity key**: a Secure Enclave P-256 key on a Mac
  that has one (as the phone's), a 0600 file key elsewhere. The device id,
  name, machine id, Tailscale name and SSH alias are labels and hints; none
  authorizes anything.
- **My Machines** is one list: the hub's `GET /v1/me/devices` (every Mac and
  phone of the account, with live presence) merged with what `cmux device
  list` already merges locally (acpmux peers, SSH config hosts, Cloud
  machines). One row per machine id; a machine reachable several ways shows
  once, with its best route.

## Pairing: first contact, then per-peer grants

Phone pairing already works this way (`pairing.rs`): the first channel of a
link is `auth`, the caller signs a fresh challenge with its identity key, and
hostd asks the app "Allow <device>?" unless the key is already approved.
Machines use the same `auth`, with `kind: "mac"` (or `"linux"`) and the
grants it asks for. Unchanged: the rate limits per device and per account,
the deny cooldown, and "a token alone reaches nothing".

Each machine keeps, for every peer, a local record (`DeviceTrust`, extended):

| Grant | The peer may | Phone default | Machine default |
| --- | --- | --- | --- |
| `view` | See this machine, its workspaces and chats, read files in chat roots | on (today's phone lanes) | on |
| `control` | Type into terminals, answer agents, open and close tabs and workspaces (today's phone lanes) | on (today) | Ask |
| `run` | Start agents and workspaces in listed folders (typed request; no command strings) | off | Ask |
| `install` | Install a cmux build it sends, signed by the cmux release key or by a build key enrolled here | never | Ask |
| `move` | Move a workspace in or out, with its chats, terminals' state and folder | off | Ask |

Ask means each request shows the approval card (here and on the phone);
**Always** on the card turns the grant on for that peer. Grants are set only
on the machine they protect, never by the peer, the hub or the registry. A
phone gets no `install` at all: a phone has no build to send, and installing
from a phone is not a lane a paired phone may have
([SECURITY.md](../cmux-next-ios/SECURITY.md)).

## Actions

All three are typed services on the link, refused unless the grant allows
them, and logged on both ends.

### Send a build (`install`)

`cmux machine air-blue send [--app PATH | --tag TAG]`, **Send This Build to
Air Blue**, or the sidebar row's menu.

1. The sender packs the `.app` (and its bundled `cmux` and hostd) as a
   deterministic tar (`--zstd`), and a manifest: bundle id, version, tag,
   arch, sha256 and size of the archive.
2. Signed by either:
   - **the cmux release key**: the build's codesign is Developer ID
     Manaflow, Inc. (7WLXT3NR37) and notarized; the receiver checks
     `codesign --verify --deep --strict`, the team id and `spctl -a` after
     unpacking; or
   - **a build key the person enrolled here**: an Ed25519 key the sender
     made for its own tagged builds (`~/.config/cmux/build-key`, 0600). The
     receiver checks the signature over the manifest and the archive's
     sha256. A build key is enrolled only through an approval card on the
     receiving machine ("cosmic-gray wants to install its own builds here"),
     never by the peer.
3. The receiver streams it to a staging folder on the bulk lane (resumable by
   offset), verifies size and sha256, then the signature, then unpacks.
4. **It never replaces anything it did not install.** A build-key build
   installs only as a tagged DEV app: bundle id `com.cmuxterm.app.debug.<tag>`,
   into `~/Applications/cmux DEV <tag>.app`. A release build installs beside
   the others under its own name. The running app and Leo's nightly are never
   quit or replaced (the nightly has its own updater).
5. If a person is logged in at the desktop, it opens the build when asked
   (`--open`); if not, it says "Air Blue has no one logged in; the build is
   installed and opens at the next login" and stops. Privacy permissions the
   build will need are listed with a button for the person there.

### Run there (`run`)

`cmux machine air-blue run [--cwd DIR] [--agent claude|codex|...]`, **New
Workspace on Air Blue**. A typed `machine.session.request` (the October
draft's schema): agent from a closed list, `cwd` inside the folders the
grant lists (realpath, no symlink escape), prompt as data delivered through
hooks. No `command`, `argv`, `env` or launcher field exists in the schema.
Answer: the host-qualified receipt `{machine, workspace_id, surface_id,
session_id}`; the caller's sidebar shows it under that machine and opens it
over the same link (the phone's `daemon` and `acpmux` lanes).

### Move (`move`)

`cmux machine air-blue move [WORKSPACE]`, **Continue on Air Blue**, and back
with **Continue on cosmic-gray**. Built from what Cloud move already does,
with the link in place of the Cloud socket:

- chats move with their history, queue and draft (`agent-transfer-v1`,
  `cmux link agent move`, the pump CloudMove uses);
- the folder goes over `fs-v1` (`cmux link seed|sync`), or as a git worktree
  of the same branch when both machines have the repo (`acpmux session move`);
- terminals reopen in the same folders; the workspace layout is recreated;
- the source keeps a "Moved to Air Blue" ledger row (as `CloudMovedChats`)
  so **Continue on cosmic-gray** brings it back.

## Audit and revoke

One format on every machine: `~/Library/Application Support/cmux/machine-activity.jsonl`
(Linux: `~/.local/state/cmux/`), 0600, append only, one line per request:
time, peer device id and name, direction (in or out), service, target
(build bundle id and sha256, workspace id, folder), decision (allowed,
asked/approved, asked/denied, refused and why), and duration. Never prompt
text, file contents or tokens. It extends the formats of acpmux
`cross-host-audit.jsonl` and remote hosting `audit.jsonl`.

**Remove** in Activity or My Machines (either end) drops the peer's record,
closes its live links at once, and tells the other end over the link so it
forgets too; a removed peer's next dial is a first contact again.

## Security analysis

The link is a relay path into the app, so each new service answers the
[relay authorization](../skills/cmux-socket-policy/references/remote-relay-authorization.md)
questions.

**Who the peer is.** The hub stamps the sender's device and user; hostd
refuses another user (`not_admitted`, unchanged) and then requires `auth`
with an identity key the person approved on this machine. A stolen Stack
token gives a device id, never an approved key. Machines are refused every
service until `auth` passes, exactly as phones are.

| Service | Runs commands or opens content locally? | Touches objects it does not own? | Reads state it should not? |
| --- | --- | --- | --- |
| `machine.describe` | No. | No. | Name, OS, arch, cmux version, logged-in desktop yes/no, the grants this peer has. No paths, sessions or windows. |
| `install` | Unpacks and, with `--open`, launches an app: allowed only for a signature the receiver verifies itself (release key, or a build key the person enrolled here by card), into a tagged path that never replaces an existing app. Nothing of the sender's choosing runs before verification. | Writes only `~/Applications/cmux DEV <tag>.app` (refuses a tag whose app it did not install) and its staging folder. | No. |
| `run` | Starts an agent: the launcher is the receiver's own, the agent an enum, the cwd in the grant's folder list; the request has no command-bearing field. | Creates a new workspace owned by this request; names no existing object. | Answers only the receipt. |
| `move` (in) | Starts terminals in the moved workspace's folders with the receiver's own shell; recreates chats through acpmux's transfer, which carries history, not commands. | Creates new objects; a move out takes only a workspace the person picked on the source. | The source sends only that workspace. |
| `control` (today's phone lanes) | Unchanged: `policy.rs` allowlists, command params denied. | Unchanged ID scoping (`owned_check`). | Unchanged. |

Command-bearing params (`command`, `initial_command`, `tmux_start_command`,
`pane_start_command`, `argv`, `env`) stay denied on every method.

**Residual risks.** A peer with `run` can start agents in the listed folders
with prompts it writes; a peer with `install` and an enrolled build key can
install a tagged app the person may then open. That is why both default to
Ask and both are logged. The hub operator sees which devices talk and when,
never content (WireGuard end to end; TURN sees ciphertext).

**Trust policy.** The new policy (machines as link peers with per-peer grants,
`install` with an enrolled build key) goes to cmux#13742 with a
recommendation before the code that enforces it merges.

## What changes in existing code

| Today | Becomes |
| --- | --- |
| hostd admits phones only (`kind: phone` callers; `cmux-mobile-dial` registers a throwaway phone) | admits any of the person's devices; `auth` carries `kind` and the requested grants |
| `DeviceTrust` (approved phone keys) | per-peer record with `kind` and grants; phones migrate with today's lanes as `view` + `control` |
| "Allow iPhone Connections" (Settings > Mobile) | **Let My Other Devices Use This Mac** (phones and machines; same default as today) |
| `cmux link` overlay, slice 1 (direct only, no relay) | dials with the mobile link's dialer (hole punch, TURN, roaming) |
| Server pairing, joined machines, acpmux peers, cmux-remote enrollment, remote hosting: five pairing records | one list (My Machines) over them; new pairing is the link's `auth`; the old records stay readable and are retired one by one as their users move |
| `acpmux host update`, `cmux link machine update` (SSH or Cloud only, sha256 pins) | `install` over the link for the person's own machines; Cloud keeps the signed channel (#36185) |
| CloudMove / CloudBringBack (Cloud links only) | `move` uses the same pump over any link |
| `cmux remote doctor` (classic, not on NEXT) | `cmux machine NAME doctor`: the link's own path report (direct, TURN, TURN over TLS) and timings |

## CLI

Selector first, so machine names never collide with the Cloud verbs
(`cmux machine run` stays the Cloud "run on a fresh machine" verb):

```text
cmux machine ls                         # My Machines, with route and presence
cmux machine NAME show                  # one machine, its grants both ways
cmux machine NAME send [--app PATH|--tag TAG] [--open]
cmux machine NAME run [--cwd DIR] [--agent A] [--prompt -]
cmux machine NAME move [WORKSPACE]
cmux machine NAME doctor
cmux machine NAME activity
cmux machine NAME remove
```

## PRs in order

1. **This design** and the #13742 recommendation.
2. **Machines on the link.** hostd: a `dial` control request (dial a peer
   through the warm signaling socket), `auth` for `kind: mac|linux` with
   grants, the per-peer record, `machine.describe`, Activity log. CLI `cmux
   machine NAME show|doctor|activity|remove`. Tests: a Mac dialing a Mac over
   loopback with the fake backend, refused without `auth`, refused for
   another user, grant checks.
3. **Send a build.** `install` service with release-key and build-key
   verification, tagged install path, `--open`, "needs a person" answers. CLI
   `send`, palette **Send This Build to…**, sidebar row menu. Tests: tampered
   archive, wrong signature, unenrolled key, existing non-tagged app,
   resumable upload.
4. **Run there.** `machine.session.request` with folder allowlist; **New
   Workspace on…** picks link machines.
5. **Move.** The Cloud move pump over the link; **Continue on…** both ways.
6. **Phones as controllers of every machine.** The phone's machine list shows
   every Mac with **Continue on**, **New Workspace on**, and approval cards
   for machine requests; iOS parity rows.
7. **Consolidation.** `cmux link` on the mobile dialer; Settings > Devices
   shows one list; retire the duplicate pairing records as their callers move.

## Status

| PR | State |
| --- | --- |
| 1 | this PR |
