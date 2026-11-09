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

The bar: sign in on any Mac or phone, and every one of your devices is there.

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
   nothing (no frame, no keystroke) follows them: the target owns the stop.
   Every control or screen session has an epoch; Stop (pressed there, or
   arriving from the peer) bumps it on the target first, and the target's
   input injector drops every queued or later input event that carries an
   older epoch before it acknowledges Stop. Input is applied only by the
   target, so no lane ordering can let a keystroke through after it. Frames
   carry the epoch too: on Stop the target stops the capture source, drops
   every frame still queued on the media lane for that session, and sends
   nothing more under the old epoch, all before it acknowledges; the viewer
   also drops any late frame of an old epoch (review: media fence).
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
  (`tests/roaming.rs`). A TURN relay carries only WireGuard-encrypted
  packets and never sees plaintext; no backend service terminates the
  link's encryption.
- Priority lanes (control, input, bulk) so a 2 GB build upload never delays a
  keystroke or an approval (`class_queue.rs`, the input lane).
- Signaling is the person's own hub (`team-hub.ts`, one Durable Object per
  user). It already admits a dial from any of the user's devices to any of
  their Macs (`admit`), and stamps the sender's device and user; no backend
  change is needed for Mac to Mac.
- A Mac with **Let My Other Devices Use This Mac** on runs
  `cmux-mobile-host` (hostd) with a warm signaling socket. That switch is
  today's `mobile.allowIPhoneConnections`, off by default, and stays off by
  default: a Mac with it off is listed in My Machines (the registry knows it)
  as "Not reachable: turn on Let My Other Devices Use This Mac there", with
  the one step said, and no action is offered on it. A Mac dials through **its own** hostd (a new `dial`
  control request), so it never opens a second socket under its device id and
  every dial reuses warm signaling and cached ICE.

**Machines already paired keep working when the hub is down** (lens review).
Each side caches the peer's identity key and last endpoints (LAN address,
STUN-reflexive address, Tailscale address when it has one). Today the
session's WireGuard key is fresh and its UDP port ephemeral, and `wg-init`
and `wg-resp` travel only through signaling, so this needs one addition
(review: hub-down reconnect): hostd keeps a direct listener, one UDP port on
LAN and Tailscale interfaces only, that accepts the same `wg-init` message
signaling carries, signed by a pinned identity key, and answers `wg-resp`
signed by its own. Unsigned or unknown-key messages get no answer. The
cached endpoints record that port. A dial tries it first, in parallel with
hub signaling; the signed exchange, the WireGuard handshake and `auth`
against the pinned key are the proof, so a direct dial needs no hub. The
listener lands with the machines-on-the-link PR, behind the same switch. What a hub outage stops, exactly: every first contact; every TURN path
(TURN credentials come from signaling); and a reconnect when neither side
can reach the other's direct listener at a cached address, as after both
sides change networks off Tailscale. What keeps working: two paired
machines on one LAN, or both on Tailscale, whose cached listener address
still answers. The doc promises no more than that; My Machines shows
"Hub unreachable: direct only" so the person sees which case they are in.

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
  record, checked at every channel open and again at every request on a
  request service (`run`, `install`, `move`); a change to it reaches open
  channels too (see Grant changes reach open channels). First contact shows the caller's
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

**The `auth` signature is bound to the link it rides** (review: channel
binding). Today the signed message names both device ids, the nonce and the
keys, but not the transport, so a hub that both relays signaling and runs
its own WireGuard endpoint could pass a real peer's challenge and signature
onto a link it controls. For machines (and then phones), the signed message
adds the link's binding: the SHA-256 of both WireGuard static public keys of
this session, in a fixed order (the WebRTC fallback uses both DTLS
fingerprints). Each side computes it from its own handshake state, never
from the peer's word, and refuses an `auth` whose binding is not its own
link's. A relayed signature then names the wrong link and fails. This lands
before any grant beyond pairing (the next machine PR), so no grant ever rides
an unbound link.
Machines use the same `auth`, with `kind: "mac"` and the grants it asks for.
`kind` is the caller's claim and grants nothing by itself (review: kind
binding): the registry takes a device's `kind` from the device
(`POST /v1/devices`), so a phone could register as a Mac. The target
therefore decides what a peer is from its own record, made by the person
on the first-contact card, which says what the caller claims to be and
shows its key fingerprint ("Studio, a Mac"). `install` is offered on that
card, and accepted later, only for a peer the card recorded as a Mac whose
identity key the person approved as one; a peer recorded as a phone never
holds `install`, whatever `kind` a later `auth` sends, and a changed `kind`
under the same key is refused as a different device. A phone's key is
already a different key from any Mac's, so a phone that claims to be a Mac
is a new first contact, shown to the person as one.

