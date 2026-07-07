---
name: cmux-customization
description: "Customize cmux for an end user. Use when changing cmux.json actions, custom commands, workspace layouts, plus-button behavior, surface tab bar buttons, Command Palette entries, Dock controls, sidebar and app settings, shortcuts, notifications, browser routing, examples-library presets, or Ghostty-backed terminal preferences."
---

# cmux Customization

Use this skill for user-facing cmux customization. Keep the user's config intact, prefer schema-backed edits, and validate before reporting completion.

## What Can Be Customized

- Custom actions: define reusable `actions` in `cmux.json`. Actions can appear in Cmd+Shift+P, surface tab bars, shortcuts, the plus-button right-click menu, and — with `terminalContextMenu: true` — the terminal right-click context menu. While a TUI captures the mouse, shift+right-click still opens that menu (`terminal.shiftRightClickShowsMenu` setting, on by default).
- New workspace button: set `ui.newWorkspace.action` to replace the normal plus-button click, and `ui.newWorkspace.contextMenu` to control right-click actions. `ui.newWorkspace.rightClick` is accepted as an alias, but new examples should use `contextMenu`.
- Surface tab bar buttons: set `ui.surfaceTabBar.buttons` to replace the default tab bar buttons. Include built-in IDs such as `cmux.newTerminal`, `cmux.newBrowser`, `cmux.splitRight`, and `cmux.splitDown` only when they should stay visible.
- Workflows and layouts: use `commands` with workspace definitions to open a worktree, multiple checkouts, local services, browser previews, or SSH sessions in a deliberate split layout.
- Dock controls: create `.cmux/dock.json` or `~/.config/cmux/dock.json` for right-sidebar terminal controls such as logs, test watchers, git TUIs, dev servers, queues, or `cmux feed tui --opentui`.
- Sidebar and app behavior: use `cmux-settings` for supported settings such as appearance, sidebar display, notification behavior, browser routing, automation, shortcuts, and new-workspace placement.
- Workspace metadata: use the cmux CLI or `cmux-workspace` for workspace names, descriptions, colors, read state, and sidebar metadata updates.
- Feed and notifications: use `cmux hooks setup` for Feed event sources, notification settings for delivery behavior, and notification hooks in `cmux.json` for filtering or post-processing banners.
- Team presets and examples: use project-local `.cmux/cmux.json` and `.cmux/dock.json` to share worktree, SSH, review, dev, CI, and docs workspace patterns with a repo.
- Import, export, and reset: back up the current config, apply the smallest diff, validate it, and keep a rollback path for user-owned customizations.
- Terminal behavior: use Ghostty config for fonts, themes, cursor style, copy-on-select, shell integration, terminal keybindings, and terminal rendering.

## Choose the Right Surface

- cmux app preferences: use `cmux-settings` for global `~/.config/cmux/cmux.json` settings such as appearance, sidebar, notifications, browser behavior, automation, and shortcuts.
- Custom actions, workspace layouts, tab bar buttons, plus-button behavior, and Command Palette entries: edit `~/.config/cmux/cmux.json` globally or `.cmux/cmux.json` in the project. Project-local actions and commands override global entries with the same ID or name.
- Dock controls: edit `.cmux/dock.json` in the project or `~/.config/cmux/dock.json` globally. Run `cmux docs dock` when available.
- Terminal rendering and terminal keybindings: use Ghostty config, usually `~/.config/ghostty/config`. This includes fonts, cursor style, copy-on-select, shell integration, themes, and terminal keybindings.
- Project-specific behavior: prefer `.cmux/cmux.json` in the project so actions, commands, UI action wiring, and notification hooks travel with the repo. Do not put global app preferences there.

If a request can be handled by Ghostty config, say that and use Ghostty config instead of inventing cmux UI settings.

## Examples Library

For reusable patterns such as worktree agents, full-stack dev layouts, SSH
devboxes, PR review workspaces, docs workspaces, quick agent tab buttons, and
CI watches, read `references/examples.md`. Load it when the user asks for examples, presets,
templates, starter configs, or a known workflow shape.

## Workflow

1. Inspect existing config before editing.

   ```bash
   test -f ~/.config/cmux/cmux.json && sed -n '1,220p' ~/.config/cmux/cmux.json
   test -f .cmux/cmux.json && sed -n '1,220p' .cmux/cmux.json
   ```

2. Pick global or project-local scope. Ask only when the choice changes behavior meaningfully. Default to project-local for repo-specific commands and global for app preferences.
3. Before editing, back up the target file when it already exists:

   ```bash
   stamp="$(date +%Y%m%d-%H%M%S)"
   test -f ~/.config/cmux/cmux.json && cp -p ~/.config/cmux/cmux.json ~/.config/cmux/cmux.json."$stamp".bak
   test -f .cmux/cmux.json && cp -p .cmux/cmux.json .cmux/cmux.json."$stamp".bak
   ```

   Use the applicable path only. Do not create a backup for a missing file.
