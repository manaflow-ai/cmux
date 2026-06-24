# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `app.windowTitleTemplate`

Opt-in template for the macOS `NSWindow.title`. Leave it unset or set it to an empty string to keep the default behavior, where the title follows the active workspace title or current directory.

```json
{
  "app": {
    "windowTitleTemplate": "[cmux:{windowToken}] {activeWorkspace}"
  }
}
```

Supported placeholders:

- `{windowId}`: the persisted per-window UUID.
- `{windowToken}`: the first 8 characters of the persisted window UUID.
- `{activeWorkspace}`: the active workspace title, falling back to the default title when the workspace title is blank.
- `{activeDirectory}`: the active workspace's current directory.
- `{defaultTitle}`: the title cmux would have used without a template.
- `{appName}`: `cmux`.

For tiling window managers such as AeroSpace or yabai, match on the stable token in the title. For example, the template above gives each restored macOS window a title containing `[cmux:abcd1234]`, so a rule can match `\\[cmux:abcd1234\\]`. The token is stable across relaunches for restored windows because it comes from the persisted window UUID.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable and nightly builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## `app.forkConversationDefaultDestination`

Controls what the tab right-click `Fork Conversation` item does. The submenu still exposes every destination.

Values: `right`, `left`, `top`, `bottom`, `newTab`, `newWorkspace`.

Default: `right`.

## `terminal.agentHibernation`

Opt-in Agent Hibernation. cmux kills idle background agent processes to free RAM and CPU, then resumes each one with its saved session when you visit its tab. See [agent-hooks.md](agent-hooks.md#agent-hibernation) for the full behavior, including the confirmation settle window and how resume works.

```json
{
  "terminal": {
    "agentHibernation": {
      "enabled": true,
      "idleSeconds": 5,
      "maxLiveTerminals": 12
    }
  }
}
```

- `enabled`: turn Agent Hibernation on. Default: `false`.
- `idleSeconds`: seconds a background idle agent terminal must be quiet before it can hibernate. A ~60s confirmation settle window still applies on top of this. Default: `5`. Range: `5`-`604800`.
- `maxLiveTerminals`: how many live restorable agent terminals to keep before cmux hibernates the oldest idle background ones. Nothing hibernates while you are at or under this count. Default: `12`. Range: `1`-`256`.

Enable it from the command palette (`⌘⇧P` -> Enable Agent Hibernation), from **Settings > Terminal > Agent Hibernation**, or with `cmux agent-hibernation on`.

## `terminal.textBoxSubmitActions`

Controls what the TextBox submit button does for new terminal sessions. Active agent sessions such as Claude, Codex, OpenCode, and Pi always use plain Text Entry so prompts go into the running agent instead of launching another command. Terminals without an idle prompt report also use Text Entry.

Press Shift-Tab in the TextBox to cycle the default action. This shortcut is `shortcuts.bindings.cycleTextBoxSubmitAction`; rebind or disable it from Settings > Keyboard Shortcuts or `cmux.json`. Right-click the submit button to pick any configured action or open this documentation.

```json
{
  "terminal": {
    "textBoxDefaultSubmitAction": "codex",
    "textBoxSubmitActions": [
      {
        "id": "codex",
        "title": "Codex Yolo",
        "kind": "commandTemplate",
        "commandTemplate": "codex --dangerously-bypass-approvals-and-sandbox",
        "preservePromptAfterLaunch": true,
        "systemImage": "sparkles",
        "assetName": "AgentIcons/Codex",
        "backgroundColorHex": "#8FDBFF"
      },
      {
        "id": "custom-router",
        "title": "Custom Router",
        "kind": "commandTemplate",
        "commandTemplate": "agent-router --plan {{prompt}}",
        "systemImage": "wand.and.stars",
        "imagePath": "~/Pictures/router.png",
        "backgroundColorHex": "#3DDC97"
      }
    ]
  }
}
```

Built-in action IDs: `claude`, `codex`, `opencode`, `pi`.

Set `textBoxDefaultSubmitAction` to `text-entry` to force plain Text Entry for new terminals.
Built-in Claude and Codex actions launch with their dangerous/yolo permission flags and keep the prompt in the TextBox. Claude also sets `CLAUDE_CODE_SANDBOXED=1` and `--permission-mode bypassPermissions` so the dangerous action starts in the intended mode. Once the provider owns the terminal, submit again to send the prompt through Text Entry. This avoids storing prompt text in shell history or process arguments.

Action fields:

- `id`: stable action ID.
- `title`: menu label for custom actions.
- `kind`: `textEntry` or `commandTemplate`.
- `commandTemplate`: shell command for `commandTemplate`. Include `{{prompt}}` only when the prompt should be shell-quoted into the command line. For privacy, prefer a prompt-free provider launch command plus `preservePromptAfterLaunch`.
- `preservePromptAfterLaunch`: optional boolean. When `true`, cmux submits `commandTemplate` as a provider launch command while keeping the TextBox prompt intact for the active agent session.
- `systemImage`: fallback SF Symbol name shown on the submit button.
- `assetName`: optional app asset catalog image name, for example `AgentIcons/Codex`.
- `imagePath`: optional PNG or image path for the submit button.
- `backgroundColorHex`: submit button fill color.

## `automation.workspaceAutoNaming`

Opt-in AI auto-naming of workspaces and tabs from agent conversation content. When enabled, cmux summarizes supported agent sessions into short sidebar and tab names using each agent's own binary, and refreshes them as the conversation topic shifts. See [workspace-auto-naming.md](workspace-auto-naming.md) for the supported adapter list and full behavior.

```json
{
  "automation": {
    "workspaceAutoNaming": true
  }
}
```

Default: `false`. Manual renames (sidebar, command palette, CLI, or `/rename`) always win: a workspace or tab you renamed yourself is never auto-named again until you clear its custom name. Enable it from **Settings > Automation > Workspace Auto-Naming**.

## `diffViewer.defaultLayout`

Controls the initial layout for newly opened diff viewers.

Values: `unified`, `split`.

Default: `unified`.

```json
{
  "diffViewer": {
    "defaultLayout": "unified"
  }
}
```

The toolbar layout toggle persists the last user choice for future generated diff viewers. Passing `cmux diff --layout split` or `cmux diff --layout unified` overrides both the saved toolbar choice and this default for that invocation.
