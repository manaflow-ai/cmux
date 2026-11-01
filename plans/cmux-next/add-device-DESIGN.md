# Add Device: one way to add, list and remove every device

Status: design and v1, 2026-10-22. Branch `feat-cmux-next`.
User (u9923, u9924): "we need to build the tailscale add-device flow too, and it needs to be
cohesive ... with every part of the product, like stuff aziz is working on, mobile stuff, screen
sharing stuff, acpmux stuff, tui, daemon".

Related: `add-machine-DESIGN.md` (ssh enroll), `add-server-ui-DESIGN.md` and `server.md` section 6
(code and words), `remote-hosts.md` (`cmux host serve`), `teammate-access-DESIGN.md` (grants and
audit), `mesh-DESIGN.md` (Weft, a527), `cmux-next-ios/PROTOCOL.md` (phone link, Aziz),
`remote-desktop-DESIGN.md` (screen sharing).

## 1. What exists today (2026-10-22)

There are 13 ways a device joins a person's cmux. Each one has its own entry, its own trust step,
its own list and its own remove (or none). Paths are from the repository root.

| # | Path | Entry | Trust | Stored in | Remove |
|---|---|---|---|---|---|
| 1 | Add Machine | `machine.add` (`CmuxNextActions/Catalog/RemoteActionCatalog.swift:32`), `cmux-tui acp host enroll` (`acpmux/src/cli/host_enroll.rs`) | your ssh key; Tailscale peer list (`acpmux/src/tailnet.rs`) | app ssh registry + acpmux peer `ssh://HOST` | `remote.forget` drops the app record only; **the acpmux peer stays** |
| 2 | Connect to Machine, remote groups | `remote.connect`, `remote.newGroup` (`Handlers/RemoteGroupHandlers.swift`) | ssh | home session registry | `remote.forget` |
| 3 | Remote hosting | `cmux host enable|serve` tcp 7319 (`cmux-tui/src/remote_host/`) | Tailscale WhoIs = owner, or `host allow|grant` | `~/.cmux/host/remote.json` | `host deny|revoke`; **no app surface** |
| 4 | acpmux tickets | `cmux host ticket new`, `host join` (`acpmux/src/pairing/`), `install-static.sh` | one-use bearer ticket, wss or loopback only | `pairing.json` | `ticket revoke`; **no app surface** |
| 5 | Add Server | `server.addServer` (`Catalog/ServerActionCatalog.swift:25`), `cmux server pair` (`cmux-server/src/cli`), PairingDO (`backend/apps/api/src/pairing-do.ts`) | 8-symbol code + 4 words from the install key | TeamDO host `kind: server` | backend `server.revoke` exists; **app says "not available yet"** (`LocalServerSource.swift:123`) |
| 6 | Cloud Chief | `optchat-chief cloud pair` (reuses 5); `cmux-chief-tailnet up` (tsnet) | 5, or Tailscale login URL | TeamDO; your tailnet | 5; `down` |
| 7 | cmux Cloud VM | `newCloudMachine` | account | `MachineRegistry` | kill/delete |
| 8 | iPhone (new) | phone `PairMacStep` (`cmux-next-ios/.../Setup.swift:491`) | same account + "Allow iPhone?" on the Mac (`IPhoneHostService+Pairing.swift`) | Mac `MobileHostPairedDevices`, TeamHub `/v1/me/devices` | Settings > Mobile `remove_phone`; phone Settings > Devices |
| 9 | iPhone (old) | `palette.mobileConnect` QR (`Pages/MobilePairing/`) | account + 600 s ticket | web device registry | dashboard |
| 10 | cmux-tui web | challenge code in the TUI overlay (`cmux-tui-remote-access/src/pairing.rs`) | code, 8 h credential | in memory | expiry |
| 11 | machine-agent | `cmux machine-agent` (`cmux-tui/src/machine_agent/`) | cloud code | state file | none |
| 12 | Screen sharing | `cmux://remote-view` (`CmuxNextRemoteView/`), `cmux-rd-*` | debug only, live consent | none | none |
| 13 | Android | `adb` list for the Phone pane (`CmuxNextPhone/Android/`) | USB | none | none |

The seams a person sees:

- Settings > Machines' button opens **Add Server** (`webviews/src/pages/settings/components/HostSections.tsx:85`),
  while the same section's related actions and the sidebar `+` open **Add Machine**. Two adds, one
  section, no words that tell them apart.
