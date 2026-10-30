# Remote groups: a host is a sidebar group, and groups nest inside it

Status: design + slices 1-6, 2026-10-20 (a283); part II (surfaces, protocol, transport, skew, offline) 2026-10-21. Owner lane: "Agents & routing".
Builds on: `remote-hosts.md` (tailnet host listener, `cmux host list|dial`),
`server-reach.md` (paired server sections), `cloud-subagents-DESIGN.md` (acpmux peers on
Freestyle VMs), `add-server-ui-DESIGN.md` (pairing card), `motion.md` (motion gate),
`plans/cmux-next/coordination/sidebar.md` (sidebar document contract).

## 0. Summary

The user asked for "remote groups, and nested groups for groups in the remote stuff", and for
Chief to move between this Mac, a Mac mini, a Linux VM and cmux cloud.

1. **A remote group is the machine section we already have, made first-class.** cmux-next's
   sidebar document already has one `machine` section per daemon session (`sec_m_<session>`),
   and remote hosts, paired servers and Cloud VMs already draw as one section each. What is
   missing is (a) one obvious action that makes one, (b) nesting inside it, (c) "new things
   here run there" everywhere, and (d) the health line on its header. We add those; we do not
   add a second "remote" object.
2. **Groups nest.** A group may hold groups, up to depth 3 (host > project > branch). The rule
   that every workspace of a group belongs to one machine now holds for the whole subtree, so a
   subtree never straddles two hosts.
3. **Inheritance is placement.** Where a new workspace is created decides where it runs: inside
   a remote group (at any depth) it is created on that group's machine, in the group's folder
   when the group names one. No per-workspace host picker is needed in the common path.
4. **Offline tolerant.** A remote group stays in the sidebar while its host is down: header
   shows `Reconnecting…`/`Offline since 14:02`, rows stay dimmed, actions queue only where the
   daemon already queues (we never fake local execution).
5. **Chief rides the same object.** Chief's placement (`chief.brain_place`) names a machine;
   "Move Chief To…" lists the same remote groups. Moving Chief is a remote-group operation, not
   a separate feature.

## 1. Competitive teardown

### 1.1 T3 Code (pingdotgg/t3code)

Sources: `docs/internals/remote.md`, `docs/user/remote-access.md` on t3code `main`
(read 2026-10-20).

| Aspect | T3 Code | Notes |
| --- | --- | --- |
| Unit | "environment": one server process (HTTP + WebSocket) that owns providers, execution, files and durable state | stable id across restarts and endpoint changes |
| Binding | a project and its threads belong to exactly one environment; nothing routes across environments | repo identity links clones across envs for display only |
| Reach | ordered route list per env: LAN, Tailscale, VPN, public URL, SSH (desktop-managed forward), T3 Connect relay; first answering route wins, earlier routes re-preflighted every minute and on network change; cooldown against flapping | learned routes from the server, user routes never edited |
| Pairing | one-time link/QR per device; secret in URL fragment; `t3 pair`, `t3 connect` | permissions are per route; reconnect does not refresh them, re-pair needed |
| Choosing an env | composer picks an env per draft; optional "Auto balance" across machines (Prefer / Less often / Manual only) | choosing a branch/worktree pins the draft to a machine |
| Install on host | first SSH launch downloads the server to `~/.t3/runtime`; `t3 service install` | Linux or Apple Silicon only |
| Sidebar | not documented; projects are listed per env | no nesting of envs or projects |
| Offline | idle tunnels cleaned after minutes; no offline view of an env's threads | open issue #8618: remote Stop gives no feedback, thread stuck "Thinking" |