**The grants are signed too** (review: grant scope). The signed `auth`
message carries the requested grants as a canonical list (sorted grant
names, each with its scope: folders for `run`, build key fingerprints for
`install`), so a hub that relays the request cannot widen or swap it. The
card shows exactly that list. An approval from the phone signs the caller's
key fingerprint, the link binding and the canonical list of the grants the
person ticked; hostd verifies that signature, and that the ticked list is a
subset of what the caller signed, before it writes `DeviceTrust`. A grant
that is not in both signed lists is never written.

**Which phone may approve** (review: approval bootstrap). The target checks
a phone's approval signature only against an approval key already in its
own `DeviceTrust`, put there when that phone paired with this Mac through
its own card (today's `pairing.rs` flow). A key that arrives through the hub
or the caller is never accepted as an approver. So the card for a first
contact shows on the phone only when that phone is already paired with the
target Mac; otherwise it shows only on the target Mac itself, and the person
approves there. The device registry's ids are never treated as keys.
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

**Grant changes reach open channels** (review: revocation of live
channels). Each peer record has a trust epoch, and every open channel and
every live `control` or `screen` session carries the epoch it opened under.
Taking a grant away, narrowing its scope (a folder, an agent or a build key
taken off its list, an "Always" removed), Remove, and Stop bump the epoch.
Before the change is acknowledged in Settings, hostd closes every channel
and session of that peer whose service or scope is no longer allowed, drops
any queued input for it (the same fence Stop uses), and cancels the work
it started that falls outside the new scope (review: scope narrowing): an
upload or install not yet moved into place is discarded; a move not yet
committed stops at its last committed step; an agent started over `run`
whose folder or agent left the list is stopped (its session and history
stay, as for any stopped agent). Adding a grant opens nothing; the peer's
next request uses it.

**The person or an agent** (lens review: the confused deputy). `cmux machine
NAME run|send|move` can be called by an agent on the caller, and an agent
can type anything a person can into a terminal, so a claim is not a proof.
A request is `person` only when the caller's app made it from a gesture in
its own UI (a click, a palette row, the sidebar menu) and sends it over its
own control line to hostd, which no other process can write. Everything
else is `agent`: every `cmux` CLI call, every socket or MCP request, and
every request on hostd's local link socket, whatever origin it names (hostd
overwrites it). A terminal command that needs `person` (a `send`) prints a
link that opens the same action in the app, where the person confirms it.
The target never trusts the claim upward: an
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
   - **the cmux release key**: an Ed25519 key that signs a new per-build
     manifest, `cmux-<version>-<arch>.manifest.json` (bundle id, version,
     build number, channel, arch, the archive's SHA-256 and size, and the
     installed-tree hash below, all inside the signed bytes), published beside the
     DMG by the release and nightly jobs and signed by the same signing step
     that writes the appcast's `sparkle:edSignature` (today that signs the
     DMG only, so this is a new step). The key's public half ships in the
     app, as Sparkle's does. A rotation is a signed statement, not an
     embedded key (review: key rotation): the release publishes
     `cmux-release-key-rotation.json` (the new public key, the first build
     number it signs, and the old key's fingerprint) signed by the old key,
     and every manifest the new key signs for the next 90 days carries a
     second signature by the old key. A receiver accepts a manifest signed
     by a key it does not ship only when it holds a rotation statement for
     that key, verified against a key it already trusts, and then records
     the new key; a manifest signed by an unknown key with no such statement
     is refused. And
     the build's codesign must satisfy the exact designated requirement of
     its channel: Developer ID Manaflow, Inc. (7WLXT3NR37), notarized, *and*
     bundle id `com.cmuxterm.app` (release) or the nightly's id, nothing
     else. The receiver checks the manifest signature and the archive's
     sha256 against the signed manifest before unpacking, then the unpacked
     tree's hash against the signed manifest before the rename, then
     `codesign --verify --deep --strict
     -R '<designated requirement>'` and `spctl -a` on the unpacked app. Any
     other app signed by the team (a helper, a lab app) is refused, and so
     is a build older than the one installed at that path (the manifest's
     build number), so an old signed build cannot be replayed; or
   - **a build key the person enrolled here**: an Ed25519 key the sender
     made for its own tagged builds (`~/.config/cmux/build-key`, 0600). The
     receiver checks the signature over the manifest (which signs the
     archive's SHA-256 and size and the installed-tree hash), the archive
     against it before unpacking, and the unpacked tree against it before
     the rename. A build key is enrolled only through an approval card on the
     receiving machine ("Studio wants to install its own builds here"),
     never by the peer.
3. The receiver streams it to a staging folder on the bulk lane (resumable by
   offset), verifies size and sha256, then the signature, then unpacks with
   its own extractor, not `tar`: regular files, directories and relative
   symlinks only (cmux bundles carry some, such as `bin/cmux-tui` and
   `bin/acpmux`), every path inside one top-level `<name>.app/`, no `..`
   component, no absolute path, no hard link, device, FIFO or setuid bit,
   and a cap on file count and total size. Symlinks never let a write
   escape (review: symlink order): the extractor writes every file and
   directory first, each opened relative to the staging folder's descriptor
   one component at a time with `O_NOFOLLOW` (`openat`), so no path it writes
   through can be a link; it creates the symlinks last, and checks each
   target lexically (resolved against the link's own folder inside the
   bundle, never through the file system) before it creates the link. A
   target that leaves the bundle, or a symlink at a path already written,
   refuses the whole archive. The whole tree is then checked once more
   against the manifest before it is moved into place. Anything else refuses
   the whole archive. It unpacks into a fresh folder in staging, on the same
   volume as `~/Applications`. A first install moves it into place with
   `renamex_np(RENAME_EXCL)`, which fails rather than overwrite anything. A
   replacement (allowed only by step 4) swaps the two folders atomically
   with `renamex_np(RENAME_SWAP)`, which works on a non-empty destination
   (review: replacement); the old tree, now in staging, is deleted after the
   ledger records the new one. A crash at any point leaves either the old or
   the new app at the path, never a mix, and the ledger's pending entry tells
   the next start which one and what to clean up. The old tree is checked
   after it leaves the path, not before (review: replacement race): hostd
   swaps first, then hashes the tree it just swapped out, now in its own
   staging folder. If that hash is not the ledger's (anything changed the
   app since this link installed it), it swaps back at once and refuses the
   send with "MacBook's copy of cmux DEV <tag> changed since it was
   installed; left as it is". A swap loses nothing, so a tree this link did
   not install is never deleted, whatever wrote to the path between any
   check and the swap. Installs to one path are
   serialized by a lock on that path, so two sends of one tag never race.
   The journal order is: write and sync the pending ledger entry (old and
   new tree hashes), swap, write and sync the committed entry, then delete
   the old tree. At start, a pending entry is resolved by hashing what is at
   the path. The install PR tests a crash at each step.
4. **It never replaces anything it did not install.** The receiver keeps an
   install ledger (0600, beside Activity): each install's path, bundle id,
   archive sha256, installed-tree hash and the peer that sent it. The
   installed-tree hash is SHA-256 over the sorted list of (relative path,
   type, mode, size, content SHA-256 or symlink target) of every entry in
   the bundle, so it is the same for the same tree whatever archive carried
   it. It replaces an app only if the ledger says this machine link put it
   there and the tree it swaps out still has the ledger's tree hash (checked
   after the swap, as above); anything else at that path is left alone, or
   swapped back, and the send is refused with its reason. A build-key build
   installs only as a tagged DEV app: bundle id `com.cmuxterm.app.debug.<tag>`,
   into `~/Applications/cmux DEV <tag>.app`. The tag must match
   `^[a-z0-9][a-z0-9-]{0,39}$`, and the signed bundle id must be exactly
   `com.cmuxterm.app.debug.<tag>`. That is stricter than
   `scripts/reload.sh`, which accepts `^[A-Za-z0-9_-]+$` and makes the
   bundle segment by turning every other character into `.`
   (`mobile-attach.sh`): a reload build tagged `foo_bar` carries
   `com.cmuxterm.app.debug.foo.bar` and no tag maps to it. The sender checks
   this before uploading and says "rebuild with a tag of lowercase letters,
   digits and dashes" (a tag such as `foo-bar` already satisfies both); it
   never renames a signed bundle. Any other tag or bundle id refuses the send, so neither the path nor the bundle id is ever
   built from a slash, a dot component or a control character. The final
   path is checked to be a direct child of `~/Applications` after
   resolving. A release build installs beside
   the others under its own name. The running app and the person's nightly are never
   quit or replaced (the nightly has its own updater). With `--open`, the
   receiver hashes the installed tree again and checks the app's code
   signature against the build's designated requirement (the release
   requirement, or the enrolled build key's) just before it launches. The
   hash catches a tree damaged since install. What it cannot stop, and does
   not claim to, is another process running as the person rewriting the app
   between that check and the launch: such a process can already run
   anything as the person, so this design gives it no new power. The
   threat this step guards against is the peer and the link, and their
   bytes were verified before the app ever reached the path.
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