- Forget is partial: a forgotten machine is still an acpmux peer and still runs agents for you.
- A paired server cannot be removed from the app.
- Tickets, teammate grants and remote hosting work from the CLI only; the app never shows them.
- Phones live in three lists (Mac file, TeamHub, web), servers in TeamDO, machines in two more.
- Three Tailscale integrations (acpmux `tailnet.rs`, `remote_host` WhoIs, Chief tsnet) share no
  device record.

## 2. The one flow

### 2.1 Words

One noun for the person: **device**. A device is a **computer** (Mac, Linux, Windows, a cloud VM)
or a **phone** (iPhone, later Android). "Machine", "server", "peer", "host", "node" stay as code
names; no screen uses them for the add flow. Each device row says in plain words what it can do:
"Runs your agents", "Can use this Mac's agents", "Can watch only", "Phone: approvals and
terminals".

### 2.2 One entry, everywhere

| Surface | Entry |
|---|---|
| App | action `device.add` "Add Device…" (palette, File menu, Settings > Devices, the right sidebar Machines `+`, the left sidebar background menu) |
| CLI | `cmux device add [HOST]` (the app's card) and `cmux device add HOST --yes` (headless enroll); `cmux-tui device …` on a machine with no app |
| MCP | `app_device_add`: opens the card only; a person presses Add (same rule as Add Server) |
| iOS | Settings > Devices > "Add a Computer" shows the same three ways with the phone as the scanner |
| New computer | `cmux device join`: prints a code, the 4 words and a QR in the terminal |

`machine.add` and `server.addServer` stay as aliases (scripts, muscle memory) and open the same
card on their way.

### 2.3 Three ways in one card

The card opens on the way that fits, with the other two one click away:

1. **On your network.** The computers your network already knows (Tailscale today, Weft later)
   that are not added yet, online first. One click runs the enroll (`acp host enroll`, path 1):
   reach, install, daemon, harness, peer, name. This is the default when the network has a
   candidate. A caption under the help says, before Add, that it needs ssh that signs in with a
   key, not a password (enroll's reach runs ssh in batch mode).
2. **It shows a code.** The new computer ran `cmux device join` (or the install line) and shows
   `XXXX-XXXX` and four words. Type the code (or scan the QR with the phone); the card shows the
   computer's name, OS and words under "Do these words match?"; Approve. This is path 5, unchanged
   on the wire (PairingDO), so cloud VMs, Linux boxes and Cloud Chiefs work with no tailnet.
3. **Set up a new device.** One line per OS to copy (`curl -fsSL https://cmux.com/install | sh -s -- join`,
   PowerShell for Windows), and for a phone the App Store QR. The new device then shows its code
   and the card moves to way 2. This is the Tailscale "Add device" page, with approval built in:
   nothing joins until a person approves on a device that is already in. For a computer (Mac,
   Linux or Windows) a row under the line keeps Other Computer… (add by host name) at hand, since
   the card opens here when the network lists nothing and a computer already reached with an ssh
   key needs no line (HQ #4877 break 5).

Approval always happens on a device that is already yours: the Mac card, or the phone's approval
sheet, or `cmux device approve CODE` in a terminal that is yours (the card's same intents, refused
from scripts and MCP).

### 2.4 One list: Devices

`cmux device list --json` and Settings > Devices show one row per device, merged from every
store: acpmux peers, paired acpmux devices and open invites, remote-hosting grants, the network's
nodes, and (in the app) phones, servers and cloud machines. A row has:

```json
{"id":"peer:mini-7","name":"mini-7","kind":"computer","os":"macOS","role":"runs-agents",
 "network":{"kind":"tailscale","address":"mini-7.tail1234.ts.net","online":true},
 "via":["peer"],"state":"connected","added_at":"2026-10-22T07:12:00Z"}
```

`state` is one of `connected`, `offline`, `pending` (waiting for approval), `error` (with a
reason a person can act on). `available` lists the network's computers that are not devices yet
(way 1).

### 2.5 One remove

`device.remove` (app, CLI `cmux device remove ID`, MCP) removes the device from **every** store
that holds it: the acpmux peer, the pairing credential (its open connections close at once), a
remote-hosting grant, the app's machine record, a phone pairing, a server's team record
(`server.revoke`). A removed device cannot reconnect without a new add. The confirmation says what
stops working, in plain words, before it runs.

A computer added with Add Device is in two lists: the sidebar's SSH machine and the acpmux peer
enroll added at the same `ssh://[user@]host`. Removing it from either removes both (HQ #4877
break 8): Settings > Devices Remove of a peer also forgets the SSH machines at that exact route,
and Forget Machine (`remote.forget`) also runs `acp host rm` for the peer at its route once its
Undo toast ends (so Undo brings both back: the peer was never removed), unless another of the
app's SSH sessions still uses that route. Routes match only exactly: the same host (any case),
the same user, and no ssh port on the machine.

### 2.6 One audit

Every add, approve, deny, remove, invite and failed join appends one line to the host audit log
(`~/.cmux/host/audit.jsonl`, 0600, the teammate-access log): `{"ts","event":"device.added",
"device","via","by"}`. `cmux device audit` and Settings > Devices > Recent activity read it. It
stays on the machine.

## 3. The network seam (Tailscale now, Weft later)

```rust
/// The overlay network that finds and reaches devices.
pub trait DeviceNetwork {
    fn kind(&self) -> NetworkKind;               // tailscale | weft | none
    fn status(&self) -> NetworkStatus;           // signed in, this device's name and address
    fn nodes(&self) -> Vec<NetworkNode>;         // every node: name, dns, ips, os, online, mine
}
```

- `TailscaleNetwork` reads `tailscale status --json` through `acpmux::tailnet` (the one Tailscale
  wrapper; `remote_host` already uses it for WhoIs).
- `WeftNetwork` (a527, `cmux-tui/crates/cmux-weft`) plugs in when its client library lands: the
  same nodes from the netmap. Until then it reports `none`.
- Choice: setting `devices.network` = `auto` (default: Weft when this device is enrolled in Weft,
  else Tailscale), `tailscale`, `weft`. The flow, the list and the remove do not change; only the
  candidates and the addresses come from the other network.

Nothing in the flow edits Tailscale ACLs, tags or keys, and nothing turns on `tailscale serve`.
A device that the network does not let us reach shows the fix in words ("Allow port 22 from your
devices in your Tailscale access controls"), never a silent change.

## 4. How the other parts fit

| Part | Fits by |
|---|---|
| acpmux / cmux-tui | the enroll (way 1) and peers are the device's agent link; `cmux-tui device` runs on any machine with no app |
| Daemon (`cmux host`) | remote hosting grants show as devices that can use this Mac; remove revokes them |
| Server, Cloud Chief, Freestyle VMs | way 2 (PairingDO code and words); Leo's network enrollment PRs (#22066, #21928) add their WireGuard keys after approval with no change to the flow |
| iPhone (Aziz) | phones are devices; the Mac's "Allow iPhone?" dialog becomes the same approval card; remove calls `revokePhone` and the TeamHub `DELETE /v1/devices/:id` |
| Screen sharing | a device row gets "Share Screen" when its host role is on; consent stays per session |
| Weft (a527) | section 3 |
| Android | a phone kind; no app yet |

## 5. Threat model

| Threat | Answer |
|---|---|
| A stranger runs `cmux device join` and guesses a code | 40-bit code, 10 minutes, one use, rate limit in PairingDO; the words must match; a person approves |
| A stolen code is approved for the wrong computer | the four words come from the joining computer's key; the card asks the person to compare them with the new computer's screen |
| A script or agent approves | approve is person-only (`ServerHeadlessApproval`); MCP and CLI `device add` only open the card |
| A removed device keeps access | remove revokes in every store; acpmux closes its open connections at once; servers drop at the next TeamDO flush |
| Enroll edits network policy | never: no ACL, key, tag or `serve` change |
| Audit tampering by another user | the log is 0600 in the user's home |

## 6. v1 (this change)

- `cmux device list|remove|audit|network` in cmux-tui (`cmux-tui/src/devices/`), with the pure
  merge, the `DeviceNetwork` trait and its Tailscale and Weft (none yet) sides, and audit lines.
- `device.add`, `device.list`, `device.remove` app actions; the Add Device card (AppKit) that opens
  on the right way and hands off to the Add Machine and Add Server cards.
- Settings > Machines becomes Settings > Devices: one list, Add Device, Remove per row.
- `remote.forget` also removes the acpmux peer (through `device.remove`).

Later: phone approval in the same card, server revoke from the app, iOS "Add a Computer", Weft
network, screen-sharing row action.
