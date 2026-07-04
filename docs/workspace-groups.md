# Workspace Groups

Workspace groups let you nest workspaces into collapsible named sections in the sidebar. Each group has an implicit "anchor workspace," a customizable `+` button for spawning new workspaces inside it, and right-click actions for renaming, pinning, ungrouping, and editing its configuration.

## Concepts

### Anchor workspace

Every group is owned by exactly one workspace called the **anchor**. The group header in the sidebar IS the anchor's representation — there is no separate row for it. Clicking the header name area focuses the anchor's panels. Clicking the chevron toggles collapse.

Anchors are always brand new when a group is created. They are never promoted from an existing workspace. The anchor's working directory is inherited from the first selected workspace (when grouping a selection) or from the active workspace (when creating via the CLI without `--cwd`).

Closing the anchor workspace **dissolves the group**: every other member loses its `groupId` and stays in the tabs list as an ungrouped workspace. Nothing is closed besides the anchor itself. The app shows a confirm dialog with a "Don't ask again" toggle before this happens.

### Group identity

A group has a `name`, `iconSymbol` (an SF Symbol, default `folder.fill`), and an optional `customColor` (hex string). Both are independent of the anchor workspace's own customizations. The anchor's color and icon are seeded from the group on creation, but they can diverge afterwards.

### Pinning

Groups can be pinned independently of individual workspace pins. Pinned top-level rows, whether individual workspaces or groups, stay above unpinned rows. Within each tier, groups and workspaces keep the order you drag them into.

The sidebar layout, top to bottom:
1. Pinned top-level rows (workspaces and groups).
2. Unpinned top-level rows (workspaces and groups).

## Creating a group

### From the keyboard (`⌃⌘G` or `⌘⇧G`)

Press `⌃⌘G` to create a new empty workspace group. cmux inserts a fresh anchor workspace as the group header and auto-names it `Group 1`, `Group 2`, … (rename anytime via the header context menu).

Select two or more workspaces in the sidebar, press `⌘⇧G`. A fresh anchor workspace is inserted above the selection; all selected workspaces become children. The group is auto-named `Group 1`, `Group 2`, … (rename anytime via the header context menu). `⌘⇧G` collides with React Grab's default; the group handler only consumes the chord when there is an explicit sidebar multi-selection of at least two workspaces, so React Grab still fires in single-selection and browser/terminal contexts. Rebind in Settings → Keyboard if you'd rather the two not share a key.

Single-tab groups are not created from the shortcut. Use the workspace context menu's **New Group from Workspace** entry for that.

### From a workspace context menu

Right-click any workspace in the sidebar, choose **New Empty Workspace Group** for an anchor-only group, **New Group from Workspace** for a group containing that workspace, or **New Group from Selection** when multiple workspaces are selected. The blank area below the sidebar list also offers **New Empty Workspace Group**. Same auto-naming behavior as the shortcuts.

### From the group header context menu

Right-click an existing group's header for: **Rename Group…**, **Pin / Unpin Group**, **Edit Group Config…** (opens `~/.config/cmux/cmux.json`), **Open Workspace Groups Docs**, **Ungroup (Keep Workspaces)**, **Delete Group (Close Workspaces)**. Delete is destructive and prompts for confirmation; ungroup keeps the workspaces and just removes the container.

### From the `+` button on a group header

Hover over a group header to reveal a trailing `+` button. Click to create a new workspace in the group at the anchor's cwd. Right-click for **New Workspace in Group**, **Edit Group Config…**, and **Open Workspace Groups Docs**.

Pressing `⌘N` while the active workspace is a group anchor or group member also creates the workspace inside that group. The default group placement is **After current**: from a regular group member, the new workspace lands right after the active member; from the anchor/header, it lands at the top of the group.

New in-group workspaces adopt the anchor's cwd only when **Settings → App → Inherit Workspace Working Directory** (`app.workspaceInheritWorkingDirectory`) is on, which is the default. Turn it off and new workspaces — grouped or not — start in your home directory instead.

## CLI

All group operations are scriptable via `cmux workspace-group <subcommand>`. The hyphenated form ships first; once the broader `cmux workspace <noun>` namespace lands, `cmux workspace group ...` will be the canonical form with the hyphenated form kept as an alias forever.