4. For app settings and cmux-owned shortcuts, use the settings helper from the installed skill or checkout:

   ```bash
   ~/.agents/skills/cmux-settings/scripts/cmux-settings list-supported
   ~/.agents/skills/cmux-settings/scripts/cmux-settings set browser.openTerminalLinksInCmuxBrowser true
   ~/.agents/skills/cmux-settings/scripts/cmux-settings validate
   ```

   If the user installed with `skills.sh`, use `~/.codex/skills/cmux-settings/scripts/cmux-settings` instead.
5. For actions, UI wiring, workspace layouts, notification hooks, and Dock controls, edit JSONC or JSON carefully. Preserve unrelated sections such as `vault`, `rightSidebar`, `commands`, `actions`, `ui`, and `notifications`.
6. Reload config after successful edits:

   ```bash
   cmux reload-config
   ```

7. Verify the configured entrypoint exists. For shortcuts, read back the binding. For custom actions, confirm the action ID and where it should appear.

## Common Patterns

Add a Command Palette action that opens Codex in a new tab. It will appear in Cmd+Shift+P unless `palette` is false:

```json
{
  "actions": {
    "codex-new-tab": {
      "type": "agent",
      "agent": "codex",
      "title": "Codex",
      "subtitle": "Start Codex in this workspace",
      "target": "newTabInCurrentPane",
      "palette": true
    }
  }
}
```

Replace the plus-button click and define the plus-button right-click menu.
This is the pattern for "bring your own worktree, multiple checkouts, or SSH
setup". The `workspaceCommand` action ID is `worktree-agents`, and its
`commandName` must match a command named `Worktree Agents` in the same config:

```json
{
  "actions": {
    "worktree-agents": {
      "type": "workspaceCommand",
      "title": "Worktree Agents",
      "commandName": "Worktree Agents",
      "icon": { "type": "symbol", "name": "folder.badge.plus" }
    }
  },
  "ui": {
    "newWorkspace": {
      "action": "worktree-agents",
      "contextMenu": [
        { "action": "worktree-agents", "title": "Worktree Agents" },
        { "type": "separator" },
        { "action": "cmux.newTerminal", "title": "New Terminal" },
        { "action": "cmux.newBrowser", "title": "New Browser" }
      ]
    }
  },
  "commands": [
    {
      "name": "Worktree Agents",
      "description": "Create a worktree and open agents inside it",
      "workspace": {
        "name": "Worktree Agents",
        "cwd": "../worktrees/my-feature",
        "layout": {
          "direction": "horizontal",
          "children": [
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "Codex", "command": "codex" }
                ]
              }
            },
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "SSH", "command": "ssh devbox" }
                ]
              }
            }
          ]
        }
      }
    }
  ]
}
```

Add a project workspace layout:

```json
{
  "commands": [
    {
      "name": "dev",
      "workspace": {
        "name": "Dev",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "children": [
            { "pane": { "surfaces": [{ "type": "terminal", "command": "bun dev" }] } },
            { "pane": { "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] } }
          ]
        }
      }
    }
  ]
}
```

Replace surface tab bar buttons:

```json
{
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        "cmux.newTerminal",
        "cmux.newBrowser",
        {
          "action": "codex-new-tab",
          "title": "Codex",
          "icon": { "type": "symbol", "name": "terminal" }
        }
      ]
    }
  }
}
```

Add project Dock controls:

```json
{
  "controls": [
    {
      "id": "git",
      "title": "Git",
      "command": "lazygit",
      "cwd": ".",
      "height": 300
    },
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui --opentui",
      "height": 260
    }
  ]
}
```

## Validation

- App settings: run `cmux-settings validate`.
- JSONC shape: keep valid JSONC and avoid duplicate keys.
- Dock JSON: parse `.cmux/dock.json` or `~/.config/cmux/dock.json` with a JSON parser before reporting completion.
- Runtime reload: run `cmux reload-config` when the CLI is available.
- User-facing action: confirm the action title, shortcut, plus-button behavior, context-menu entry, or tab bar placement the user asked for.

## Rules

- Do not overwrite whole top-level config sections unless you own the full section.
- Do not store secrets directly in actions, commands, or prompts. Use environment variables or the user's secret manager.
- Do not use app/runtime sleeps or timing workarounds in generated commands.
- Do not add a cmux setting for behavior Ghostty already owns.
- Keep labels short enough for menus, buttons, and the Command Palette.