Where it hurts (the user's "basic features become jigsaw puzzles"):

- Every feature must answer "which environment?" and nothing routes across them, so a feature
  that touches two machines (move a thread, compare branches, run a build on the mini while
  editing on the laptop) has no home.
- Version skew is the feature author's problem: capability checks per route and per server
  version, and different permissions per route.
- The env picker lives in the composer, per draft, so the place a thing runs is a transient
  choice, not something you can see in the list.
- No durable picture of an offline env.

### 1.2 Rex (superlogical.com/rex)

Sources: `rex/docs/linux/installation`, `rex/docs/linux/remote-access.md` (read 2026-10-20).
The Linux server is "not released yet" even to testers.

| Aspect | Rex | Notes |
| --- | --- | --- |
| Unit | one `rex` binary is both server and CLI; shared server (one `rex` account) or login server (PAM, one server per account) | packages: deb, rpm, apk, Nix; systemd or OpenRC |
| Reach | Unix socket by default; Tailscale (built-in tsnet node, Serve, or tailnet address), plain HTTP only with `--allow-anonymous` | identity from Tailscale; owner-only by default |
| Adding a host | Mac app "Add Remote Host…" with an address; CLI `rex hosts add build <url>`, `rex -S build` | host list is CLI-only and does not sync to the GUI or other machines |
| Terminal | ships `xterm-rex` terminfo and an SSH fallback snippet | |
| Grouping | none documented | |

Where it hurts: hosts are an address book, not a place in the UI; the CLI host list and the GUI
do not share state; no grouping, no offline view.

### 1.3 cmux-next today

| Aspect | cmux-next (feat-cmux-next, 2026-10-20) |
| --- | --- |
| Unit | a daemon session (`cmux-tui`), on this Mac, an SSH machine, a tailnet host (`cmux host serve`), a paired server, or a Cloud VM |
| Sidebar | one machine section per session (`sec_m_<session>`), groups inside it, one level deep |
| Reach | SSH (`remote connect ssh://`), tailnet listener (`cmux host dial`), Cloud link, paired server (SSH dev route; overlay planned) |
| Making one | several entrances: `remote connect`, `servers add --code`, `cloud new workspace`, Settings > Remote hosting |
| Agents | acpmux peers (a242), Chief brain placement (server-reach.md) |
| Gaps | no single "New Remote Group…", no nesting, new-workspace inheritance is per entrance, health shown only as a dim header, Chief move is a separate flow |

### 1.4 How cmux wins

1. **Place, not picker.** Where a row sits is where it runs. T3's per-draft env picker and Rex's
   `-S host` flag both make the user remember; cmux shows it.
2. **Nesting.** host > project > branch mirrors how people actually work remotely; neither
   competitor nests.
3. **One object for people and agents.** A Chief, a subagent, a terminal and a browser tab all
   live in the same remote group; "move Chief to the Linux VM" is a drag of the Chief row, not
   a migration.
4. **Offline is a state, not a disappearance.** The group stays with its last layout; reconnect
   is automatic with backoff (we reuse T3's best idea: ordered routes with preflight and
   cooldown, which `MachineRegistry` routes already model).
5. **One state everywhere.** The sidebar document syncs through the home daemon, so the CLI,
   MCP, the Mac app and iOS see the same remote groups (Rex's CLI-only host list is the
   anti-pattern).

## 2. Requirements made testable

| # | Requirement | Testable form |
| --- | --- | --- |
| R1 | groups nest inside a remote group (host > project > branch) | sidebar doc accepts `group` under `group` up to depth 3; refuses depth 4 (`nesting`), a cycle (`invalid_target`), and a subtree with workspaces of two machines (`cross_machine`) |
| R2 | moving a group moves its whole subtree | `move` of a parent group to another section carries children and grandchildren |
| R3 | closing the last workspace removes empty ancestors (machine sections only) | `close` cascades up through empty groups, never into a pinned/custom section |
| R4 | flat rows carry depth | `view` rows: top-level group depth 0, its subgroup 1, the next 2, a workspace in that one 3; `parent` = its own group; a collapsed group hides its whole subtree; a text filter shows the path of groups to a match |
| R5 | one action makes a remote group | `remote.group.new` (palette "New Remote Group…", sidebar `+` menu, CLI `cmux remote group new <host>`, MCP) connects or reuses the host and returns its section id |
| R6 | new workspaces inherit the host | `workspaceGroup.newWorkspace` creates on the machine all the group's members run on (`GroupSpawnHost`), and refuses with "machine not connected" when that host is offline; before slice 1 it always created on this Mac |
| R7 | health on the header | header shows `Connected`, `Reconnecting…`, `Offline since HH:MM`, `Sign-in needed` from `MachineRegistry` link state |
| R8 | motion | nested expand/collapse and reorders go through the motion gate category `sidebar` (a274) |
| R9 | 21 locales | every new string in `Localizable.xcstrings` for all 21 locales |

## 3. Data model

The sidebar document (`cmux-layout-reducer::sidebar_doc`) is the single home of placement. It
already has `Item.parent` and view rows with `depth`. Change:

- `check.rs`: an item's parent is a group of the same section; a group may have a parent group
  when the resulting depth is at most `MAX_GROUP_DEPTH` (3 levels of groups). The parent chain
  must not cycle. `cross_machine` is checked over the nearest machine-bearing ancestor chain:
  every workspace under a top-level group (at any depth) is of one machine.
- `reduce.rs place`: a group may move under a group when depth(target) + height(moved) fits;
  moving a group under itself or its descendant is `invalid_target`; children (and their
  children) follow a group that changes section.
- `reduce.rs close`: an emptied group is removed, then its parent if emptied, up the chain.
- `check.rs repair`: nested rows deeper than the limit, or forming a cycle, are lifted to the
  top level of their section (repair never deletes).
- `view.rs`: a row's depth is its number of group ancestors (top level 0).
- `accept.rs`: drag acceptance uses the same depth rule and treats a dragged group's whole
  subtree as `self`.

Old daemons refuse nested groups with `nesting`; clients gate the "New Subgroup" UI on the
daemon capability `sidebar.nested_groups` so a newer app against an older home daemon degrades
to flat groups.

No new section kind. A "remote group" is a `machine` section whose session is not the home
session. Its title defaults to the host name and is editable (existing `title`).

## 4. Making a remote group (one action)

`remote.group.new {host}`:

1. Resolve `host` against, in order: existing machine sections (reuse), `cmux host list`
   tailnet peers, paired servers (`team.hosts.list`), `~/.ssh/config` aliases, Cloud machines.
2. Connect through the existing path for that kind (`cmux host dial`, `remote connect`, Cloud
   link). Nothing new is installed by this action except what `remote install` already does
   with the user's OK on first connect.
3. Add the machine section (existing `section.add` with `kind: machine`), expanded, scrolled
   into view, and select its empty-state row "New Workspace on <host>".

Entrances (one shared action path): palette "New Remote Group…", sidebar `+` menu, sidebar
empty-area right-click, group-header right-click "Move Group to Remote…", CLI
`cmux remote group new <host> [--name N]`, MCP `app_remote_group_new`.

## 5. Health and reconnect

`MachineRegistry` link state drives the header. States: `connected`, `connecting`,
`reconnecting(attempt, next)`, `offline(since)`, `auth_needed`, `incompatible(version)`.
Reconnect: on app activation, network change, sidebar open and with capped exponential
backoff (1 s → 60 s), never a tight timer. Header right-click: "Reconnect Now", "Disconnect",
"Show Host Info…", "Forget Host…" (destructive, confirms).

Offline: rows stay with their last titles, dimmed; opening one shows "Host offline: reconnect"
instead of a blank terminal. Creating a workspace in an offline group is refused with that
message; we never run it locally by surprise.

## 6. Chief

Chief's placement (`chief.brain_place {host}`) names a machine. "Move Chief To…" in the Chief
menu lists remote groups (this Mac, Mac minis, Linux VMs, Cloud). The move itself is
server-reach.md's and cloud-chief-vm.md's job (save turn, stop, start on target, resume); this
design only makes the target list the remote groups, so a remote group added once is a Chief
target everywhere. Durable Objects (cmux cloud) appear as one more machine kind when that
reach lands (object-sync phase 3).

## 7. UI mocks

Three layouts were mocked (gallery in Home's right pane,
`plans/cmux-next/remote-groups-mocks/index.html`):

- **A. Host header + nested groups (Recommended).** The machine section header gets a host
  glyph (laptop / mini / Linux / cloud), the host name, and a status dot + short status text at
  the trailing edge. Nested groups indent 12 pt per level with the existing group color bar.
  The section's `+` creates a workspace on that host.
- **B. Host chip rows.** Hosts drawn as group rows inside one "Remote" section. Rejected: makes
  hosts look like ordinary groups and breaks "one section per machine" in the document.
- **C. Host switcher.** A host picker at the top of the sidebar filters the list to one host.
  Rejected: hides cross-host work, which is the point of the feature.

## 8. Slices

| Slice | Work | Done when |
| --- | --- | --- |
| 1 (landed) | design + teardown + mocks; nested groups in the sidebar document (Rust); group "New Workspace" inherits the host (R6) | reducer tests R1-R4 and `GroupSpawnHostTests` red before, green after |
| 2 | the list draws nested groups: `SidebarGroup.parent/depth`, `SidebarRow.depth` (one gutter per level, `SidebarListView.frame(for:)`), a collapsed group hides its subtree, a filter keeps the path to a match; the projection lists each nested group with its own members; drag acceptance nests a group within 3 levels | `SidebarNestedGroupLayoutTests`, `SidebarDocNestedGroupProjectionTests`, Rust `drag_nests_a_group_within_the_depth…` |
| 3 | "New Subgroup" (`workspaceGroup.newSubgroup`: group menu, palette, CLI `workspace-group new-subgroup`, MCP; `SidebarDocSubgroupPlan` refuses past 3 levels) | `WorkspaceSubgroupActionTests`, `SidebarDocSubgroupPlanTests` |
| 4 | "New Remote Group…" (`remote.newGroup`: palette, sidebar background menu, CLI `remote new-group <host>`, MCP): connects the host as `remote.connect` does and marks its machine section `host_group`, which keeps its header in one list | Rust `host_group_tests`, `SidebarHostGroupLayoutTests`, `RemoteGroupActionTests` |
| 5 | a remote group's header names every state (Connected, Connecting…, Reconnecting…, Offline, Unreachable…); "Remove Remote Group" (`remote.removeGroup`, header menu of a remote group only) unmarks it without disconnecting; SSH hosts keep their Reconnect/Disconnect/Forget menu | `HostGroupHeaderStatusTests`, `RemoteGroupRemoveActionTests`, `SidebarDocHostGroupPlanTests` |
| 6 (landed) | "Move Chief To…" (`chief.moveTo`, palette; `cmux chief move --to` and the Chief's MCP `move` tool are the CLI and MCP): This Mac (`local:<home>`), SSH remote groups (`ssh:<destination>`), paired servers greyed out "not supported yet", cmux Cloud (`cloud` / `cloud:staging`, from the app's auth; one entry, Cloud VMs are not targets) greyed out until signed in, offline hosts greyed out. Dry run report, confirm, move, then `move reach` on the target; the Cloud token goes through a 0600 file in a 0700 folder, deleted after | `ChiefMoveTargetsTests`, `ChiefMovePlanTests`, `ChiefMoveTargetHomeTests`, `ChiefMoveActionTests`, `CmuxDialogDisabledOptionTests` |

### 8.1 Interface offered to a284 (Chief move)

A Chief move target is a remote group: the document's machine sections with `host_group: true`
(`SidebarDocRecords.sections[…].hostGroup`), each named by its daemon session (`sec_m_<session>`),
with the machine's name, kind (ssh, server, cloud) and live status from `MachineRegistry`. This Mac
is always a target. a284's "Move Chief To…" menu lists those; the move itself (save the turn, stop,
start on the target, resume) stays a284's.