### Subcommands

```bash
cmux workspace-group list [--json]
cmux workspace-group create --name "manaflow" [--cwd ~/projects/manaflow] [--from <id>,<id>]
cmux workspace-group ungroup <group-id>
cmux workspace-group delete  <group-id>   # destructive: closes every member workspace
cmux workspace-group rename <group-id> --name "new name"
cmux workspace-group collapse <group-id>
cmux workspace-group expand <group-id>
cmux workspace-group pin <group-id>
cmux workspace-group unpin <group-id>
cmux workspace-group add --group <group-id> --workspace <workspace-id>
cmux workspace-group remove --workspace <workspace-id>
cmux workspace-group set-anchor --group <group-id> --workspace <workspace-id>
cmux workspace-group new-workspace <group-id> [--placement afterCurrent|top|end]
```

`create` returns a group handle (`workspace_group:N` by default). Pass `--json` for the full structured payload.

### Examples

Group the three currently selected workspaces under a name:

```bash
cmux workspace-group create --name manaflow
```

Spin up a new workspace inside an existing group (e.g. wired to a worktree script):

```bash
cmux workspace-group new-workspace workspace_group:1
```

List groups in the focused window:

```bash
cmux workspace-group list
```

## Configuration

Per-group configuration is keyed by the anchor's working directory in `~/.config/cmux/cmux.json` (this surface lands in a follow-up; the file location is reserved). The intent:

```jsonc
{
  "workspaceGroups": {
    // Global default for Cmd-N inside a group, the group header + button, and
    // configured group actions. Per-cwd entries below can override it.
    //   "afterCurrent" (default) - after the active in-group workspace; falls
    //                              back to top when there is no member reference
    //   "top"                    - second slot, right after the anchor
    //   "end"                    - after the trailing member
    "newWorkspacePlacement": "afterCurrent",
    "byCwd": {
      "/Users/you/manaflow/cmux": {
        "color": "#7A4FD8",
        "icon": "ladybug.fill",
        "newWorkspacePlacement": "top",
        "contextMenu": [
          // Entries reference actions defined elsewhere in cmux.json (in the
          // global `actions` block) or built-in actions like "newWorkspace".
          { "action": "newWorktreeAction", "title": "New Worktree" },
          { "action": "newWorkspace" }
        ]
      },
      "~/projects/*": {
        "icon": "leaf.fill",
        "newWorkspacePlacement": "end"
      }
    }
  }
}
```

Matching: keys containing `*` or `?` are globs; otherwise they are path prefixes. Longest match wins.

Resolution order for group new-workspace placement:
1. Explicit `--placement afterCurrent|top|end` on `cmux workspace-group new-workspace`, or `"placement"` in the v2 `workspace.group.new_workspace` params.
2. The per-cwd entry above.
3. Global default via Settings > App > Group New Workspace Placement or `workspaceGroups.newWorkspacePlacement` in `cmux.json` (defaults to `afterCurrent`).

`Cmd-N` inside a group uses the active group workspace as the placement reference. The group header `+` button and CLI path use the anchor as the reference, so `afterCurrent` behaves like `top` there.

## iMessage mode (planned)

When the sidebar is in iMessage mode (latest unread floats to top), the intended behavior for groups is two boolean knobs:

- `sortInsideGroups` (default `true`): workspaces inside each group sort by latest unread; group section position is unchanged.
- `floatGroups` (default `false`): the whole group section reorders by its most-recent unread member.

Neither knob is wired up yet. The current build keeps the sidebar's existing iMessage-mode behavior unchanged regardless of groups. A follow-up will add the `sidebar.imessageMode.*` keys to `cmux.json`, the schema, and the Settings UI; this section is documented here so the eventual JSON shape is decided up front.

## Persistence

Groups (name, anchor, pin state, collapse state, color, icon) round-trip through `~/Library/Application Support/cmux/session-<bundle-id>.json` alongside workspaces. Membership lives on `Workspace.groupId`. Writes are atomic via the existing `SessionPersistenceStore` rename-into-place pattern.
