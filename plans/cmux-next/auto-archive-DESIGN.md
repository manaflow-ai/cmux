# Auto-archive idle workspaces (2026-10-25)

Ask (Lawrence 12659): "build multiple variations of auto archive feature, which will auto archive old
workspaces, that is configurable, and supports archiving workspaces in groups, and groups themselves
if all the workspaces in the group are archived, think about how expert product designer would design
this".

Builds on Aziz's archive (archiving-DESIGN.md): an archived item stays in its group, last and dimmed;
Unarchive puts it back. Auto-archive only decides *when* to archive; it never deletes, closes or hides.

## Principles

1. **Never lose the person's place.** Archive is reversible and in place: the row stays in its group
   (dimmed, last), opens on click, and Undo is one step. No workspace is closed or deleted.
2. **Never surprise.** The default asks first (a sidebar card), and the quiet variant always says what it
   did (a toast with Undo, Cmd-Z).
3. **Never archive live work.** Pinned, shown, running (a command or an agent turn), needing the person
   (unread, waiting, error) and never-seen workspaces always stay, even from a manual sweep.
4. **Groups follow their members.** The person thinks in groups; a group whose members are all archived
   is archived itself, and comes back with its first restored member.
5. **Cheap with huge sidebars.** No polling, no per-frame or per-key work. One deadline at a time.

## Idle signal

A workspace's last use is the newest of:

- shown in a window (the coordinator's ledger, recorded on every workspace switch: an O(1) dictionary write);
- output in a terminal (`TabModel.lastOutputMs`), an agent update (`agent.updatedAtMs`), a notification
  (`notification.createdAtMs`).

The ledger (`AutoArchiveLedger`, one `UserDefaults` key, saved at most every 5 minutes and on quit) keeps
last-seen per workspace, so idleness survives restarts. A workspace never seen before starts its clock at
first sight: nothing is ever idle on arrival (an upgrade does not archive the whole sidebar).

## Variations (`workspaces.autoArchive.style`)

| Style | Background | What the person sees | For |
| --- | --- | --- | --- |
| `suggest` (**default**) | at the deadline, if any are idle | A sidebar card: "N workspaces look idle", up to 5 names, **Archive** / **Not Now** (Not Now waits a day) | Everyone: no row moves without a click |
| `quiet` | archives the idle ones | A toast "Archived N idle workspaces" with **Undo** (Cmd-Z) | People who want a self-tidying sidebar |
| `groups` | archives only members of groups with their own rule | Toast with Undo | Per-project policy: CI and scratch groups tidy, the rest never |
| `manual` | nothing | **Archive Idle Workspaces** (sidebar background menu, palette, `cmux workspace archive-idle`) archives now, with Undo | Tidy on demand |
| `off` | nothing; group rules ignored | The sweep still works when asked | Opt out |

`workspaces.autoArchive.idleDays` (1 to 365, default 3: a long weekend away is not "done").

Default picked: **suggest**. Reason: the request asks for auto-archive, but a row that moves on its own
the first time is a surprise; suggest shows the value on day one and asks once. Switching to `quiet` is
one setting.

## Per-group rules

Right-click a group > Options > **Auto-Archive Group Workspaces** > Use the Default / Never / After 1 Idle
Day / 3 Days / 1 Week / 30 Days (`cmux workspace-group set-auto-archive --arg after=<default|never|hours>`).
Stored in the sidebar document (`extra.auto_archive`: `"never"` or hours 1..87600), so it syncs with the
group and survives restarts. The **nearest** group with a rule decides for a member (a nested group's
rule wins over its parent's). Never keeps members even from the manual sweep.

## Groups

In the reducer (`cmux-layout-reducer` `sidebar_doc/archive.rs`), so the app mirror, the daemon, the CLI
and MCP agree and each change is one undo step:

- **Roll-up.** When an `archive` leaves a group with members and none unarchived, the group archives too
  (`extra.archived_by = "members"`) and moves to its own list's archived tail; the walk climbs nested
  groups, re-checking a parent whenever a child group archives.
- **Wake.** Unarchive of a member first unarchives the archived groups above it (outermost first). A move
  or adopt of a *live* workspace into an archived group unarchives the group. An archived workspace
  dropped into an archived group leaves it archived.
- **Undo.** The roll-up is part of the same op, so its inverse restores the group with the member.

## Archived view

**Restore Archived Workspace…** (sidebar background menu ▸ Group, palette, `cmux workspace restore-archived
--arg item=<item|all>`): a searchable Cmd-Shift-P step listing every archived workspace (by hand, on its
own, or under an archived group), last used first, with **Restore All** first. Return restores it (and its
archived groups). Opening an archived workspace from the sidebar still works as before (dimmed).

A workspace auto-archive archived comes back on its own when shown again (a click, Cmd-P, a link). One
archived by hand keeps Aziz's rule: it opens dimmed until Unarchive.

## Cost (huge sidebars)

- Work happens at one `DemandTimer` deadline: the planner returns the soonest next deadline (never
  sooner than 60 s after a pass), so an idle Mac wakes about once per idle period, not on a poll.
- First pass 30 s after launch; a setting change re-plans after 1 s.
- A pass is O(workspaces + document items) on the main actor; 10 000 workspaces is a few milliseconds,
  at most once a minute. The workspace-switch path adds one dictionary write and, only while something
  is auto-archived, one item lookup.
- No view or sidebar code changes: rows draw the existing dimmed flag. Nothing in the snapshot boundary.

## Surfaces

| Surface | Entry |
| --- | --- |
| Settings > General > Auto-Archive | Idle Workspaces (style), Idle For (days) |
| cmux.json | `workspaces.autoArchive.style`, `workspaces.autoArchive.idleDays` |
| Sidebar background menu ▸ Group | Archive Idle Workspaces, Restore Archived Workspace… (beside Collapse All; the menu keeps 12 top-level rows) |
| Group menu > Options | Auto-Archive Group Workspaces ▸ |
| Palette | all three |
| CLI | `cmux workspace archive-idle`, `cmux workspace restore-archived`, `cmux workspace-group set-auto-archive` |
| MCP | the same actions (agents may run the sweep; the style and days are `userOnly`) |

## Files

- Reducer: `cmux-tui/crates/cmux-layout-reducer/src/sidebar_doc/archive.rs`, `model.rs`
  (`ARCHIVED_BY_KEY`, `AUTO_ARCHIVE_KEY`, `AutoArchiveRule`), tests `archive_group_tests.rs`.
- Settings: `schemas/settings/source/auto-archive.json` (generated Swift), `AutoArchiveSettings.swift`.
- Logic: `CmuxNextSidebar/AutoArchive/` (`AutoArchivePlanner` pure, `AutoArchiveCoordinator`,
  `AutoArchiveLedger`, `AutoArchivePolicy`, `AutoArchiveDocument`, `SidebarDocAutoArchiveRule`);
  `CmuxNextBridge/AutoArchiveCandidates.swift` (daemon reads); actions in
  `CmuxNextSidebarActions/AutoArchiveActions.swift`. No Package.swift change (it is frozen).
- App: `AppServices+AutoArchiveHost.swift` (one-line forwards), wiring in `AppServices`, `AppActions`, `AppDelegate`.
- Tests: `AutoArchivePlannerTests`, `AutoArchiveCoordinatorTests`, reducer `archive_group_tests`.

## Open

- Group header rows have no "archived by members" badge; the dimmed look already reads as archived.
- The ledger is per Mac; another Mac's shows do not count (its own coordinator runs there).
- No capture tour yet for the card and toast (they are existing components; see the report).