### 8.2 Known gaps after slice 5

- Paired servers and Cloud machines got a Reconnect row (`machine.reconnect`) after slice 5.
- "Offline since HH:MM" shows as "Offline": the machine model has no offline time yet.
- New Remote Group takes SSH destinations (aliases, tailnet names); a tailnet host found by
  `cmux host list` and a Cloud machine become remote groups only through their own connect today.
- A group dragged into a group in the classic (non-document) sidebar path is not supported; the
  document path is the one shipped.

## 9. Open items

1. Depth limit 3 is a product choice (host > project > branch). Deeper trees are refused, not
   truncated.
2. Should a remote group carry a default folder per nested group (project root)? Proposed:
   `extra.cwd` on a group body, inherited by new workspaces; slice 2.
3. The Swift `SidebarGroup` value holds `workspaces` only; slice 2 adds `subgroups` and keeps
   the snapshot-boundary rule (value snapshots, no store references in rows).

---

# Part II: every surface in a remote group (2026-10-21, Remote groups agent)

User (Oct 22): "remote groups ... each group is kinda just a cmux-tui instance? ... cloud machines
as well as my own mac mini or linux server or other macbook ... enumerate everything that's open
... file viewer, diff viewer, acp chat, terminals, browsers, literally everything."

## 10. Verdict on the model

