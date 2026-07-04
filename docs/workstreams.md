# Workstreams

Workstreams are a **top-level, drill-in (master-detail) layer** for organizing
workspaces. They sit a level *above* [Workspace Groups](./workspace-groups.md):
where groups are an inline, single-level disclosure rendered in the same
scrolling list, a workstream is a first-class container you **navigate into**.

This scales the sidebar past the point where a flat list stops working — the
agent-per-PR workflow that keeps 20–30 workspaces open across a handful of
concurrent initiatives. Instead of scanning a 30-row wall, you see a short list
of workstreams and drill into the one you're working.

## Mental model

- **Workstream** = a feature / epic / initiative.
- **Workspace (PR)** = one workspace, matching cmux's one-agent-per-PR usage.

Two levels, with **navigation between them** (workstream → its workspaces), vs.
a group's single level with in-place expand/collapse.

## Drill-in navigation

The sidebar has two states, driven by one piece of per-window state
(`drilledInWorkstreamId`):

1. **Top level (`drilledInWorkstreamId == nil`).** A "Workstreams" section lists
   your workstreams, each showing a rollup (workspace count + aggregate unread).
   Below it are any workspaces *not* assigned to a workstream — exactly the
   pre-workstream list. Clicking a workstream row **drills in**.
2. **Drilled in.** The sidebar shows a breadcrumb (← Workstreams / *Name*) and
   **only that workstream's workspaces** (its own groups still render inline).
   Tapping the breadcrumb returns to the top level.

The entire filter is one predicate — a workspace is visible when its
`workstreamId == drilledInWorkstreamId`. With no workstreams, every workspace
has `workstreamId == nil`, so the top level is identical to the classic flat
list: **adopting workstreams is opt-in and removing them is lossless.**

Drilling in is a *view* concern only: it never changes which workspace is
focused, so the terminal you're looking at is unaffected.

## Relationship to Workspace Groups

Workstream membership (`Workspace.workstreamId`) is **orthogonal** to group
membership (`Workspace.groupId`). A workspace can be in a workstream *and* in a
group, so a drilled-in workstream still renders its inline group headers.
Existing single-level groups and ungrouped workspaces are unchanged.

Unlike a group, a workstream has **no anchor workspace**. Deleting a workstream
is non-destructive: its workspaces are kept and return to the top level
(deleting a *group* with `delete` still closes its members; use `ungroup` to
keep them).

## Persistence

Workstreams, their membership, the master-list ordering, and the drill-in /
last-viewed state all persist across app restart in the session snapshot.
Workstream ids are stable across restart, so membership and the drill-in pointer
reconnect directly.

## CLI

All operations are scriptable via `cmux workstream <subcommand>`:

```bash
cmux workstream list [--json]
cmux workstream create [--name "Checkout revamp"] [--workspaces <id>,<id>]
cmux workstream rename <workstream> --name "new name"
cmux workstream delete <workstream>          # keeps workspaces (returns them to top level)
cmux workstream add --workstream <id> --workspace <ws>
cmux workstream remove --workspace <ws>
cmux workstream move <workstream> --to-index <n> | --before <workstream> | --after <workstream>
cmux workstream enter <workstream>           # drill in (view only)
cmux workstream exit                         # back to the workstream list
```

`<workstream>` accepts a UUID or a `workstream:N` ref printed by `list`. Every
command honors `--json`. These map to the `workstream.*` control-socket methods.

## Sidebar context menu

Right-click a workstream row for **Rename**, **Move Up / Move Down**, and
**Delete**. Create a workstream from the CLI, or move workspaces into one and it
appears automatically.
