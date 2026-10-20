# Remote groups: a host is a sidebar group, and groups nest inside it

Status: design + slice 1, 2026-10-20 (a283). Owner lane: "Agents & routing".
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
   "Move Chief to…" lists the same remote groups. Moving Chief is a remote-group operation, not
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

Chief's placement (`chief.brain_place {host}`) names a machine. "Move Chief to…" in the Chief
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
| 1 (landed) | design + teardown + mocks; nested groups in the sidebar document (Rust); group "New Workspace" inherits the host (R6); failing-first tests | reducer tests R1-R4 and `GroupSpawnHostTests` red before, green after, on the fleet |
| 2 | Swift: render nested groups from doc rows (indent, collapse per group), "New Subgroup" in group menu, capability gate | tagged app shows host > project > branch |
| 3 | `remote.group.new` action (palette, `+` menu, CLI, MCP, 21 locales) | one action from nothing to a usable remote group on a Mac mini |
| 4 | header health line and reconnect menu; offline refusal message | killing the host listener shows Offline, restoring it reconnects |
| 5 | Chief "Move Chief to…" lists remote groups | Chief moves from this Mac to a mini from that menu |

## 9. Open items

1. Depth limit 3 is a product choice (host > project > branch). Deeper trees are refused, not
   truncated.
2. Should a remote group carry a default folder per nested group (project root)? Proposed:
   `extra.cwd` on a group body, inherited by new workspaces; slice 2.
3. The Swift `SidebarGroup` value holds `workspaces` only; slice 2 adds `subgroups` and keeps
   the snapshot-boundary rule (value snapshots, no store references in rows).
