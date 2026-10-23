# Cloud groups: a sidebar group that lives in the cloud, links everywhere, and is the unit of sharing

Status: design, 2026-10-22 (a461). Owner lane: "Agents & routing".
Ask (Lawrence, Oct 22): "how do we make cloud work better so Chief can link to it? a grouped group for
everything in cloud, or groups that only live in the cloud? explore the search space ... lowkey groups
in cloud might be the move ... and how do we make multiplayer work too".

Builds on (read before changing this):
[object-sync/DESIGN.md](object-sync/DESIGN.md) (TeamDO directory, HostDO replica, `cmux.wire/1`),
[state-placement.md](state-placement.md) (a fact lives where its single writer is),
[remote-groups-DESIGN.md](remote-groups-DESIGN.md) (a283: machine sections, nested groups, `cross_machine`),
[durable-links-DESIGN.md](durable-links-DESIGN.md) (`cmux://tab/<id>` that always resolves),
[cloud-subagents-DESIGN.md](cloud-subagents-DESIGN.md) (a242: subagents as acpmux peers on Freestyle VMs),
[teammate-access-DESIGN.md](teammate-access-DESIGN.md) (consent, scopes, audit),
[chief-group-chats-DESIGN.md](chief-group-chats-DESIGN.md) and `home-dm-group-chats/` (a132/a287),
[agent-cursor.md](agent-cursor.md) and the a201 glass cursor, [pricing-DESIGN.md](pricing-DESIGN.md)
(one credits ledger, a205), cmuxterm-hq `plans/agent-cloud/DESIGN.md` and `plans/cloud-chief/REPORT.md`
(the agent hub, now `cloud-chief-hub` on 100.127.110.65:8790), cmuxterm-hq
`plans/multiplayer-chief/DESIGN.md` (owner/member/guest on one Linux box).

## 0. Summary

