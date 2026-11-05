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

> you can look at some of the lenses in HQ to review and think about how we
> want to do this well. I suppose the screen sharing code, it's somewhat
> related

The HQ lens review (Tailscale, WireGuard, Signal, capabilities, Mosh, Varda,
latency, HIG, Nielsen, local-first) shaped the parts marked "(lens review)".

## The experience

The bar is ChatGPT desktop and iOS: sign in, and your devices are there.

1. **A new Mac.** Install cmux and sign in with the same account (or, from a
   Mac that already has cmux, **Set Up cmux on Another Mac…** over SSH you
   already have). It appears in **My Machines** on every Mac and phone of that
   account within a second of signing in.
2. **First contact asks once, on the machine being used.** The first time
   Studio reaches MacBook, MacBook shows "Studio wants to use this
   Mac" with what it asks for, and the same card reaches the person's phone
   (a signed approval, as phone pairing already does). Allow pins
   Studio's identity key with the chosen grants. No code, no SSH, no
   Tailscale policy, no port.
3. **Then it just works, both ways.** From any Mac: the sidebar machine picker,
   **New Workspace on MacBook**, **Continue on MacBook** (moves the
   workspace with its chats and terminals), **Send This Build to MacBook**.
   From the phone: the same machines, opening and moving their workspaces,
   starting a workspace there, and every approval card. A phone never sends a
   build (it has none) and never installs one, so it shows no **Send This
   Build** row. From the CLI: `cmux machine macbook send|run|move`.
4. **Approvals go where the person is.** A grant set to Ask shows its card on
   that Mac and on the person's phone, whichever answers first.
5. **What only a person at that Mac can do is said, never attempted.** Screen
   Recording and Accessibility, and a logged-in desktop to launch an app, are
   shown as one line with a button that opens the right Settings pane there.
6. **Everything is in Activity, on both ends.** Each machine lists what other
   devices did on it and what it did on them; **Remove** on either end ends it.
7. **You always know when you are being controlled, and Stop always wins**
   (lens review). While any peer holds a live `control` or `screen` session,
   the target shows "Studio is controlling this Mac" with **Stop**, in the menu
   bar and the window. Stop and Remove travel on the link's control lane, and
   nothing (no frame, no keystroke) follows them.
8. **One page per device.** Settings > Devices shows each phone and machine
   once, with everything it may do here. Today that is four switches: Allow
   iPhone Connections, Mac Screen device access, Join consent and Computer
   Use machine consent.

## One link for every device

The mobile link (`cmux-next-ios/rust/crates/cmux-mobile-link`, PROTOCOL.md) is
the transport for every pair of the person's devices, phone to Mac and Mac to
Mac (Linux later; see Pairing). It is the fastest and most tested path
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

**Machines already paired keep working when the hub is down** (lens review).
Each side caches the peer's identity key and last endpoints (LAN address,
STUN-reflexive address, Tailscale address when it has one). A dial tries
those directly first, in parallel with hub signaling; the WireGuard handshake
and `auth` against the pinned key are the proof, so a direct dial needs no
hub. A hub outage stops only first contacts.

