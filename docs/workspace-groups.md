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

Groups can be pinned independently of individual workspace pins. Pinned groups float above unpinned groups in the sidebar. Individually pinned workspaces (not part of a group) stay above all groups.

The sidebar layout, top to bottom:
1. Pinned ungrouped workspaces.
2. Pinned groups (each one's members in tab order).
3. Unpinned groups.
4. Ungrouped unpinned workspaces.

## Creating a group

### From the keyboard (`⌘⇧G`)

Select one or more workspaces in the sidebar, press `⌘⇧G`, enter a name. A fresh anchor workspace is inserted above the selection; all selected workspaces become children.

If nothing is selected, the active workspace is grouped on its own.

### From a workspace context menu

Right-click any workspace in the sidebar, choose **New Group from Workspace…** (or **New Group from Selection…** when multiple workspaces are selected), enter a name. Same behavior as the shortcut.

### From the group header context menu

Right-click an existing group's header for: **Rename Group…**, **Pin / Unpin Group**, **Edit Group Config…** (opens `~/.config/cmux/cmux.json`), **Open Workspace Groups Docs**, **Ungroup (Keep Workspaces)**.

### From the `+` button on a group header

Hover over a group header to reveal a trailing `+` button. Click to create a new workspace in the group at the anchor's cwd. Right-click for **New Workspace in Group**, **Edit Group Config…**, and **Open Workspace Groups Docs**.

## CLI

All group operations are scriptable via `cmux workspace-group <subcommand>`. The hyphenated form ships first; once the broader `cmux workspace <noun>` namespace lands, `cmux workspace group ...` will be the canonical form with the hyphenated form kept as an alias forever.

### Subcommands

```bash
cmux workspace-group list [--json]
cmux workspace-group create --name "manaflow" [--cwd ~/projects/manaflow] [--from <id>,<id>]
cmux workspace-group ungroup <group-id>
cmux workspace-group rename <group-id> --name "new name"
cmux workspace-group collapse <group-id>
cmux workspace-group expand <group-id>
cmux workspace-group pin <group-id>
cmux workspace-group unpin <group-id>
cmux workspace-group add --group <group-id> --workspace <workspace-id>
cmux workspace-group remove --workspace <workspace-id>
cmux workspace-group set-anchor --group <group-id> --workspace <workspace-id>
cmux workspace-group new-workspace <group-id>
```

`create` returns a group handle (`group_ref:N` by default). Pass `--json` for the full structured payload.

### Examples

Group the three currently selected workspaces under a name:

```bash
cmux workspace-group create --name manaflow
```

Spin up a new workspace inside an existing group (e.g. wired to a worktree script):

```bash
cmux workspace-group new-workspace group_ref:1
```

List groups in the focused window:

```bash
cmux workspace-group list
```

## Configuration

Per-group configuration is keyed by the anchor's working directory in `~/.config/cmux/cmux.json` (this surface lands in a follow-up; the file location is reserved). The intent:

```json
{
  "workspaceGroups": {
    "byCwd": {
      "/Users/you/manaflow/cmux": {
        "color": "#7A4FD8",
        "icon": "ladybug.fill",
        "contextMenu": [
          { "label": "New worktree", "command": ["scripts/new-worktree.sh"] },
          { "action": "newWorkspace" }
        ]
      },
      "~/projects/*": {
        "icon": "leaf.fill"
      }
    }
  }
}
```

Matching: keys containing `*` or `?` are globs; otherwise they are path prefixes. Longest match wins.

## iMessage mode

When the sidebar is in iMessage mode (latest unread floats to top), two boolean knobs control how groups behave:

```json
{
  "sidebar": {
    "imessageMode": {
      "sortInsideGroups": true,
      "floatGroups": false
    }
  }
}
```

- `sortInsideGroups` (default `true`): workspaces inside each group sort by latest unread; group section position is unchanged.
- `floatGroups` (default `false`): the whole group section reorders by its most-recent unread member.

Both can be toggled from Settings → Sidebar → Groups (UI mirror lands alongside the config schema).

## Persistence

Groups (name, anchor, pin state, collapse state, color, icon) round-trip through `~/Library/Application Support/cmux/session-<bundle-id>.json` alongside workspaces. Membership lives on `Workspace.groupId`. Writes are atomic via the existing `SessionPersistenceStore` rename-into-place pattern.
