---
name: cmux-customization
description: "Customize cmux for an end user. Use when changing cmux.json actions, custom commands, workspace layouts, Command Palette entries, surface toolbar buttons, shortcuts, notifications, browser routing, appearance, or Ghostty-backed terminal preferences."
---

# cmux Customization

Use this skill for user-facing cmux customization. Keep the user's config intact, prefer schema-backed edits, and validate before reporting completion.

## Choose the Right Surface

- cmux app preferences: use `cmux-settings` for `~/.config/cmux/cmux.json` settings such as appearance, sidebar, notifications, browser behavior, automation, and shortcuts.
- Custom actions, workspace layouts, toolbar buttons, plus-button behavior, and Command Palette entries: edit `~/.config/cmux/cmux.json` globally or `.cmux/cmux.json` in the project.
- Terminal rendering and terminal keybindings: use Ghostty config, usually `~/.config/ghostty/config`. This includes fonts, cursor style, copy-on-select, shell integration, themes, and terminal keybindings.
- Project-specific behavior: prefer `.cmux/cmux.json` in the project so the customization travels with the repo.

If a request can be handled by Ghostty config, say that and use Ghostty config instead of inventing cmux UI settings.

## Workflow

1. Inspect existing config before editing.

   ```bash
   test -f ~/.config/cmux/cmux.json && sed -n '1,220p' ~/.config/cmux/cmux.json
   test -f .cmux/cmux.json && sed -n '1,220p' .cmux/cmux.json
   ```

2. Pick global or project-local scope. Ask only when the choice changes behavior meaningfully. Default to project-local for repo-specific commands and global for app preferences.
3. For app settings and cmux-owned shortcuts, use the settings helper from the installed skill or checkout:

   ```bash
   ~/.agents/skills/cmux-settings/scripts/cmux-settings list-supported
   ~/.agents/skills/cmux-settings/scripts/cmux-settings set browser.openTerminalLinksInCmuxBrowser true
   ~/.agents/skills/cmux-settings/scripts/cmux-settings validate
   ```

   If the user installed with `skills.sh`, use `~/.codex/skills/cmux-settings/scripts/cmux-settings` instead.
4. For actions and workspace layouts, edit JSONC carefully. Preserve unrelated sections such as `vault`, `rightSidebar`, `commands`, `actions`, `ui`, and `notifications`.
5. Reload config after successful edits:

   ```bash
   cmux reload-config
   ```

6. Verify the configured entrypoint exists. For shortcuts, read back the binding. For custom actions, confirm the action ID and where it should appear.

## Common Patterns

Add a Command Palette action that opens Codex in a new tab:

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

Add a project workspace layout:

```json
{
  "commands": [
    {
      "name": "dev",
      "type": "workspace",
      "cwd": ".",
      "layout": {
        "type": "split",
        "direction": "horizontal",
        "children": [
          { "type": "pane", "surfaces": [{ "type": "terminal", "command": "bun dev" }] },
          { "type": "pane", "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] }
        ]
      }
    }
  ]
}
```

Add surface toolbar buttons:

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

## Validation

- App settings: run `cmux-settings validate`.
- JSONC shape: keep valid JSONC and avoid duplicate keys.
- Runtime reload: run `cmux reload-config` when the CLI is available.
- User-facing action: confirm the action title, shortcut, or toolbar placement the user asked for.

## Rules

- Do not overwrite whole top-level config sections unless you own the full section.
- Do not store secrets directly in actions, commands, or prompts. Use environment variables or the user's secret manager.
- Do not use app/runtime sleeps or timing workarounds in generated commands.
- Do not add a cmux setting for behavior Ghostty already owns.
- Keep labels short enough for menus, buttons, and the Command Palette.
