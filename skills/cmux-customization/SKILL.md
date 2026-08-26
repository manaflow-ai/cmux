---
name: cmux-customization
description: "Customize cmux for an end user. Use when changing cmux.json actions, custom commands, workspace layouts, plus-button behavior, surface tab bar buttons, Command Palette entries, Dock controls, sidebar and app settings, shortcuts, notifications, browser routing, examples-library presets, or Ghostty-backed terminal preferences."
---

# cmux Customization

Keep the user's config intact, prefer schema-backed edits, and validate before reporting completion.

## Choose the right surface

| Want to change | Edit |
|---|---|
| App preferences (appearance, sidebar, notifications, browser routing, automation, shortcuts, new-workspace placement) | `~/.config/cmux/cmux.json` via the `cmux-settings` helper |
| Custom actions, workspace layouts/commands, tab bar buttons, plus-button behavior, Command Palette entries, notification hooks | `~/.config/cmux/cmux.json` globally or `.cmux/cmux.json` in the project |
| Dock controls (right-sidebar terminals: logs, test watchers, git TUIs, dev servers, queues, `cmux feed tui --opentui`) | `.cmux/dock.json` or `~/.config/cmux/dock.json`; `cmux docs dock` when available |
| Terminal rendering and terminal keybindings (fonts, themes, cursor style, copy-on-select, shell integration) | Ghostty config, usually `~/.config/ghostty/config` |
| Workspace names, descriptions, colors, read state, sidebar metadata | cmux CLI, see [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) |
| Feed event sources | `cmux hooks setup` |

Project-local `.cmux/cmux.json` and `.cmux/dock.json` let worktree, SSH, review, dev, CI, and docs patterns travel with the repo; project actions and commands override global entries with the same ID or name. Global app preferences do not belong there.

If a request can be handled by Ghostty config, say so and use Ghostty config instead of inventing cmux UI settings.

Key surfaces in `cmux.json`: `actions` (reusable, can appear in Cmd+Shift+P, surface tab bars, shortcuts, and the plus-button right-click menu), `ui.newWorkspace.action` (replaces the plus-button click) and `ui.newWorkspace.contextMenu` (right-click menu; `ui.newWorkspace.rightClick` is an accepted alias but new examples use `contextMenu`), `ui.surfaceTabBar.buttons` (replaces default tab bar buttons; include built-ins like `cmux.newTerminal`, `cmux.newBrowser`, `cmux.splitRight`, `cmux.splitDown` only when they should stay visible), and `commands` (workspace definitions with split layouts).

## Workflow

1. Inspect existing config.

   ```bash
   test -f ~/.config/cmux/cmux.json && sed -n '1,220p' ~/.config/cmux/cmux.json
   test -f .cmux/cmux.json && sed -n '1,220p' .cmux/cmux.json
   ```

2. Pick global or project-local scope. Default to project-local for repo-specific commands, global for app preferences. Ask only when the choice changes behavior meaningfully.
3. Back up the target file when it already exists (applicable path only, no backup for a missing file).

   ```bash
   stamp="$(date +%Y%m%d-%H%M%S)"
   test -f ~/.config/cmux/cmux.json && cp -p ~/.config/cmux/cmux.json ~/.config/cmux/cmux.json."$stamp".bak
   test -f .cmux/cmux.json && cp -p .cmux/cmux.json .cmux/cmux.json."$stamp".bak
   ```

4. For app settings and cmux-owned shortcuts, use the settings helper (`~/.codex/skills/...` if the user installed with `skills.sh`).

   ```bash
   ~/.agents/skills/cmux-settings/scripts/cmux-settings list-supported
   ~/.agents/skills/cmux-settings/scripts/cmux-settings set browser.openTerminalLinksInCmuxBrowser true
   ~/.agents/skills/cmux-settings/scripts/cmux-settings validate
   ```

5. For actions, UI wiring, workspace layouts, notification hooks, and Dock controls, edit the JSONC by hand and preserve unrelated sections (`vault`, `rightSidebar`, `commands`, `actions`, `ui`, `notifications`).
6. `cmux reload-config`.
7. Verify the configured entrypoint exists: read back the shortcut binding, or confirm the action ID and where it should appear.

## Example: Command Palette action

Appears in Cmd+Shift+P unless `palette` is false.

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

For worktree agents, full-stack dev layouts, SSH devboxes, PR review workspaces, docs workspaces, tab bar buttons, and CI watch Dock controls, read [references/examples.md](references/examples.md). Load it when the user asks for examples, presets, templates, starter configs, or a known workflow shape.

## Validation

- App settings: `cmux-settings validate`.
- Keep valid JSONC, no duplicate keys.
- Parse `.cmux/dock.json` or `~/.config/cmux/dock.json` with a JSON parser before reporting completion.
- `cmux reload-config` when the CLI is available.
- Confirm the exact user-facing result: action title, shortcut, plus-button behavior, context-menu entry, or tab bar placement.

## Rules

- Do not overwrite a whole top-level config section unless you own the full section.
- Do not store secrets in actions, commands, or prompts. Use environment variables or the user's secret manager.
- Do not use sleeps or timing workarounds in generated commands.
- Do not add a cmux setting for behavior Ghostty already owns.
- Keep labels short enough for menus, buttons, and the Command Palette.
