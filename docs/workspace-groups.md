# Workspace Groups

Workspace groups let you nest workspaces into collapsible named sections in the sidebar. Each group has an implicit "anchor workspace," a customizable `+` button for spawning new workspaces inside it, and right-click actions for renaming, pinning, ungrouping, and editing its configuration.

## Concepts

### Anchor workspace

Every group is owned by exactly one workspace called the **anchor**. The group header in the sidebar IS the anchor's representation — there is no separate row for it. Clicking the header name area focuses the anchor's panels. Clicking the chevron toggles collapse.

When a group is created from existing workspaces, the first listed workspace becomes the anchor and no extra terminal is created. An empty group gets a new generated anchor. The anchor's working directory is inherited from the first selected workspace (when grouping a selection) or from the active workspace (when creating via the CLI without `--cwd`). A generated anchor that is still an untouched shell is skipped when you click the header name area and the first real member is focused instead.

Closing the anchor workspace closes only that workspace and **promotes the group's next member to be the new anchor**, so the group and its other members stay intact (the promoted member then shows the group name as the header). When the anchor is the group's only workspace, the group is removed. To flatten a group back into ungrouped workspaces, use **Ungroup**; to close every workspace in a group, use **Delete Group**.

### Group identity

A group has a `name`, `iconSymbol` (an SF Symbol, default `folder.fill`), and an optional `customColor` (hex string). Automation can also provide an `external_id` (or `idempotency_key`) as a caller-owned identity scoped to the window. Repeating `workspace.group.create` with that identity returns the existing group instead of creating another anchor. Names are not identities: users may have multiple groups with the same name.

The current anchor carries explicit provenance. Only an anchor created by cmux can be removed through the guarded anchor-cleanup option; a user-selected or promoted anchor is never inferred to be disposable.

### Pinning

Groups can be pinned independently of individual workspace pins. Pinned top-level rows, whether individual workspaces or groups, stay above unpinned rows. Within each tier, groups and workspaces keep the order you drag them into.

The sidebar layout, top to bottom:
1. Pinned top-level rows (workspaces and groups).
2. Unpinned top-level rows (workspaces and groups).

## Creating a group

### From the keyboard (`⌃⌘G` or `⌘⇧G`)

Press `⌃⌘G` to create a new empty workspace group. cmux inserts a fresh anchor workspace as the group header and auto-names it `Group 1`, `Group 2`, … (rename anytime via the header context menu).

Select two or more workspaces in the sidebar, press `⌘⇧G`. The first selected workspace becomes the anchor; all selected workspaces become children without creating an extra terminal. The group is auto-named `Group 1`, `Group 2`, … (rename anytime via the header context menu). `⌘⇧G` collides with React Grab's default; the group handler only consumes the chord when there is an explicit sidebar multi-selection of at least two workspaces, so React Grab still fires in single-selection and browser/terminal contexts. Rebind in Settings → Keyboard if you'd rather the two not share a key.

Single-tab groups are not created from the shortcut. Use the workspace context menu's **New Group from Workspace** entry for that.

### From a workspace context menu

Right-click any workspace in the sidebar, choose **New Empty Workspace Group** for an anchor-only group, **New Group from Workspace** for a group containing that workspace, or **New Group from Selection** when multiple workspaces are selected. The blank area below the sidebar list also offers **New Empty Workspace Group**. Same auto-naming behavior as the shortcuts.

### From the group header context menu

Right-click an existing group's header for: **Rename Group…**, **Pin / Unpin Group**, **Edit Group Config…** (opens `~/.config/cmux/cmux.json`), **Open Workspace Groups Docs**, **Ungroup Workspaces**, **Delete Group**. Ungroup Workspaces keeps the workspaces and removes only the group container. Delete Group closes the group header workspace and every workspace inside the group; if the group contains child workspaces, it prompts for confirmation first.

### From the `+` button on a group header

Hover over a group header to reveal a trailing `+` button. Click to create a new workspace in the group at the anchor's cwd. Right-click for **New Workspace in Group**, **Edit Group Config…**, and **Open Workspace Groups Docs**.

Pressing `⌘N` while the active workspace is a group anchor or group member also creates the workspace inside that group. The default group placement is **After current**: from a regular group member, the new workspace lands right after the active member; from the anchor/header, it lands at the top of the group.

## CLI

Groups are scriptable with `cmux workspace group …`. Group and workspace arguments take a group id or key and a workspace id or key.

```bash
cmux workspace group list
cmux workspace group create --name "manaflow" [--color <token|#hex>] [--id <id>] [--index <n>] [--collapse]
cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color] [--collapse|--expand]
cmux workspace group <group> delete
cmux workspace group <group> move --index <n>
cmux workspace group <group> add --workspace <key|id> [--index <n>]
cmux workspace group remove --workspace <key|id>
```

The rest are app actions on the focused group, or the one `--target` names (list them with `cmux action list --noun workspace-group`):

```bash
cmux workspace-group new-workspace
cmux workspace-group ungroup
cmux workspace-group toggle-pin
cmux workspace-group close-workspaces     # closes every member workspace
```

The Swift CLI's `cmux workspace-group …` flags `--cwd`, `--from`, `--idempotency-key`, `--external-id`, `--remove-generated-anchor`, `--close-workspaces`, and `--placement`, and the `set-anchor` verb, were removed with no Rust equivalent yet (see [plans/cmux-next/cli.md](../plans/cmux-next/cli.md)).

### Examples

Group two explicitly chosen workspaces under a name:

```bash
cmux workspace group create --name manaflow --id manaflow
cmux workspace group manaflow add --workspace ws_0123456789abcdef0123456789abcdef
cmux workspace group manaflow add --workspace ws_fedcba9876543210fedcba9876543210
```

List groups:

```bash
cmux --json workspace group list
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
1. Explicit `"placement"` in the v2 `workspace.group.new_workspace` params.
2. The per-cwd entry above.
3. Global default via Settings > App > Group New Workspace Placement or `workspaceGroups.newWorkspacePlacement` in `cmux.json` (defaults to `afterCurrent`).

`Cmd-N` inside a group uses the active group workspace as the placement reference. The group header `+` button and CLI path use the anchor as the reference, so `afterCurrent` behaves like `top` there.

## iMessage mode (planned)

When the sidebar is in iMessage mode (latest unread floats to top), the intended behavior for groups is two boolean knobs:

- `sortInsideGroups` (default `true`): workspaces inside each group sort by latest unread; group section position is unchanged.
- `floatGroups` (default `false`): the whole group section reorders by its most-recent unread member.

Neither knob is wired up yet. The current build keeps the sidebar's existing iMessage-mode behavior unchanged regardless of groups. A follow-up will add the `sidebar.imessageMode.*` keys to `cmux.json`, the schema, and the Settings UI; this section is documented here so the eventual JSON shape is decided up front.

## Persistence

Groups (name, anchor, pin state, collapse state, color, icon, external identity, and anchor provenance) round-trip through `~/Library/Application Support/cmux/session-<bundle-id>.json` alongside workspaces. Membership lives on `Workspace.groupId`. Writes are atomic via the existing `SessionPersistenceStore` rename-into-place pattern.