**`run` is code execution as the person** (review: run scope). The folder
list fixes only where the agent starts. The agent itself (Claude, Codex)
runs commands and edits files as the person's user on the target, anywhere
that user can reach, so `run` is treated as that and not as a sandbox. The
card says so in words: "Studio wants to start Codex here. Codex can run
commands and change files as you on this Mac." The agent starts in the
target's own default permission mode and policy for that harness, which the
request cannot name or raise: an agent started over `run` asks on the target
(and on a paired phone) before every command its own policy would ask for,
exactly as one the person started locally. "Always" on a `run` card covers
that peer, folder and agent only. A sandboxed `run` (a container, or a
macOS sandbox profile) is a later option, not something this design
claims.
Answer: the host-qualified receipt `{machine, workspace_id, surface_id,
session_id}`; the caller's sidebar shows it under that machine and opens it
over the same link (the phone's `daemon` and `acpmux` lanes).

Every `run` carries a request id the caller makes once (a UUID). The target
keeps each id with its receipt for as long as the workspace it made exists,
and a day after it closes, in the install ledger's sibling file; a retry
after a lost reply (a link that dropped and came back) gets the same receipt,
never a second workspace. The caller retries an id for at most a day; after
that it asks the person again with a new id.

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

**A move never ends a running command silently** (lens review: a running
build is work). A process can't move between machines, so a terminal whose
foreground process is not its shell (a dev server, a build, a test watcher,
or an agent CLI such as `claude` run in a terminal tab) can't simply reopen
on the target. The move card names each one with its command ("Terminal 2
is running `npm run dev`").

- **By default it stays running on the source.** Its writes stay in the
  source's folder; the move copies the folder once and doesn't sync it
  afterward. On the source, the moved workspace keeps only its running tabs,
  live and closable, under the "Moved to MacBook" row, and **Continue on
  Studio** puts them back in the returning workspace instead of opening new
  shells.
- **What the target sees depends on its grants on the source** (a move
  grants nothing more). With no grant, the target shows the tab as "Running
  on Studio" with the command name from the move. With `view`, it also
  streams the output read-only. With `control`, it also takes input, over
  the lanes a phone already uses. Each is checked against the source's own
  `DeviceTrust` and trust epoch when it's used.
- **Stop and Reopen on MacBook** on the card ends that one command and opens
  a fresh shell in the same folder on the target. The command is ended only
  after the receiver confirms the move's last step (when the source marks
  the workspace moved); a move that fails or is cancelled ends nothing.
- **A move started by an agent** always leaves running commands where they
  are.

Chats aren't terminals: a running chat turn moves and continues on the
target (`agent-transfer-v1`, #30567). Idle terminals move as above. The move
PR tests a running command left on the source and reached from the target
under each grant, Stop and Reopen ending only the command named on the card
and only after the last step commits, and a failed move ending nothing.

Neither pump may simply be pointed at a Mac. `fs-v1` is served only by a
Cloud host today, and `agent-transfer-v1` refuses remote and stamped
clients, both on purpose. A Mac serves them on the link only behind a new
gate. On the **source**, a move out happens only from the source's own UI
or its own CLI (the person picks the workspace there), never on a peer's
request: the source mints a one-use move ticket (random, scoped to that one
workspace id, its chats and its folder) and sends it with the move. The
ticket must be presented within 5 minutes; once the receiver accepts it, it
is the move's lease, renewed by every committed step and by a heartbeat
while a step runs, and it lapses only after 5 minutes with no progress or
when the person cancels on the source. A large folder therefore never runs
out of ticket mid-copy, and a retry inside the lease resumes. The pumps serve only what the ticket names and refuse every other id.
A peer that only holds `move` can therefore bring nothing out. On the
**receiver**, the peer holds `move` here, the request names one workspace,
and the folder it writes is the workspace's own (a new folder under the person's
chosen root on the receiver, or the same repo's worktree). Writes use the
install extractor's rule, not a realpath check that a later write could race
(review: move confinement): every file is opened relative to the
workspace folder's descriptor one component at a time with `O_NOFOLLOW`;
symlinks from the source are recreated last, only when their target
resolves lexically inside the workspace folder, and are otherwise refused
with the file named in the move's report. No other root is reachable. That gate, with its
tests, is the move PR's first commit.

A move is one transaction with an id (the ticket's). Each step (folder,
chats, workspace) is recorded on both sides as it commits, in the ledger;
a retry with the same id resumes from the last committed step and never
copies twice, and the source marks the workspace moved only after the
receiver confirms the last step. A move that cannot finish leaves the
source as it was and the receiver's partial folder named as such, with
**Retry** and **Discard**.

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
(Linux: `~/.local/state/cmux/`), 0600, append only, one line per request,
bounded: at 4 MiB it rotates to `machine-activity.1.jsonl` (one previous
file kept, 8 MiB in all), and repeated identical refusals from one peer
(same service and code) are logged once a minute with a count. A write that
fails (disk full) never blocks or changes the decision; it is counted and
shown in Activity. One line per request:
time, peer device id and name, origin (person or agent), direction (in or
out), service, event (the device hub's names: `requested`, `approved`,
`denied`, `started`, `ended` with its reason), target
(build bundle id and sha256, workspace id, folder), decision (allowed,
asked/approved, asked/denied, refused and why), and duration. Never prompt
text, file contents or tokens. It extends the formats of acpmux
`cross-host-audit.jsonl` and remote hosting `audit.jsonl`.

**Remove** in Activity or My Machines (either end) drops the peer's record,
bumps its trust epoch and closes its live links at once (see Grant changes
reach open channels). The remover keeps a tombstone (the peer's identity
key and the removal time) and refuses every `auth` from that key until the
person pairs it again by card. Dropping the record, bumping the epoch and
writing the tombstone are one durable transaction (one SQLite transaction,
committed with a full sync) that commits before Remove is acknowledged or
any link is closed (review: durable Remove); a crash before the commit
leaves the peer paired and Remove not shown as done, never the peer
forgotten without a tombstone; the tombstone, not the other end's
cooperation, is what makes Remove hold. It then tells the other end so it
forgets too, with a removal notice signed by the remover's identity key:
over the live link when there is one, and otherwise as the answer to that
peer's next dial, which the tombstone refuses with the signed notice in
place of a first-contact card. The hub's reply mailbox is not used: it
carries only phone-to-Mac replies today (review: notice route). The other
end verifies the notice against the key it pinned and drops its record of
the remover; a hub can delay a dial, never forge a notice. Until the
other end confirms, Activity on the remover shows "Removal not yet
delivered to MacBook", so the person knows that machine still lists this
one (it can no longer get in here either way).

**Pairing again after Remove** (review: tombstone reset). Only the remover
can lift its tombstone: **Allow MacBook to Pair Again** in Activity on that
machine (a person's gesture in its own UI, never a request over the link).
That deletes the tombstone, and the peer's next dial is a first contact with
the usual card.

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
| `run` | Yes, by design: it starts an agent that runs commands as the person. The launcher is the receiver's own, the agent an enum, the start folder in the grant's list, and the agent's permission mode the receiver's default, which the request cannot raise; the request has no command-bearing field. | The request creates a new workspace and names no existing object; the agent it starts can touch what the person's user can, under its own permission prompts. | The request answers only the receipt; the agent can read what the person's user can. |
| `move` (in) | Starts terminals in the moved workspace's folders with the receiver's own shell; recreates chats through acpmux's transfer, which carries history, not commands. | Creates new objects; a move out takes only the workspace named by a one-use ticket the source minted from its own UI. | The source's pumps serve only the ticket's workspace, chats and folder. |
| `screen` | Shows the screen (View) or injects input (Control) through the screen-sharing worker; Control never from an `agent` origin; the indicator and Stop always show. | No. | The screen, by design: that is the grant. |
| `control` (today's phone lanes) | Unchanged: `policy.rs` allowlists, command params denied. | Unchanged ID scoping (`owned_check`). | Unchanged. |

Command-bearing params (`command`, `initial_command`, `tmux_start_command`,
`pane_start_command`, `argv`, `env`) stay denied on every method.

**Residual risks.** A peer with `run` can start agents in the listed folders
with prompts it writes, and those agents act as the person under the
target's own permission prompts (see `run`); a peer with `install` and an enrolled build key can
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
   link-bound, signed grants, the per-peer record with its trust epoch,
   removal tombstones and signed removal notices, the direct listener,
   `machine.describe`, Activity log. CLI `cmux machine NAME
   show|doctor|activity|remove`. Tests: a Mac dialing a Mac over loopback
   with the fake backend, refused without `auth`, refused for another user,
   grant checks, a relayed grant list that was widened is refused, a grant
   taken away closes the open channel, a removed key is refused while the
   other end was offline.
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
| 2 | next; owner of PRs 2 to 8 in this order: the paired-mac-docs agent session ([session](https://cmux.com/deeplink/agent?id=aid-7b9fdc33059f6db52b75)), which starts PR 2 when this one merges |