**Yes, and it is already the model in the code.** A remote group is one cmux-tui daemon (headless,
no UI) on the remote machine. The Mac app, `cmux-tui`, iOS and Cloud Chief are clients of that
daemon over the one versioned protocol (raw v12 lines + `cmux.protocol/2` streams;
`cmux-tui-contract.md`). The Mac app is already a client of its own local daemon, so local and
remote take one code path. Part I (sections 0-9) is the sidebar half of this; Part II is the
surface half.

Chief's take, checked point by point:

| Claim | Verdict | Evidence |
| --- | --- | --- |
| one headless daemon per host, one protocol for every client | agree, exists | `cmux remote connect ssh://…` installs the pinned `cmux-tui` (`cmux-remote/src/ssh_bootstrap.rs`) and splices the unchanged daemon protocol; `cmux host serve` does the same over the tailnet (`remote-hosts.md`) |
| Mac app is only a client of its local host | agree, exists | `CmuxNextDaemon` / `MachineRegistry.daemon(for:)` |
| each surface is a protocol object | agree, with one change: the browser **runtime** stays on the viewing Mac by default | `remote-state-ownership.md` 3.5 (decision 2026-10-01); streaming (`rb/1`) is the opt-in for hosts the Mac cannot reach |
| discovery: host enumerates everything open and pushes changes | agree, exists | `list-workspaces` + `subscribe` (tree snapshot + events, `cmux-tui-contract.md` 2.3) |
| transport: tailnet or SSH stdio bootstrap (VS Code Remote style) | agree, both exist | SSH: `remote connect ssh://`; tailnet: `cmux host serve|dial`; also `ws(s)://`, `iroh://`, relay routes, `--wireguard-config` |
| version skew and offline must be handled | agree, partly done | SSH bootstrap probes `remote-probe --json` (protocol, build identity, capabilities) and installs or `--upgrade`s; offline header states landed in slice 5; offline **content** (read-only cache) does not exist (section 15) |
| per-host auth, per-user later | agree, exists for owner | SSH = the user's SSH identity; tailnet = WhoIs owner check before any byte, `cmux host allow <login>` for teammates |