What this replaces as the way between the person's machines: SSH as the
default route, the `cmux link` overlay's "direct paths only, no relay" slice,
and iroh. SSH stays as a first-contact route and a fallback; see
[What changes](#what-changes-in-existing-code).

Speed targets, measured by `cmux-mobile-dial` and the demo below, as p50,
p95 and p99 (lens review), with keypress to echo over the link, screen glass
to glass at 30 ms p50 and 50 ms p99 (the remote desktop plan's budget), and
sign-in to "shows in My Machines" under 2 s: link up
under 300 ms warm on the same LAN, under 1 s across networks; ping p50 under
5 ms on a LAN; bulk at the path's line rate (the WireGuard path is a smoltcp
TCP stream with 256 KiB buffers; raise the window for bulk channels if the
demo shows it bound).

## One identity and one list

- **A device is its hostd identity key**: a Secure Enclave P-256 key on a Mac
  that has one (as the phone's), a 0600 file key elsewhere. The device id,
  name, machine id, Tailscale name and SSH alias are labels and hints; none
  authorizes anything.
- **The hub is never the authority** (lens review). The hub stamps who sent
  a signal; that only routes. Admission is the target's own `DeviceTrust`
  record, checked at every channel open. First contact shows the caller's
  key fingerprint on the card (here and on the phone, whose signed approval
  covers the same key), so a hub that swapped keys is visible.
- **My Machines** is one list (drawn from a local cache first, no spinner): the hub's `GET /v1/me/devices` (every Mac and
  phone of the account, with live presence) merged with what `cmux device
  list` already merges locally (acpmux peers, SSH config hosts, Cloud
  machines). One row per machine: rows with the same `machineId` group, and
  within a group each build (release, nightly, a tagged DEV) is a sub-row
  with its own device id, the online one first. A row with no `machineId`
  (an older app) is its own machine, keyed by its device id, and is never
  merged by name. A machine reachable several ways shows once, with its
  best route.

## Pairing: first contact, then per-peer grants

Phone pairing already works this way (`pairing.rs`): the first channel of a
link is `auth`, the caller signs a fresh challenge with its identity key, and
hostd asks the app "Allow <device>?" unless the key is already approved.
Machines use the same `auth`, with `kind: "mac"` and the grants it asks for.
Linux machines come later: today the device registry and the hub know only
`mac` and `phone` (`backend/src/index.ts`, `schema.ts`, `team-hub.ts`), so a
Linux kind needs that change in the same PR that lets one pair.

Unchanged: the rate limits per device and per account,
the deny cooldown, and "a token alone reaches nothing".

Each machine keeps, for every peer, a local record (`DeviceTrust`, extended):

| Grant | The peer may | Phone default | Machine default |
| --- | --- | --- | --- |
| `view` | See this machine's workspaces and chats, read files in chat roots | on (today's phone lanes) | off: chosen on the first-contact card or later |
| `control` | Type into terminals, answer agents, open and close tabs and workspaces (today's phone lanes) | on (today) | Ask |
| `run` | Start agents and workspaces in listed folders (typed request; no command strings) | off | Ask |
| `install` | Install a cmux build it sends, signed by the cmux release key or by a build key enrolled here | never | Ask |
| `move` | Move a workspace in or out, with its chats, terminals' state and folder (a move in is also a write to its folder, so the card names both) | off | Ask |
| `screen` | See this Mac's screen (View) or also drive its mouse and keyboard (Control) | Ask | Ask |

Pairing alone grants nothing. A paired machine with no grant may open only
`echo`, `version` and `machine` (its name, OS, desktop state and the grants
it holds here), none of which says anything about the person's work. The
first-contact card lists the grants the caller asked for, each unticked; the
person ticks what to allow, and can change it later in Settings > Devices.

Ask means each request shows the approval card (here and on the phone);
**Always** on the card allows the same request again (this folder, this
agent, this build key), not the whole grant (lens review). The card never
takes focus and has no default button.

**The person or an agent** (lens review: the confused deputy). `cmux machine
NAME run|send|move` can be called by an agent on the caller. Every request
carries its origin as the caller's app knows it: `person` (a click, a palette
row, a command typed in a terminal the person is at) or `agent` (an agent's
tool call or socket request). The target never trusts the claim upward: an
`agent` request never uses `install` or `screen` Control, and `run` and
`move` from an agent always ask, whatever "Always" says. Grants are set only
on the machine they protect, never by the peer, the hub or the registry. A
phone gets no `install` at all: a phone has no build to send, and installing
from a phone is not a lane a paired phone may have
([SECURITY.md](../cmux-next-ios/SECURITY.md)).

## Actions

All three are typed services on the link, refused unless the grant allows
them, and logged on both ends.

