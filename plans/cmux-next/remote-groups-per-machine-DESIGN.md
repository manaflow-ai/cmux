# Remote groups per machine: one machine, a machine icon, show or hide, one flat list by default

Status: R1-R3 built 2026-10-22; R4 waits on a436's gate (section 8). Owner lane: "Agents & routing".
Ask: Lawrence's voice talk with Leo (Chief msg 9663). Builds on
[remote-groups-DESIGN.md](remote-groups-DESIGN.md) (a283/a473: a remote group is a `machine` section
with `host_group`), [cloud-groups-DESIGN.md](cloud-groups-DESIGN.md) (a461: cloud-homed groups,
membership and links), [workspace-proxy-DESIGN.md](workspace-proxy-DESIGN.md) (a464/a473: a browser
reaches the remote daemon's ports), [sidebar-ordering-DESIGN.md](sidebar-ordering-DESIGN.md) (bands,
Move to Top, Cmd-N on top), [sidebar-calm-movement.md](sidebar-calm-movement.md) (no motion nobody
asked for), [sidebar-performance.md](sidebar-performance.md) (budgets).

## 0. What the user asked, and what already exists

| Ask | State on feat-cmux-next (a986daae1dd) | This design |
| --- | --- | --- |
| a remote group is exactly one machine (a Freestyle VM, or a Mac mini / server over Tailscale), and everything in it runs only there | **exists**: a remote group is the machine section `sec_m_<session>` marked `host_group`; the reducer refuses a workspace of another machine in it (`cross_machine`), and New Workspace in it creates on that machine (`GroupSpawnHost`) | no model change; R1 makes it visible |
| show / hide remote groups | **missing** | R2: `sidebar.showRemoteGroups` + one action `sidebar.toggleRemoteGroups` |
| users may still make their own mixed views (local + remote workspaces in one group or custom section; a workspace with local and remote terminals) | **exists**: custom document sections and ordinary groups hold workspaces of any machine; a workspace's panes pick their machine per terminal | unchanged; stated as an invariant (section 4) |
| group header: a tiny machine icon (cloud / Mac mini / laptop, user-changeable) in place of today's color; otherwise minimal, no other icons by default | header draws the name, a **status color dot** and the word "Connected"; the machine's own icon only when the user set one (`machine.setIcon`) | R1: the dot is replaced by the machine icon (default from the machine's form, user icon wins); status words only when not connected |
| default sidebar: every workspace flat, chronological, across screens; no nested groups by default | **mostly exists**: one list (`sidebar.groupByComputer` off) is the default, but it lists machine by machine (all of this Mac's rows, then the mini's), so it is not chronological across machines; nested groups exist in the reducer and list (a479's prototype) but none is made by default | R3: one list merges machines by creation time; nested groups stay opt-in (only New Subgroup makes one) |
| sidebar perf is critical, p95 rows in a436's gate, no regressions | sidebar layout bench exists | R4: p95 rows for the merged one list and the header |

Target user: a person with 2-3 Mac minis and a Linux server, maybe a Cloud VM. That is at most
~5 machines, ~50-300 workspaces. Budgets in section 6 are set for 10 machines × 1,000 workspaces so
the target case has 10× headroom.

## 1. Model (unchanged)

- A **remote group** = one `machine` section of the sidebar document whose session is not the home
  session and whose `host_group` flag is on. One section per machine, so one remote group per
  machine. Its workspaces are that machine daemon's workspaces; a terminal, diff, file view or agent
  opened from it runs on that machine (`machines.daemon(for:)`).
- Mixing is a **view**, never a remote group: an ordinary group or a custom section may hold
  workspaces of several machines (the user drags them in); a workspace may hold panes of several
  machines. The remote group never holds another machine's workspace (`cross_machine`).
- a461's cloud groups are records in `TeamDO`, drawn in their own "Cloud" section; a cloud group may
  list workspaces of many machines (it is a mixed view by this definition). A Freestyle VM the user
  adds as a machine is a remote group like a mini. The two do not overlap: a remote group is "the
  machine", a cloud group is "a shared list".

## 2. R1: the header is a machine icon and a name

```
 [mini-glyph] cmux-mini-2                     ⌄  +       connected
 [mini-glyph] cmux-mini-3   Reconnecting…     ⌄  +       needs no action, says so
 [cloud]      fs-vm-12      Offline           ⌄  +       icon and text dimmed
```

- **Icon** (16 pt, `Metrics.smallIconSize`, the row's tertiary text color): the user's icon when set
  (`machine.setIcon`: emoji, SF Symbol or image; existing path), else the machine's **form**:

  | Form | When (first match) | SF Symbol |
  | --- | --- | --- |
  | cloud | `kind == .cloud` (Freestyle VM, Cloud machine) | `cloud` |
  | Mac mini | name or host contains `mini` (`cmux-mini-2`, `lawrences-mac-mini`) | `macmini` |
  | laptop | name contains `macbook`, `mbp`, `mba`, `laptop` | `laptopcomputer` |
  | desktop Mac | name contains `imac`, `studio`, `macpro` | `desktopcomputer` |
  | server | anything else remote (SSH/Linux/paired server) | `server.rack` |
  | this Mac | `kind == .local` | `laptopcomputer` (reading `hw.model` to pick `desktopcomputer` on a desktop Mac is a follow-up) |

  The name heuristic is a default only; the user's choice always wins and is stored in the home
  session registry (`session-icon-v1`), so every client draws the same icon. A later slice can read
  the real model from `cmux host list` / `remote-probe` (`hw.model`) instead of the name.
- **No status dot.** The icon takes the dot's place. Connected says nothing. Every other state is the
  existing words after the name (Connecting…, Reconnecting…, Offline, Update needed, …), and the icon
  and name dim (tertiary → quaternary) while the machine is not connected. The tooltip keeps words,
  detail and a Cloud machine's cost.
- **No other icons by default.** The `+` and the fold chevron stay (they are controls the
  ordering design keeps at rest so the header never reflows); no kind glyph, no color bar.
- The workspace rows under a remote group's header draw **no machine mark** (the header already
  names the machine). In one list (R2 hidden, R3) a remote row keeps its mark, now drawn with the same
  form icon so a row and its group read the same.

## 3. R2: show or hide remote groups

- Setting `sidebar.showRemoteGroups` (bool, default **true**; cmux.json, Settings > Appearance > Sidebar,
  agent-settable) and two actions on the one action path, `sidebar.remoteGroups.hide` and
  `sidebar.remoteGroups.show` (Command Palette and keyboard; each is offered only while it applies).
  Default picked: no menu row, because the machine header menu and the sidebar background menu are
  both at the 12-row limit (`MachineIconTests` guards it); Settings and the palette cover it.
- **Hidden** = the remote groups' headers go away and their workspaces join the one list, in
  chronological order with their machine mark (R3). Nothing is removed, nothing disconnects, every
  workspace stays one Cmd-P away and still runs on its machine. Shown = each remote group is a
  headed section again. Default picked: hiding flattens rather than removes rows, because removing
  them would hide agents that need attention; a per-group "Hide" that removes rows can come later.
- Toggling is a user intent: one layout change, through the motion gate (instant under Reduce
  Motion), no reload of row views (rows are keyed by workspace id and are reused).

## 4. R3: one list is chronological across machines

Today one list lays out machine sections one after another (`SidebarLayout.make`, `flat`), so a
mini's newest workspace sits under all of this Mac's rows. R3:

- Each workspace document item gets `extra.created_ms` (the home daemon's wall clock, stamped by the
  daemon when it adopts the workspace into the document; the reducer stays clock-free and takes the
  value in the op). Items made before R3 have none.
- In one list, the rows of every flattened machine section (this Mac, machines whose group is hidden,
  machines that are not remote groups) merge into one sequence: a **stable k-way merge** of each
  section's own order, taking at each step the head with the newest `created_ms`. Each machine keeps
  its own manual order (Move to Top, drags); the merge only interleaves machines. An item without a
  time sorts as if made at the time of the item above it in its own section (so old documents keep
  their order and new workspaces go on top).
- Pinned band, Home, custom sections and headed remote groups are not merged (they are views the
  user made).
- "Across screens": the list is per window today and already lists every workspace of every space
  the window shows; R3 does not filter by space.
- No nested groups by default: nothing makes a subgroup except New Subgroup (a479's prototype stays
  behind that action; no migration nests anything).
- Drops: a drop in the merged list resolves to the dragged workspace's own machine section, at the
  index after the nearest row of that machine above the drop point (`DropResolver`). A drop that would
  move a workspace to another machine is refused as today (moving a workspace between machines is a
  separate feature).

## 5. Coordination

- a473 (remote groups part II, workspace proxy): no protocol change; R1 reads `SidebarMachine` only.
  The form-from-`hw.model` follow-up needs `remote-probe` to report `hw.model` (a473's lane).
- a461 (cloud groups): cloud groups stay a separate "Cloud" section; R2's toggle does not hide them.
- a479 (nested groups prototype): stays a prototype; R3 makes no nested group.
- a469: the merged list must keep the sidebar's row reuse (keys by workspace id) that a469's work
  relies on; no new store reference below the list (snapshot boundary rule).
- a436 (perf gate): R4 adds rows (section 6).

## 6. Performance (R4)

The merge is O(n log k) for n rows and k machines with a binary heap, O(n·k) with a linear scan of
heads; k ≤ 10, so the linear scan is used (no allocation per step). The header icon is one cached
`NSImage` per (symbol, size); no per-frame work.

New p95 rows for a436's gate (Swift package bench, release build, 200 runs, fleet mini):

| Row | Input | Budget p95 |
| --- | --- | --- |
| `sidebar.layout.oneList.merge.5x60` | 5 machines × 60 workspaces, one list | ≤ 1.0 ms |
| `sidebar.layout.oneList.merge.10x1000` | 10 machines × 1,000 workspaces | ≤ 12 ms |
| `sidebar.layout.remoteGroups.toggle.5x60` | flip R2 on a 5 × 60 sidebar (layout only) | ≤ 1.0 ms |
| `sidebar.header.configure.machine` | configure 100 remote-group headers | ≤ 2.0 ms |

"No regression": the existing one-list rows (`flat` path) must stay within 5% of the base commit's
p95 on the same mini.

## 7. Slices

| Slice | Work | Done when |
| --- | --- | --- |
| R1 | header: form icon in place of the status dot; no "Connected"; dimmed when not connected; rows under a remote group's header draw no machine mark | `RemoteGroupHeaderIconTests` (form per machine, user icon wins, no dot, words only off-connected) red, then green |
| R2 | `sidebar.showRemoteGroups` + `sidebar.toggleRemoteGroups` (palette, menus, CLI, MCP), localized | `RemoteGroupsVisibilityTests` (hidden: no host-group header, rows in one list; shown: headers back) red, then green |
| R3 | `extra.created_ms` stamped on adopt (daemon), merged one list (Swift), drop resolution in the merged list | Rust `adopt_stamps_created_ms`; `SidebarOneListMergeTests` (interleaves machines by time, keeps each machine's manual order, old items keep order) red, then green |
| R4 | p95 rows in a436's gate | rows present and within budget on a fleet mini |

## 8. Where the slices stand (2026-10-21)

- **R1, R2: built** (`SidebarMachineForm`, `SectionHeaderRowView`, `SidebarLayout.marksMachine`,
  `sidebar.showRemoteGroups`, `sidebar.remoteGroups.hide|show`). Two older tests changed with the rule
  the user asked for: `HostGroupHeaderStatusTests` (no "Connected" in words) and
  `SidebarIconMeaningTests` (no bare dot; the connected header's tooltip says the state).
- **R3: built.** The daemon stamps `created_ms` on each adopted reference (`sidebar_doc::created`,
  at the three apply sites; the document finds an item by session and workspace id only, so the
  stamp changes no lookup). The app reads it onto `SidebarWorkspace.createdMs`, and
  `SidebarLayout.mergeOneList` runs after `make` lays out the sections: each run of consecutive
  headerless computer sections is cut into top-level units (a workspace with its tab and tree rows,
  a group with its members, a fold row), merged newest first in a stable k-way merge of each
  section's own order, and laid out again from the run's top. Rows keep their section and index,
  so drops, folds and row updates are unchanged; the drop gap moves with its place. A Done fold or
  "Show N more" row stays a unit of its own section. Not done: the merge does not run when no row
  has a time (an older daemon), and a row update that changes a row's height lays the list out
  again (as before), so the merge runs on every structural change, never per frame.
- **R4: blocked on a436's gate.** `scripts/cmux-next/perf-budgets.json` and `perf-budgets.py` are on
  branch `perf-gate` (not on feat-cmux-next). The rows in section 6 go there when it lands; R1 and R2
  add no per-frame work (one cached glyph per header configure, one CALayer fewer per header).