What I would not do: a second "remote" implementation of any surface, a per-surface tunnel, or a
remote-only protocol. Every gap below is closed by routing an existing Swift surface to the
pane's machine daemon (`machines.daemon(for:)`), never by a new server.

## 11. Inventory: what already works remotely (feat-cmux-next 9d0545d50eb, nightly 3970568398401)

Verified end to end on 2026-10-21 against a Linux arm64 VM (OrbStack `mux-linux`, Ubuntu) with
`scripts/cmux-next/remote-group-e2e.py` (headless bridge, no app state changed):

| Check | Result |
| --- | --- |
| SSH bootstrap, first connect (installs pinned `cmux-tui` linux-aarch64) | connected < 90 s |
| reconnect (daemon already installed) | 0.5 s |
| enumerate: `workspace list`, `terminal list` | answers; a workspace made by an earlier bridge was still there after that bridge exited (host-owned state) |
| terminal: create workspace in a folder, type, read screen | `rg-e2e-…-Linux` read back |
| diff: `git status`, `git diff --patch` on the host | patch `+changed` returned |

Code that exists (read, not all run here):

| Piece | Where |
| --- | --- |
| SSH reach + install + upgrade + reconnect | `cmux-tui/crates/cmux-remote` (`ssh_bootstrap.rs`, `provider/ssh.rs`), app `SSHService`, `remote.connect`, `remote.install`, `remote.reconnect` |
| tailnet reach | `cmux-host` (`cmux host enable|serve|dial|list`), owner WhoIs admission |
| Cloud VMs | `CmuxNextCloud`, `cloud-subagents-DESIGN.md` (acpmux peers on Freestyle VMs) |
| remote group sidebar object | Part I slices 1-6 (`remote.newGroup`, header states, nesting, Move Chief To…) |
| terminals | daemon PTYs, attach stream, resize, scrollback (`terminal-snapshot-history-v1`) |
| files | daemon `fs.stat|list|read|write|mkdir|rename|delete|pick` (`cmux-tui-core/src/fs_ops`) |
| git / diff | daemon `git.status|diff|branches|files|commit|push|checkpoint.*|worktree.*`; the diff tab calls "the session host's" git (`DiffPageProvider+Git.swift`) |
| ACP chats | acpmux runs on the machine that owns the workspace; G2 attach path (`agent-session-attach-v1`, `RemoteAcpmuxWire`); `cmux acp host add` peers |
| browser reach to host ports | `remote-localhost.md` (stages 1-3 built, Chromium), `loopback-forward-v1`; a464's `workspace-proxy-DESIGN.md` (f432d56) with per-profile app proxy and proposed `terminal ports` discovery |
| browser streamed from host | `remote-tab-protocol.md` (`cmux.rb/1` on `cmux.rd/1`), crates `cmux-remote-browser*`, `cmux-rd-*` |

