# Workspace Color Commands

## set-workspace-color

Set or clear the custom color for a workspace tab.

```bash
cmux set-workspace-color [--workspace <id|ref|index>] (--clear | [--] <#hex>)
```

**Flags:**
- `--workspace <id|ref|index>` - Target workspace (default: current / `$CMUX_WORKSPACE_ID`)
- `--clear` - Remove the custom color (mutually exclusive with `<#hex>`)

**Examples:**
```bash
cmux set-workspace-color "#C0392B"
cmux set-workspace-color --workspace workspace:2 "#1565C0"
cmux set-workspace-color --workspace workspace:3 --clear
```

**Socket method:** `workspace.set_color`
```json
// Set color
{ "workspace_id": "<uuid>", "color": "#C0392B" }

// Clear color
{ "workspace_id": "<uuid>", "color": null }
```

## notify (color support)

The `notify` command now accepts an optional `--color` flag. If omitted, notifications automatically inherit the source workspace's `customColor`.

```bash
cmux notify --title <text> [--body <text>] [--color <#hex>]
```

**Examples:**
```bash
# Inherits workspace color
cmux notify --title "Done" --body "Task complete"

# Explicit override
cmux notify --title "Alert" --body "Disk full" --color "#C0392B"
```

## list-workspaces (color in response)

`workspace.list` now includes `custom_color` in each workspace entry:

```json
{
  "workspaces": [
    {
      "id": "...",
      "ref": "workspace:1",
      "title": "backend",
      "custom_color": "#C0392B",
      "selected": true,
      "pinned": false
    }
  ]
}
```

`custom_color` is `null` when no color is set.

## list-notifications (color in response)

`notification.list` now includes `color` in each notification entry:

```json
{
  "notifications": [
    {
      "id": "...",
      "title": "Build done",
      "color": "#C0392B",
      "is_read": false
    }
  ]
}
```