### Send a build (`install`)

`cmux machine macbook send [--app PATH | --tag TAG]`, **Send This Build to
MacBook**, or the sidebar row's menu.

1. The sender packs the `.app` (and its bundled `cmux` and hostd) as a
   deterministic tar (`--zstd`), and a manifest: bundle id, version, tag,
   arch, sha256 and size of the archive.
2. Signed by either:
   - **the cmux release key**: an Ed25519 key that signs every release's
     manifest (the same manifest the updater's appcast already signs), and
     the build's codesign must satisfy the exact designated requirement of
     its channel: Developer ID Manaflow, Inc. (7WLXT3NR37), notarized, *and*
     bundle id `com.cmuxterm.app` (release) or the nightly's id, nothing
     else. The receiver checks the manifest signature and the archive's
     sha256 before unpacking, then `codesign --verify --deep --strict
     -R '<designated requirement>'` and `spctl -a` on the unpacked app. Any
     other app signed by the team (a helper, a lab app) is refused; or
   - **a build key the person enrolled here**: an Ed25519 key the sender
     made for its own tagged builds (`~/.config/cmux/build-key`, 0600). The
     receiver checks the signature over the manifest and the archive's
     sha256. A build key is enrolled only through an approval card on the
     receiving machine ("Studio wants to install its own builds here"),
     never by the peer.
3. The receiver streams it to a staging folder on the bulk lane (resumable by
   offset), verifies size and sha256, then the signature, then unpacks with
   its own extractor, not `tar`: regular files and directories only, every
   path relative and inside one top-level `<name>.app/`, no `..`, no
   absolute path, no symlink that resolves outside the bundle, no hard
   link, device, FIFO or setuid bit, and a cap on file count and total
   size. Anything else refuses the whole archive. It unpacks into a fresh
   folder in staging, which is moved into place with one rename.
4. **It never replaces anything it did not install.** The receiver keeps an
   install ledger (0600, beside Activity): each install's path, bundle id,
   archive sha256 and the peer that sent it. It replaces an app only if the
   ledger says this machine link put it there and the app on disk still
   matches the ledger's hash; anything else at that path is left alone and
   the send is refused with its reason. A build-key build
   installs only as a tagged DEV app: bundle id `com.cmuxterm.app.debug.<tag>`,
   into `~/Applications/cmux DEV <tag>.app`. A release build installs beside
   the others under its own name. The running app and the person's nightly are never
   quit or replaced (the nightly has its own updater).
5. If a person is logged in at the desktop, it opens the build when asked
   (`--open`); if not, it says "MacBook has no one logged in; the build is
   installed and opens at the next login" and stops. Privacy permissions the
   build will need are listed with a button for the person there.

### Run there (`run`)

`cmux machine macbook run [--cwd DIR] [--agent claude|codex|...]`, **New
Workspace on MacBook**. A typed `machine.session.request` (the October
draft's schema): agent from a closed list, `cwd` inside the folders the
grant lists (realpath, no symlink escape), prompt as data delivered through
hooks. No `command`, `argv`, `env` or launcher field exists in the schema.
Answer: the host-qualified receipt `{machine, workspace_id, surface_id,
session_id}`; the caller's sidebar shows it under that machine and opens it
over the same link (the phone's `daemon` and `acpmux` lanes).

Every `run` carries a request id the caller makes once (a UUID). The target
keeps the ids it answered for a day, with their receipts, in the install
ledger's sibling file; a retry after a lost reply (a link that dropped and
came back) gets the same receipt, never a second workspace.

### Move (`move`)

`cmux machine macbook move [WORKSPACE]`, **Continue on MacBook**, and back
with **Continue on Studio**. Built from what Cloud move already does,
with the link in place of the Cloud socket:

- chats move with their history, queue and draft (`agent-transfer-v1`,
  `cmux link agent move`, the pump CloudMove uses);
- the folder goes over `fs-v1` (`cmux link seed|sync`), or as a git worktree
  of the same branch when both machines have the repo (`acpmux session move`);
- terminals reopen in the same folders; the workspace layout is recreated;
- the source keeps a "Moved to MacBook" ledger row (as `CloudMovedChats`)
  so **Continue on Studio** brings it back.

Neither pump may simply be pointed at a Mac. `fs-v1` is served only by a
Cloud host today, and `agent-transfer-v1` refuses remote and stamped
clients, both on purpose. A Mac serves them on the link only behind a new
gate: the peer holds `move` here, the request names one workspace, and the
folder it writes is the workspace's own (a new folder under the person's
chosen root on the receiver, or the same repo's worktree), checked by
realpath on every file. No other root is reachable. That gate, with its
tests, is the move PR's first commit.

### Take over (`screen`)

The phone and Mac already share one screen engine for simulators and Cloud
desktops: hostd's `surface` service (`cmux.rd/1` on a link channel, video on
the media lane as H.264 RTP over the WireGuard UDP carrier, with frame
skipping and NACK). **Take over** adds a display source to it, fed by the
cmux Remote screen-sharing worker, which stays the only process holding
Screen Recording and Accessibility. Video rides the media lane and input the
input lane. Share This Mac's WebRTC `ScreenStream` and the device hub's
tickets move onto this; the remote desktop plan's separate Noise_XX
transport is not built.

## Audit and revoke

One format on every machine: `~/Library/Application Support/cmux/machine-activity.jsonl`
(Linux: `~/.local/state/cmux/`), 0600, append only, one line per request:
time, peer device id and name, origin (person or agent), direction (in or
out), service, event (the device hub's names: `requested`, `approved`,
`denied`, `started`, `ended` with its reason), target
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
| `screen` | Shows the screen (View) or injects input (Control) through the screen-sharing worker; Control never from an `agent` origin; the indicator and Stop always show. | No. | The screen, by design: that is the grant. |
| `control` (today's phone lanes) | Unchanged: `policy.rs` allowlists, command params denied. | Unchanged ID scoping (`owned_check`). | Unchanged. |

Command-bearing params (`command`, `initial_command`, `tmux_start_command`,
`pane_start_command`, `argv`, `env`) stay denied on every method.

**Residual risks.** A peer with `run` can start agents in the listed folders
with prompts it writes; a peer with `install` and an enrolled build key can
install a tagged app the person may then open. That is why both default to
Ask and both are logged. The hub operator sees which devices talk and when,
never content (WireGuard end to end; TURN sees ciphertext). The hub keeps
the person's device graph (`/v1/me/devices`: ids, names, kinds, presence)
and no audit: Activity stays on the devices, and "both ends" is a query over
the link (lens review).

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
| Share This Mac on the device hub (`workers/device-hub`): its own device keys, per-pair permissions (none, ask, view, full), tickets, TURN minting and server-side audit | the `screen` grant over the link; the hub's keys, permissions, tickets and audit retire as Mac Screen and the iPhone viewer move; `ApprovalBanner` and `ShareIndicator` become the one card and indicator for every grant |
| `cmux-vnc://` room-and-secret pairing | retired (whoever holds the link gets in); the RFB client stays for compatibility |
| Computer Use machine consent (team machines, agents) | stays agent consent, with the same card and the same Activity log |
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
   through the warm signaling socket), `auth` for `kind: mac` with
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
6. **Take over.** The `screen` grant, a display source in `surface`, the
   indicator and Stop; Share This Mac moves onto the link.
7. **Phones as controllers of every machine.** The phone's machine list shows
   every Mac with **Continue on**, **New Workspace on**, and approval cards
   for machine requests; iOS parity rows.
8. **Consolidation.** `cmux link` on the mobile dialer; Settings > Devices
   shows one list; retire the duplicate pairing records as their callers move.

## Status

| PR | State |
| --- | --- |
| 1 | this PR |