## 12. Surface matrix

"Owner" is where the object's state and process live. "Client path" is how the Mac app shows it.

| Surface | Owner | Protocol object | Client path today | Status in a remote group | Gap / next slice |
| --- | --- | --- | --- | --- | --- |
| Terminal | host daemon | PTY + attach stream, resize, scrollback, OSC 133/7501 status | GhosttyKit bytes from the pane's daemon | **works** (verified Linux) | none for v1 |
| Workspace / pane / tab tree | host daemon | tree snapshot + `subscribe` | sidebar machine section | **works** | offline cache (15) |
| Diff viewer | host daemon (`git.*`) | `git.status`, `git.diff`, stage/commit/push | `DiffPageProvider` → session host | daemon side **verified**; app routing by pane machine **unverified** | slice C: app-level check that a diff tab in a remote workspace calls the remote daemon |
| File viewer / Files pane / file grid | host daemon (`fs.*`) | `fs.list|stat|read|write`, `fs.pick` | `CmuxNextFiles` reads **local** `FileManager` | **gap**: shows this Mac's disk | slice B: a `FileSource` protocol with `LocalFileSource` and `DaemonFileSource(fs.*)`, picked by the pane's machine; watch via an `fs.watch` stream (new daemon verb, capability `fs-watch-v1`) |
| Markdown / HTML / image preview | host daemon (`fs.read`) | same as files | local file read | **gap** (same cause as files) | rides slice B |
| ACP chat | host acpmux, supervised by host daemon | `agent-session-*` verbs over the link | `AgentTabStore.open` via `machines.daemon(for:)` | attach **exists**; new-chat verbs (`agent-session-new`, harness catalog, draft) per `remote-state-ownership.md` 3.4 **open**; origin policy D10 open | slice D: those verbs + "Claude Code is not installed on <host>" install row |
| Browser (default) | record in host daemon, runtime on the viewing Mac | tab record + `loopback-forward-v1` | Chromium tab with remote localhost (`remote-localhost.md`, a464 proxy) | **works for Chromium**, WebKit stays "this Mac" | port discovery (`terminal ports`, a464) |
| Browser (streamed) | Chromium on the host | `cmux.rb/1` over `cmux.rd/1` | `CmuxNextRemoteBrowser` | prototype | later; only for hosts the Mac cannot reach or must not hold cookies for |
| Notifications, status, agent state | host daemon | events on `subscribe` | sidebar dots, Home | **works** (same stream) | none |
| Chief | the machine named by `chief.brain_place` | Chief protocol | Move Chief To… (slice 6) | **works** for SSH targets | Cloud/tailnet targets (a284) |
| Remote desktop | host `cmux-rd-host` | `cmux.rd/1` | `CmuxNextRemoteView` | separate feature (`remote-desktop-DESIGN.md`) | out of scope |