1. **A cloud group is a group whose record lives in the cloud, not on a Mac.** Its id
   (`grp_` + 20 lowercase hex, TeamDO's `ctx.newId`) is minted by the server, never by a client. Its name, color,
   icon, member list, roles and the list of its workspaces (with each workspace's placement) are
   rows of the team's `TeamDO`. Any Mac, the iPhone, the web and any Chief (this Mac's, Cloud
   Chief, a teammate's) read the same record, also when the Mac that made it is asleep.
2. **Contents stay at their home.** A workspace in a cloud group still runs where it runs: this
   Mac, a Mac mini, or a Cloud VM. The group shows each workspace's placement with a badge, and
   "Move to..." changes it. The group is the address book and the sharing unit; it is not a
   second copy of anyone's terminals.
3. **Links resolve everywhere.** `cmux://group/grp_…` and `https://cloud-api.cmux.dev/g/grp_…` open the group
   on any device. When a workspace's host is offline, the link opens a read-only mirror of its
   last published state (HostDO replica) with "Host asleep since 14:02".
4. **Chief links only what it reads back.** A Chief never writes a group id from memory or from
   a create call alone: it calls `group.list`/`group.get` and links the id in that answer.
5. **Multiplayer = share a group.** Members with roles owner/edit/view; presence and cursors on
   the a201 glass cursor; who is typing per terminal; one writer per terminal at a time (a soft
   lock with takeover); agents have an owner; every op is in the group's audit log.
6. **Recommended**: cloud-only groups (option B, section 7), drawn under one "Cloud" sidebar
   section. Not a mirror of local groups (A), and not a single "Cloud" meta-group (C).

### Transport: the a473 host-daemon model (user, 2026-10-22)

The user asked that cloud groups and multiplayer sit on a473's remote-groups model: one
headless cmux-tui daemon per machine (Cloud VM, Mac mini, Linux server, another MacBook), one
protocol for terminals, files, diffs, ACP chats and browsers
([remote-groups-DESIGN.md](remote-groups-DESIGN.md) sections 10-18, a473's part II, commit
5407956b2c0; a Cloud VM is one more route there, section 13). That document is the base of this
one. So a cloud group adds no
transport. It is only the cloud **record**: id, name, members and roles, and the list of `ws_`
ids with each one's placement. Placement names a machine of that model (`placement.host` = the
daemon session / `host_` id, `placement.machine` = a Cloud VM's `machine_` id). Opening,
mirroring and moving a workspace all go through that host protocol; a Cloud VM is one more
machine kind there.

### Default picked: the authority is `TeamDO`, not the agent hub

The task named the agent hub (`cloud-chief-hub`, 100.127.110.65:8790) as the source of truth. I
picked `TeamDO` in cmux Cloud instead, and the hub becomes a client. Reasons, each checked:

| Need | Agent hub (`hub.py`, SQLite on the Cloud Chief VM) | `TeamDO` (cmux Cloud Worker) |
|---|---|---|
| iPhone opens a link | No. The tailnet ACL denies :8790 from the iPhone (cloud-chief REPORT, "Hub moved onto this VM") | Yes, public HTTPS, account sign-in |
| `https://` link for a teammate | No public address; tokens are hub macaroons, not cmux accounts | Yes, Stack account, team membership |
| Mac asleep | Yes | Yes |
| Members and roles | No: one owner token plus attenuated tokens per box | Yes: `team-roles.ts` owner/admin/member/billing/guest, `roleHas` grants |
| Host offline mirror | No | Yes: `HostDO` replica (`host-replica/store.ts`) already stores the last snapshot + tail per host stream |
| Durability | One VM, one SQLite file (the hub VM was already deleted and moved once) | DO SQLite + PlanetScale projection (state-placement rule) |
| Billing | None | Team plan, seats, credits ledger |

The hub stays what it is good at: the agent message bus. Each cloud group gets a hub box
`group:<grp_id>` for agent-to-agent chatter in that group (section 6.5), so Cloud Chief and
subagents on Freestyle VMs keep using `hub.py post/read` with a token attenuated to that box.

Flagged as a possible bad decision: this makes slice 1 a backend change (Worker + DO migration,
staging then prod) rather than a 50-line `hub.py` table. I accept that because a hub-only
version cannot meet the iPhone and teammate requirements, so it would be thrown away.

## 1. Search space

The question "how does cloud work better so Chief can link to it" has five axes. Each row is a
choice; the bold cell is the pick.

| Axis | Choices |
|---|---|
| Where the group record lives | a Mac's daemon (today) / Mac + cloud mirror / **cloud (TeamDO)** / the agent hub |
| What "in the cloud" means for a workspace | its record only / **record in cloud, contents at its home (Mac, mini, VM)** / everything in a VM |
| What a link names | a title / a local numeric handle / a Mac-local `ws_` id / **a server-issued `grp_`/`ws_` id with `cmux://` and `https://` forms** |
| Sharing unit | the whole team / a workspace / a terminal / **a group** |
| Sidebar shape | a "Cloud" meta-group / one machine section per VM (a283) / **a "Cloud" section that holds cloud groups, with placement badges on rows** |

## 2. Requirements made testable

| # | Requirement | Testable form |
|---|---|---|
| G1 | server-issued stable id | `group.create` returns `grp_[a-z0-9]{20}`; a client-supplied id is refused `invalid_argument`; the same idempotency key returns the same id |
| G2 | resolves on every device | `group.get {group}` answers the same record to the Mac app, the iPhone app, the CLI and Cloud Chief, signed in as a member |
| G3 | Mac asleep | with the creating Mac's daemon stopped, `group.get` and `https://cmux.com/g/<id>` still answer; rows of workspaces homed on that Mac show `offline since` |
| G4 | universal link | `DeepLink.parse("cmux://group/grp_…")` → `.group(id)`; `https://cmux.com/g/grp_…` → same; Universal Link on iOS |
| G5 | per-workspace placement badge | each row carries `placement: local(host_…) / mini(host_…) / cloud_vm(machine_…)`; the badge glyph and tooltip come from it |
| G6 | move between placements | `workspace.move_placement {ws, to}` runs the existing move path (snapshot → start on target → reattach) and updates the row only after the target reports live |
| G7 | Chief links only read-back ids | the Chief link tool refuses to render a `cmux://group/` link whose id was not in a `group.list`/`group.get` answer in the same turn |
| G8 | offline mirror is read-only | opening a row whose host is offline shows the replica's last screen; input is refused `host_offline`; no local fallback |
| G9 | roles | view cannot type or start agents; edit can; owner can add members, change roles, delete; checked in TeamDO, not the client |
| G10 | presence + typing | a member opening the group appears in `presence` within 2 s; typing in a terminal sends `typing {term}` frames, never stored |
| G11 | two people typing | one writer per terminal: the second sees "Aziz is typing" and a Take Over button; takeover is logged |
| G12 | audit | every write op appends `{at, user|agent, op, target}` to the group's audit window; `group.audit.list` pages it |
| G13 | 21 locales, motion gate | every new string in `Localizable.xcstrings`; badges and presence go through the `sidebar` motion category |

## 3. Data model

### 3.1 Where each fact lives (state-placement rule)

| Fact | Authority | Projection | Stream |
|---|---|---|---|
| Group record: id, name, color, icon, created_by, archived | TeamDO row `groups` | MySQL `cloud_groups` (directory, search, admin) | `team:<t>` |
| Group members and roles | TeamDO row `group_members (group, principal, role)`; principal = `user_…` or `agent_…` | MySQL `cloud_group_members` | `team:<t>` |
| Group's workspaces and order | TeamDO row `group_items (group, ws, position, placement, home)` | MySQL | `team:<t>` |
| Workspace contents (screens, panes, tabs) | its home: daemon on `host:<h>`, or DocDO for a cloud-homed doc (object-sync 5.1) | none | `doc:<ws>` |
| Last screen, title, cwd, agent status of a workspace whose host is offline | HostDO replica (already built) | none | `host:<h>/…` |
| Presence, cursors, typing | `GroupDO` memory (new, one per group), broadcast only | none | `group:<g>` live frames |
| Audit | TeamDO event window | MySQL `audit_events`, ClickHouse for long history | |
| Group chat | ConversationDO (a132), `conversation.group = grp_…` | as today | `conv:<c>` |
| Agent bus | hub box `group:<grp_id>` | none | hub |

`GroupDO` is the only new DO. It holds no durable state beyond its idempotency ledger: it is the
fan-out point for presence, cursors and typing, so `TeamDO` (which serves every team read) does
not carry a socket per viewer. If it restarts, clients resend presence in 2 s.

### 3.2 Ids and links

- `grp_` ids: minted by TeamDO on `group.create`, 20 lowercase hex (`ctx.newId("grp")`, a hash of the
  commit's transaction id, so an idempotent replay returns the same id). Never reused.
  Archived groups keep their id and answer `archived: true` (a link still opens, read-only).
- Workspaces put into a cloud group get a TeamDO directory row keyed by their existing `ws_` id
  (object-sync 5.1 "workspace record"), so `cmux://workspace/ws_…` also resolves off-Mac.
- Link forms (one parser, `DeepLink`):
  - `cmux://group/grp_…`
  - `cmux://group/grp_…/workspace/ws_…` (open the group with that row selected)
  - `https://cloud-api.cmux.dev/g/grp_…[/w/ws_…]` (slice 1; `cmux.com/g/` later as an alias): the web route. Signed in and member: opens the app
    (Universal Link on iOS, `cmux://` hand-off on Mac), else a web read-only view of the group
    list and each row's last replica screen. Not a member: "Ask the owner for access" with a
    request button (owner gets a Home message). Never leaks titles to non-members.

### 3.3 Sidebar

- One new section kind `cloud` in the sidebar document (`sec_cloud`), drawn under Home and above
  the machine sections. It lists the cloud groups the user is a member of, in TeamDO order.
- Inside a cloud group, the `cross_machine` rule of remote groups does not apply: rows may have
  different placements. The rule stays for machine sections (a283), so nothing there changes.
- Each row draws a placement badge at the trailing edge: laptop glyph (this Mac), mini glyph
  (a Mac mini or other host), cloud glyph (Cloud VM). Tooltip: host name, status ("Asleep since
  14:02", "Paused VM", "Running"), and cost for VMs ("about $0.13/h, 4 GB VM").
- A row whose host is offline is dimmed with its last title; opening it shows the replica.
- Shared groups show member avatars (max 3 + count) on the header; live presence rings them.
- Nested groups inside a cloud group follow a283's depth limit (3).

## 4. Placement: where each workspace runs

| Placement | Where | Cost | Made by |
|---|---|---|---|
| `local` | this Mac's daemon (`host_…` of this Mac) | 0 | New Workspace in a cloud group (default when this Mac is online) |
| `mini` | an enrolled host: a Mac mini, a Linux box, a teammate's Mac with a consented grant | 0 new | "Move to > cmux15" |
| `cloud_vm` | a Freestyle VM through the cmux Cloud VM API wrapper (a205), one VM per workspace or a shared pool VM | about $0.13 per running hour for the 4 GB VM, about $0.26 for the 4 vCPU / 8 GiB pool VM; paused = storage only | "Move to > Cloud", or New Workspace with "Run in Cloud" |

Rules:

1. **New Workspace inherits the group's default placement** (`groups.default_placement`, set in
   group settings; default `local` for a personal group, `cloud_vm` for a shared group so it does
   not depend on one person's laptop). Changing it never moves existing rows.
2. **Move** (`workspace.move_placement`) reuses the moves that exist: `cmux cloud move` / "Bring
   Back" for local <-> VM (`app_cloud_move`, `app_cloud_bring_back`), and the a283/a284 move path for
   host <-> host. The TeamDO row changes only after the target daemon publishes the workspace live
   (G6). A failed move leaves the row where it was and posts the reason in the group.
3. **Auto-pause**: a `cloud_vm` row with no viewer, no running agent turn and no foreground
   process for 10 minutes pauses its VM (a306 already pauses cloud subagents at about 60 s; group
   VMs wait longer because a person may come back). The badge says "Paused" and opening wakes it.
4. **Billing**: VM time is charged to the group owner's team credits (pricing-DESIGN, one ledger,
   a205 folds VM time in). A member's agent turns are charged to the member's own plan, as today.

## 5. Linking: how Chief hands out links

The failure we fix: Chiefs write ids they never read (titles, numeric handles, made-up ids), and
links to cloud work had no stable form.

1. **Read back, then link.** After `group.create`, the Chief calls `group.get {group}` (or reads
   the id from `group.list`) and links that id. The optchat link renderer checks every
   `cmux://group/` and `cmux://workspace/` link in a Chief message against the ids seen in tool
   answers in that turn and drops (with a note to the Chief) any it cannot match (G7). Same check
   as a455's "Chief sees the chat" leak flag.
2. **Prefer the group link for cloud work**: a Chief that started work in a cloud group links
   `[Fix login · Cloud](cmux://group/grp_…/workspace/ws_…)`; the iPhone and teammates can open it.
3. **Offline host**: the link still opens; the row shows the replica (last screen, last agent
   turn summary) read-only with "Host asleep since 14:02 · Wake" (Wake = Wake-on-LAN/mac-pause
   when the host supports it, else "Move to Cloud").
4. **Tools** (MCP + CLI + palette, one action path each):
   `group.list`, `group.get`, `group.create {name, members?, default_placement?}`,
   `group.add_workspace {group, ws}`, `group.link {group, ws?}` (returns both link forms from a
   read-back), `workspace.move_placement {ws, to}`, `group.members.add {group, principal, role}`.
   CLI: `cmux group cloud list|get|create|add|link|move|share`. a235's Cloud Chief tool list gains
   these through the same catalog (its relay already exposes the app's MCP tools).

## 6. Multiplayer

### 6.1 Members and roles

| Op | owner | edit | view |
|---|---|---|---|
| See the group, rows, replica screens, chat | yes | yes | yes |
| Type in a terminal, drive a browser tab | yes | yes (one writer, 6.3) | no |
| Start, steer, stop an agent | yes | yes | no |
| Add or move a workspace, change placement | yes | yes | no |
| Start a Cloud VM (spends credits) | yes | yes, when the owner turned on "Members may start VMs" (default off) | no |
| Add or remove members, change roles, delete or archive the group | yes | no | no |

- Principals: cmux accounts (`user_…`) and Chiefs (`agent_…`). A Chief is added like a person;
  its role caps what its tools can do in the group (a view Chief can read and summarize only).
- Only team members can be added in slice 1; outside guests come with TeamDO `guest` (exists).
- Role check is in TeamDO on every op (same `roleHas` path as `team.*` ops), never in the client.
- Group roles map to team roles for the check: owner → owner of the group row; edit → member
  grant set; view → guest grant set. No new grant names.

### 6.2 Presence and cursors

- `GroupDO` live frames: `presence {user, device, viewing: ws_…/tab_…, at}` (heartbeat 15 s,
  gone after 45 s). The header shows avatars; a row shows the avatars of who is viewing it.
- Cursors: in a shared browser tab or pane, a member's pointer is drawn with the a201 glass
  cursor pill (`CmuxNextAgentCursor`, same CALayer renderer, colored by the person's id, label =
  first name). Frames reuse the `automation.input` coordinate rules (viewport CSS px, never
  screen points) with `kind: move` only, rate-limited to 20/s per member, never stored.
- Terminals do not draw a remote mouse cursor; they show the remote text cursor position and the
  typing indicator (6.3).

### 6.3 Typing and conflicts (two people, one terminal)

- **One writer per terminal at a time.** The first key from a member takes a soft lock
  `writer {term, user, until}` held in GroupDO for 5 s after the last key, renewed by typing.
- Others see "Aziz is typing" in the terminal's tab and above its input line; their keys are not
  sent. A "Take Over" button (and the same key pressed three times) takes the lock; the previous
  writer sees "Lawrence took over" and the takeover is in the audit log.
- Agents: a terminal driven by an agent shows the agent as writer; a person who types pauses the
  agent's input lease (automation-lease.md `user_driving`), as on a single Mac today.
- Why not merge both keystreams: a shell has one input line; interleaved keys produce commands
  nobody typed. A lock with visible takeover is what tmux shared sessions and screen sharing
  teach people to expect.
- Browser tabs: the same writer lock, scoped to the tab.
- ACP chat composer: drafts are per person; sends are ordered by the agent's session; two sends
  in one turn are queued by the existing steer path (a435), not merged.

### 6.4 Agent ownership

- Every agent row in a group records `owner` (the person or Chief who started it) and `billed_to`.
- Owner and group owner can stop it; edit members can steer it (their message is labeled with
  their name in the agent chat); view members can read it.
- A Chief joining a group can see its agents; it can steer only agents it owns, unless the group
  owner gives it edit.

### 6.5 Group chat and the agent bus

- A cloud group has one ConversationDO conversation (a132 group chats, a287's Chiefs Reply
  policy), created with the group, members kept in sync with the group members. It is the place
  where "Lawrence moved Fix login to Cloud" and agent finish notes land.
- The hub box `group:<grp_id>` carries agent-to-agent messages (subagents on Freestyle VMs,
  Cloud Chief). Tokens are attenuated per group box (`hub.py attenuate TOKEN box=group:<id>
  can=read,post`). The hub is not the authority for membership: a nightly job revokes hub tokens
  of agents removed from the group.

### 6.6 Audit log

`group.audit.list {group, cursor}` pages `{at, actor (user|agent), op, target, from_device}` for:
create, rename, member add/remove/role, workspace add/remove/move_placement, VM start/pause,
agent start/stop/steer by a non-owner, writer takeover, link-open by a non-member (refused).
Retained per team plan (TeamDO window + MySQL `audit_events`).

### 6.7 Billing

Sharing needs a team. A personal user who shares a group is offered "Make a team" (existing
team flow and seats). VM time: group owner's team credits. Model tokens: each person's own plan;
a Chief's tokens: the Chief owner's plan. No new price.

## 7. Alternatives compared

| | A. Cloud mirror of local groups | **B. Cloud-only groups (recommended)** | C. One top-level "Cloud" meta-group |
|---|---|---|---|
| What it is | Every local group syncs up to the cloud; the Mac stays the authority | Some groups are homed in the cloud (TeamDO); local groups stay local | One special group named "Cloud" that holds every cloud VM workspace |
| Mac asleep | Read-only (mirror stale; cannot add a workspace) | Fully usable: add, move, share, chat | Usable, but only for VM rows |
| Stable link | Mac-issued id; two Macs make two ids for "the same" group | Server-issued `grp_` id | One fixed id for the meta-group; rows inside need their own links |
| Multiplayer | Hard: two writers (Mac authority vs teammates' edits) | Natural: one writer (TeamDO), member ACL | One group = one ACL for all cloud work: cannot share "Fix login" without sharing everything |
| Mixed placement | Inherits a283's one-machine rule | Per-row placement with badges | VM rows only; local and mini work cannot join |
| Migration cost | Sync every group forever, conflicts on rename/reorder | Opt-in: "Move Group to Cloud" turns one local group into a cloud group (keeps `ws_` ids) | Small |
| Privacy | Uploads every local group's names | Only what the user puts in a cloud group | Uploads VM rows only |
| Verdict | Rejected: authority stays on a Mac that sleeps, two-writer conflicts | **Picked** | Rejected as the model; kept as the presentation: the `cloud` section header reads "Cloud" and holds all cloud groups |

Other ideas, kept as group templates on top of B (each is a cloud group with defaults, not a new
object):

| Idea | Template defaults | Verdict |
|---|---|---|
| Shared scratch group | team-visible, `cloud_vm`, auto-archive after 7 days idle | Slice 5 |
| Ephemeral PR review group | made from a PR URL: one workspace per PR worktree on a VM, members = PR reviewers, archived on merge, link posted to the PR | Slice 5; high value for the "Chief links work" ask |
| Per-customer group | members include the customer's guest accounts, view by default, separate billing tag | Later; needs guest invites outside the team and billing tags |
| Per-Chief group | each Chief gets a cloud group for its subagents; Cloud Chief and the Mac Chief share it | Slice 4 (a242 places subagents into it) |
| Everything is cloud (no local groups) | | Rejected: local-only privacy and offline use must stay |

## 8. Slices

| Slice | Work | Done when |
|---|---|---|
| 1 | TeamDO `groups` / `group_items` rows and ops `group.create`, `group.get`, `group.list`, `group.rename`, `group.add_workspace`, `group.archive` (owner-only, personal team first); server-issued ids; `https://cmux.com/g/<id>` web route (member: hand-off; non-member: refusal); `DeepLink .group`; Mac app draws the `cloud` section from `group.list` with placement badges (read from existing host/VM state); CLI `cmux group cloud list|create|add|link`; Chief link read-back check. Staging, then prod | tests 8.1 red before, green after; a Chief link opened on the iPhone with the Mac asleep shows the group |
| 2 | Offline mirror: rows of offline hosts open the HostDO replica read-only; "Move to..." placement (`workspace.move_placement`) with existing move paths; auto-pause | `CloudGroupOfflineMirrorTests`, move integration on a staging VM |
| 3 | Members and roles (owner/edit/view), share sheet, audit log, group chat (a132) created with the group | role matrix tests in TeamDO; share with Aziz on staging |
| 4 | GroupDO presence, a201 cursors in shared browser tabs, terminal writer lock + takeover, agent ownership; hub box per group (a242 subagents join it) | presence/typing tests; two-Mac live run |
| 5 | Templates: PR review group, shared scratch group; "Move Group to Cloud" for a local group | template tests |

### 8.1 Slice 1 failing-first tests

Backend (`backend/apps/api`, vitest, red first):
1. `group-create.test.ts`: `group.create` returns a `grp_` id of the right shape; a client
   `id` field is refused `invalid_argument`; a repeat with the same idempotency key returns the
   same id and makes one row.
2. `group-read.test.ts`: a non-member gets `auth.forbidden` for `group.get`; a member gets the
   record; `group.list` pages in TeamDO order; an archived group still answers with
   `archived: true`.
3. `group-items.test.ts`: `group.add_workspace` stores `placement` and `home`; adding the same
   `ws` twice is one row; a `ws` already in another cloud group is refused `conflict` (one group
   per workspace in slice 1).
4. `group-link-route.test.ts`: `GET /g/<id>` for a non-member returns the refusal page with no
   group name in the body; for a member returns the hand-off page with `cmux://group/<id>`.
5. Daemon-off: with no host connected, `group.get` still answers (no host call in the read path).

Swift (`CmuxNextAppTests`, fleet, red first):
6. `DeepLinkGroupTests`: `cmux://group/grp_…`, `…/workspace/ws_…` and `https://cmux.com/g/grp_…`
   parse to `.group(id, ws?)`; a malformed id is refused, not opened as something else.
7. `CloudSectionProjectionTests`: a `group.list` answer projects to a `cloud` section with rows in
   order and one badge per placement (`local`, `mini`, `cloud_vm`), offline rows dimmed.
8. `CloudGroupCrossMachineTests`: a cloud group with rows on two hosts is accepted; the same
   rows in a machine section are still refused `cross_machine` (a283 rule unchanged).

Chief (`optchat-chief`, cargo test, red first):
9. `link_readback.rs`: a Chief message with a `cmux://group/` id not seen in that turn's tool
   answers is rewritten to plain text and a note goes back to the Chief; a read-back id passes.

### 8.2 What slice 1 landed, and what it left

Landed (see the commit range in the a461 report):

- TeamDO ops `group.create`, `group.rename`, `group.add_workspace`, `group.archive`, reads
  `group.get`, `group.list` (backend `domains/team-groups.ts`, `domains/team-group-reads.ts`,
  protocol `team-group-ops.ts`), rows only, private to reads. Catalog, TS client, Rust wire and
  app-host scopes regenerated.
- `GET /g/<id>` on the API Worker: an anonymous hand-off page with only the `cmux://` link.
- `DeepLink.Target.group(id, workspace:)`, `DeepLink.parseGroupWeb`, `CloudGroupLink` (reads
  `group.get` with the signed-in account, shows the first workspace open on this Mac, refuses
  "none of this cloud group's workspaces is open on this Mac" in 21 locales).
- Chief link rule (optchat-chief `prompt.rs`): link a group only with a read-back id.

Left for slice 1b (named so nobody thinks they shipped):

1. The `cloud` sidebar section with placement badges (needs a473's machine model for the
   badge's host).
2. A CLI and MCP surface for `group.*`: the `cmux` CLI does not generate commands from the cloud
   catalog, so Chiefs cannot call these ops yet. Proposed: `cmux group cloud …` as app actions
   that call the ops with the app's sign-in.
3. The host-side read-back check (G7) in optchat-chief: the brain does not see tool outputs
   today (they are folded for the transcript only); slice 1 ships the prompt rule instead.
4. Placement names a473's ids, not host names or Cloud VM ids (a473, 2026-10-22,
   remote-groups-DESIGN.md section 19): `placement.machine_id` (`machine_<32 hex>`, one per
   daemon state root) and `placement.session_resource_id`. Slice 1's free-text `host`/`machine`
   fields get replaced by these two in slice 1b; `sec_m_<registry_id>` is local sidebar
   placement only and is never stored.
5. MySQL projection `cloud_groups` (directory/admin): not needed for slice 1 reads; it needs a
   Vitess migration through the staging gate.

## 9. Coordination

| Agent | Work it owns | What this design asks of it |
|---|---|---|
| a242 (cloud subagents, done) | subagents as acpmux peers on Freestyle VMs | Slice 4: a cloud subagent's workspace joins the spawning Chief's cloud group with `placement: cloud_vm`; peer choice stays a242's |
| a205 (Freestyle wrapper, done) | Cloud VM API, credits ledger | `cloud_vm` placement uses the wrapper; VM time billed to the group owner's team; acpmux in the tenant image (cloud-subagents B9) is a slice 2 prerequisite for tenant VMs |
| a235 (Cloud Chief tools, done) | Cloud Chief relay of app tools | The `group.*` tools reach Cloud Chief through the same catalog; no new relay |
| a448 (Chief talks to Cloud Chief), a459 (Cloud Chief reaches all Macs), a450 (iPhone talks to Chief) | live | Told by a461 on 2026-10-22: links to shared work should be `cmux://group/` read-backs; iPhone must handle `https://cmux.com/g/` Universal Links |
| a283/a284 (remote groups, Chief move) | machine sections, nested groups | `cloud` is a new section kind; `cross_machine` stays for machine sections |
| a473 (remote groups: one host daemon per machine) | the transport for every surface | `placement.host` holds a473's machine/session id; a473 owns opening, mirroring and moving. a461 could not tell a473 directly (tell refused); Chief relays |
| a455 (Chief sees the chat) | Chief-side message checks | The link read-back check (G7) sits next to its leak flag |

## 10. Open items (defaults picked)

1. One cloud group per workspace in slice 1 (default). A workspace in two shared groups needs a
   membership-union rule; later.
2. Default placement for a shared group is `cloud_vm` (default) so the group works when its maker
   is asleep; personal groups default to `local`.
3. "Members may start VMs" is off by default (credits are money).
4. Web read-only view of a replica terminal ships in slice 2, not slice 1 (slice 1 web shows the
   list and statuses only).
5. Retention of the audit window follows the team plan; no new setting.