## 13. Transport and reach (one ordered route list per host)

Per host, `MachineRegistry` keeps routes in order, first answering wins, re-preflight earlier
routes on network change (T3's best idea, Part I 1.4):

1. tailnet `cmux host dial` (no SSH key setup, identity from the tailnet) — Mac minis, other Macs
2. SSH (`ssh://alias`), bootstrap installs/upgrades `cmux-tui` — any Linux server, any Mac
3. Cloud link (`ws(s)://` with `--carrier` inside the owner's private network, or relay) — Freestyle VMs
4. relay routes (`relay+wss://`, `iroh://`) when no direct path exists

Targets map: Freestyle VM → 3 (2 as fallback); Mac mini / other MacBook → 1 then 2; Linux server → 2
(1 when it runs tailscaled + `cmux host serve`).

Tailnet policy (cmuxterm-hq #2982, 75bc7f7, live 2026-10-21, a459): the Cloud Chief tag,
`chief-dev-vm` (`tag:lawrence-devvm`) and per-agent VMs (`tag:agent-cloud`) reach
`tag:mac-mini-cluster` on 22/5900/8787/31415, cmux17-24 by IP on 22/5900 and `tag:macbuilder` on
22/5900; cmux16 stays blocked. Update (cmuxterm-hq #2990, 6d9bc62, live): tcp 7319 (`cmux host serve`) is
now open from `tag:lawrence-chief`, `tag:lawrence-devvm` and `tag:agent-cloud` to the same
destinations. Nothing listens on 7319 on the minis yet ("connection refused"), so route 1 from
cloud to a mini works only after `cmux host enable` (per-user service running `cmux host serve`)
on each mini; until then SSH (route 2) is the working route. SSH keys for user `chief` exist only on cloud-chief and chief-dev-vm.

## 14. Auth, version skew

- Auth: SSH identity or tailnet WhoIs owner, checked per connection before any protocol byte;
  teammates by explicit `cmux host allow <login>` (multiplayer, a461's TeamDO records later
  name who may attach). Relay allowlist stays default deny (`remote_relay/gate.rs`).
- Skew: the client reads `remote-probe --json` (protocol, build identity, capabilities) and the
  daemon capability list on connect. Rules: (a) protocol major mismatch → header
  `Update needed`, one click runs `remote install --upgrade` (terminals survive, RPC state resets);
  (b) a missing optional capability hides only that surface's UI (e.g. no `fs-watch-v1` → file
  viewer polls on focus, never a timer); (c) never auto-upgrade a host the user did not install
  through cmux. Seen today: the Mac mini `cmux-lawrence` has a `~/.local/bin/cmux-tui` from Aug 5,
  so the first connect there goes through the install/upgrade offer.

## 15. Offline

Today: the header names the state and rows dim (slice 5). Missing: content. Plan: the client
keeps the last tree snapshot per host (already in memory) and persists it per `registry_id` in the
app's state dir; an offline group draws from it read-only (titles, cwd, last screen text of each
terminal from `terminal-snapshot-history-v1`, last diff summary). Actions that need the host are
refused with "Host offline: Reconnect", never run locally. Object-sync phase 3 (HostDO replicas)
replaces this cache for cloud-synced hosts.

## 16. Performance budget

| Path | Budget | Today |
| --- | --- | --- |
| reconnect to an installed host (LAN/tailnet) | < 1 s to tree drawn | 0.5 s to connected (Linux VM) |
| first connect incl. install | < 90 s, progress shown | < 90 s |
| keystroke echo in a remote terminal | RTT + 1 frame | bytes path, no extra hop |
| enumerate 100 workspaces / 500 terminals | one snapshot, < 50 ms decode on the Mac | not measured |
| file viewer open (≤ 1 MB file) | RTT + 30 ms | n/a (slice B) |
| diff of 500 files | counts first, patches on demand (`--patch` per file) | fingerprint path exists (cx-9ce.34) |
| idle cost of a connected group | 0 timers; heartbeats only on the link | heartbeat interval configurable |

## 17. Slices from here

| Slice | Work | Done when |
| --- | --- | --- |
| A (landed with this part) | design part II; `scripts/cmux-next/remote-group-e2e.py` proves bootstrap, enumerate, terminal round trip, git status/diff on any SSH host, headless | script green on a Linux host (done: OrbStack Ubuntu arm64) |
| B | file viewer / Markdown / image preview read through the pane's daemon (`DaemonFileSource` over `fs.*`); `fs.watch` stream verb | Swift test: a Files pane in a workspace of a fake remote daemon lists the daemon's entries, not `FileManager`'s (red first); fleet build |
| C | diff tab in a remote workspace calls the remote daemon | Swift test with two fake daemons; live check with the e2e host |
| D | ACP new chat in a remote group (`remote-state-ownership.md` 3.4 verbs), harness-missing row | daemon tests + live chat on the Linux host |
| E | New Remote Group lists discovered hosts: `cmux host list` tailnet peers, SSH aliases, Cloud machines (Part I 8.2 gap) | `RemoteGroupDiscoveryTests`; picking a tailnet host makes a remote group without SSH |
| F | offline read-only cache (section 15) | test: kill the bridge, group still lists last workspaces and screen text, actions refused |
| G | skew: `Update needed` header + one-click upgrade | test with a probe that reports an older protocol |

## 18. Issues hit while building part II

- SSH destinations of the form `user@container@orb` (OrbStack) are refused ("SSH destination is
  not shell-safe"): the URL parser percent-encodes the inner `@`. Workaround: an SSH alias. Low
  priority; fix with a test when slice E touches destination parsing.
- `cmux remote new-group <host>` (Part I's CLI name) prints the TUI's `remote` usage: the
  `remote` scope of the bundled CLI shadows the app action. `cmux action run remote.newGroup
  --destination <host>` works. Fix belongs with slice E.
- An agent cannot screenshot the app window (`window.screenshot` is person-only), so app-level
  remote-group checks need the fleet's UI harness, not an agent shell.

## 19. Stable ids for a host (answer to a461, cloud groups slice 1)

No new id is needed: every daemon already serves three stable ids. Use them as below.

| Id | Form | Minted | Stable across | Served by | Use it for |
| --- | --- | --- | --- | --- | --- |
| machine id | `machine_<32 hex>` | once per state root, `load_or_create_machine_id` (`cmux-tui-core/src/workspace_registry.rs`), a locked file in the daemon's state root | daemon restarts, upgrades, reconnects, route changes (SSH ↔ tailnet ↔ relay), host renames | `machine.list` (`id`), `identify` with machine metadata (`machine_id`); Swift `DaemonIdentity.machineResourceID` | **the host in a cloud group record**: "this group lives on machine X" |
| session resource id | `session_<32 hex>` | once per daemon session | as above | `identify` (`session_resource_id`), `workspace list` (`session_id`); Swift `DaemonIdentity.sessionResourceID` | one daemon session on that host (a host can run several sessions) |
| registry id | UUID v4 | once per session database (`meta.registry_id`) | as above | `identify`, every tree delta and `workspace` reply (`registry_id`); Swift `DaemonIdentity.registryID`, `DaemonStore.registryID` | local placement only: sidebar section `sec_m_<registry_id>`, remote-localhost routing |

Rules:

1. A group record names `{machine_id, session_resource_id}`. Never a host name, an SSH alias, a
   tailnet IP or a Cloud VM id: those change (a Cloud VM is re-provisioned, a Mac is renamed, a
   route moves from SSH to tailnet). For a Cloud VM, the daemon's own `machine_id` is also the id,
   and the Cloud VM id is only a route to it.
2. All three ids change only when the daemon's state root is deleted. That is a new machine on
   purpose: its workspaces are gone too. A record that names an unknown `machine_id` draws as
   "Machine not found" with Forget, and is never matched to a new host by its name.
3. Read `machine_id` from `machine.list` or `identify` with machine metadata on, after connect.
   Older daemons without `machine-identity-v1` have no `machine_id`: a cloud group then refuses
   to bind (`incompatible(version)` header, section 5) and does not fall back to `registry_id`.
