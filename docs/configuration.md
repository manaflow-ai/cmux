# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `mobile.artifactFolderAccess`

Controls which files and folders cmux on iOS may browse after a chat references a directory or a directory path appears in a terminal.

```json
{
  "mobile": {
    "artifactFolderAccess": "subtree"
  }
}
```

- `subtree` (default): authorize the referenced directory and its full subtree.
- `oneLevel`: preserve the previous rule, authorizing only immediate children and listing only the referenced directory itself.

Authorization compares canonical paths after resolving symlinks. A symlink inside an authorized folder cannot grant access to a target outside that folder.

## `paneBorderColor` and `activePaneBorderColor`

Customize split-workspace pane boundaries controlled by cmux.

```json
{
  "paneBorderColor": "#6B7280",
  "activePaneBorderColor": "#3B82F6"
}
```

- `paneBorderColor`: overrides the divider color between cmux panes in split workspaces.
- `activePaneBorderColor`: draws a border around the focused cmux pane in split workspaces.

Both settings accept 6-digit hex colors (`#RRGGBB`). Omit a key, or set it to `null`, to keep the built-in appearance. These settings apply to cmux's multi-surface pane layout, not Ghostty's internal splits; Ghostty settings such as `split-divider-color` still only affect splits inside one Ghostty instance.

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

## `ui.newWorkspace.menuSectionOrder`

Controls the section order in the titlebar `+` button menu. The Cloud VM section is built in; the custom section comes from `ui.newWorkspace.contextMenu`.

Values: `customFirst`, `cloudFirst`.

Default: `cloudFirst`.

```json
{
  "ui": {
    "newWorkspace": {
      "menuSectionOrder": "customFirst",
      "contextMenu": [
        "newWorkspace"
      ]
    }
  }
}
```

`sectionOrder` is accepted as an alias. Project-local `.cmux/cmux.json` values override the global setting.

## `terminal.agentHibernation`

Routine Agent Hibernation is opt-in. cmux kills idle background agent processes to free RAM and CPU, then resumes each one with its saved session when you visit its tab. Independently, critical memory pressure can trigger a bounded safety pass over eligible idle background agents even when routine hibernation is disabled. See [agent-hooks.md](agent-hooks.md#agent-hibernation) for the full eligibility rules, confirmation settle window, and resume behavior.

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

- `enabled`: turn routine Agent Hibernation on. Default: `false`. Critical-pressure safety hibernation remains active when this is `false`.
- `idleSeconds`: seconds a background idle agent terminal must be quiet before it can hibernate. A ~60s confirmation settle window still applies on top of this. Default: `5`. Range: `5`-`604800`.
- `maxLiveTerminals`: how many live restorable agent terminals to keep before cmux hibernates the oldest idle background ones. Nothing hibernates while you are at or under this count. Default: `12`. Range: `1`-`256`.

Enable routine hibernation from the command palette (`⌘⇧P` -> Enable Agent Hibernation), from **Settings > Terminal > Agent Hibernation**, or with `cmux agent-hibernation on`.

## `sidebar.showAgentActivity`

Shows a loading spinner on sidebar workspace rows that currently have running coding agents or active manual loaders (`cmux workspace loading on`).

```json
{
  "sidebar": {
    "showAgentActivity": true,
    "loadingSpinnerPosition": "leading",
    "notificationBadgePosition": "leading"
  }
}
```

- `showAgentActivity`: show the spinner at all. Default: `true`. It is a live status signal, so it stays visible even when `sidebar.hideAllDetails` is on. Toggle it from **Settings > Sidebar > Show Loading Spinner**.
- `loadingSpinnerPosition`: `leading` (left, sharing the unread-badge slot) or `trailing` (right, in the close-button corner). Default: `leading`.
- `notificationBadgePosition`: which side the unread notification badge sits on, `leading` or `trailing`. Default: `leading`.

The spinner is compositor-driven (a Core Animation transform run by the render server), so it costs no per-frame CPU and pauses automatically while the window is occluded or Reduce Motion is on. Toggle it manually per workspace with `cmux workspace loading <on|off> [--id <name>]`; each `--id` is a separate loader and the command prints the workspace state as `before=ON;after=OFF`.

## `terminal.showTextBoxOnNewTerminals` and `terminal.focusTextBoxOnNewTerminals`

`terminal.showTextBoxOnNewTerminals` opens the TextBox on newly-created terminal sessions without moving keyboard focus into it.

`terminal.focusTextBoxOnNewTerminals` opens the TextBox and focuses it for foreground terminal sessions created from the app UI, such as new terminal workspaces, tabs, and splits. Terminals created through the cmux CLI/control socket do not auto-focus the TextBox, even when this setting is enabled, so background automation does not steal keyboard focus.

## Workspace terminal font size shortcuts

Cmd+Ctrl+= and Cmd+Ctrl+- increase or decrease every terminal in the selected workspace by one point. Cmd+Ctrl+0 resets them to the current Ghostty font size. Hidden, hibernated, and Dock terminals change with visible terminals, and newly created terminals inherit the workspace size. Rebind them with `shortcuts.bindings.increaseWorkspaceTerminalFontSize`, `shortcuts.bindings.decreaseWorkspaceTerminalFontSize`, and `shortcuts.bindings.resetWorkspaceTerminalFontSize`.

## `terminal.textBoxSubmitActions`

Controls what the TextBox submit button does for new terminal sessions. Active agent sessions such as Claude, Codex, OpenCode, and Pi always use plain Text Entry so prompts go into the running agent instead of launching another command.

Press Shift-Tab in the TextBox to cycle the default action. This shortcut is `shortcuts.bindings.cycleTextBoxSubmitAction`; rebind or disable it from Settings > Keyboard Shortcuts or `cmux.json`. Right-click the submit button to pick any configured action or open this documentation.

```json
{
  "terminal": {
    "textBoxDefaultSubmitAction": "codex",
    "textBoxSubmitActions": [
      {
        "id": "codex",
        "title": "Codex --yolo",
        "kind": "commandTemplate",
        "commandTemplate": "codex --yolo -- {{prompt}}",
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
Built-in provider actions shell-quote `{{prompt}}` before pasting the command. Claude may still show its workspace trust prompt before processing the prompt. Built-ins run `claude --dangerously-skip-permissions -- {{prompt}}`, `codex --yolo -- {{prompt}}`, `opencode --prompt {{prompt}}`, and `pi -- {{prompt}}`.

Action fields:

- `id`: stable action ID.
- `title`: menu label for custom actions.
- `kind`: `textEntry` or `commandTemplate`.
- `commandTemplate`: shell command for `commandTemplate`. Include `{{prompt}}` where the prompt should be shell-quoted into the command line.
- `preservePromptAfterLaunch`: optional boolean for custom launch-only actions. When `true`, cmux submits `commandTemplate` as a provider launch command while keeping the TextBox prompt intact for the active agent session.
- `systemImage`: fallback SF Symbol name shown on the submit button.
- `assetName`: optional app asset catalog image name, for example `AgentIcons/Codex`.
- `imagePath`: optional PNG or image path for the submit button.
- `backgroundColorHex`: action color metadata as RGB or RGBA hex. The submit button fill stays white and only changes opacity between enabled and disabled states.

## `terminal.uploadCommands`

Replace the built-in `scp` for terminal file drops and pastes over SSH with a
command you choose. When you drop or paste a file into a terminal running an SSH
session, cmux normally `scp`s it to `/tmp/cmux-drop-<uuid>` on the host and types
the remote path. `terminal.uploadCommands` is an ordered list of host-scoped
rules; when the ssh destination matches a rule, cmux runs that rule's command
instead and inserts what the command prints.

```json
{
  "terminal": {
    "uploadCommands": [
      {
        "hostPattern": "*.example.com",
        "command": "my-upload \"$CMUX_UPLOAD_LOCAL_PATH\" \"$CMUX_UPLOAD_DESTINATION:$CMUX_UPLOAD_REMOTE_PATH\""
      }
    ]
  }
}
```

- `hostPattern`: an fnmatch glob matched against the ssh destination (`user@` and
  IPv6 brackets stripped, then lowercased) — the same glob style as a single
  `ssh_config` `Host` pattern (`*`, `?`; no pattern lists or `!` negation). Omit
  it, or set it to `null`, for a catch-all.
- `command`: run through `/bin/sh -c`, **once per file**. It receives the file and
  endpoint on its environment: `CMUX_UPLOAD_LOCAL_PATH`, `CMUX_UPLOAD_REMOTE_PATH`
  (the `/tmp/cmux-drop-<uuid>` path cmux picked), `CMUX_UPLOAD_DESTINATION`,
  `CMUX_UPLOAD_PORT`, `CMUX_UPLOAD_IDENTITY_FILE`, and `CMUX_UPLOAD_SSH_OPTIONS`
  (newline-separated; the last three are unset when the session has none). The
  rest of the environment is inherited, so a one-liner resolves tools on `PATH`.
- `enabled`: set to `false` to keep a rule in the list but skip it. Defaults to
  `true`.

**First matching enabled rule wins.** If no rule matches, the built-in `scp` runs
unchanged, so other hosts are untouched.

### How the command's output is used

cmux inserts the command's **stdout** at the cursor:

- Non-empty stdout is inserted **verbatim** (with control characters stripped),
  so a rule can emit a remote path, a URL, or any reference — for example a line
  an agent in the terminal will read.
- If the command prints **nothing**, cmux inserts the shell-escaped remote path it
  chose, so the simplest rule just moves the file and behaves like the built-in.
- For a multi-file drop, each file's output is joined with spaces.

The output is **inserted, not executed** — nothing auto-submits, and you review it
before pressing Enter. Because it is inserted verbatim (rather than shell-escaped
like the built-in path), a rule's stdout should be trusted: it can land at a shell
prompt. A non-zero exit, a timeout, or cancelling from the transfer indicator
inserts nothing — exactly like an `scp` failure.

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

## `sidebar.beta.workspaceTodos.checklistStyle`

Workspace todos are always available. Status is inferred from live signals (agent needs input / agent running / open PR / merged PRs / dirty tree) and can be pinned manually from the glyph's status popover, the row's context menu (Status submenu, Mark as Done), the command palette, or `cmux workspace status set <lane|auto>`; checklists are managed from the row, the workspace todo pane (`cmux todo open`), `cmux todo ...`, or by agents over the control socket.

`checklistStyle` picks how a row's checklist opens from its summary line: `popover` (default) anchors a checklist popover to the summary line; `inline` expands the items under the row like round one.

```json
{
  "sidebar": {
    "beta": {
      "workspaceTodos": {
        "checklistStyle": "popover"
      }
    }
  }
}
```

Default: `enabled: false`. The setting turns on automatically the first time a status or checklist mutation succeeds from any entrypoint.

Three keyboard shortcuts drive the todo state, all editable in **Settings > Keyboard Shortcuts** or `shortcuts.bindings`:

- `markWorkspaceDone` (default `cmd+;`) pins the selected workspace's status to done.
- `cycleWorkspaceStatus` (default `cmd+shift+;`) advances the status one lane forward (todo → working → needs-attention → review → done → todo).
- `toggleChecklistItemComplete` (default `cmd+return`) toggles the highlighted checklist item in the focused todo pane or checklist popover.

cmux also posts a notification when a workspace's status first reaches done, and when its checklist first becomes fully complete, so you can watch agent progress without keeping the pane open.

## `terminal.newSurfaceWorkingDirectory`

Choose the working directory used by ordinary new local panes, terminal tabs,
splits, and workspaces. Explicit `cwd`/working-directory requests, remote
startup commands, restored sessions, and layout-managed surfaces keep their
own directories.

```json
{
  "terminal": {
    "newSurfaceWorkingDirectory": {
      "policy": "fixedPath",
      "path": "~/Projects/cmux"
    }
  }
}
```

- `inheritActivePane` (default): use the active pane's reported directory,
  falling back to the workspace root when it is unavailable.
- `workspaceRoot`: use the directory captured when the workspace was created;
  later `cd` commands do not change this root.
- `fixedPath`: use `path` when it expands to an existing directory. Relative
  paths, missing paths, and regular files fail closed to the workspace root.

## `terminal.shellStartup`

Set the default shell invocation and optional startup input for ordinary new
local surfaces. The setting is read from `cmux.json` when each surface starts,
so edits take effect without restarting cmux.

```json
{
  "terminal": {
    "shellStartup": {
      "mode": "nonLogin",
      "command": "mise activate zsh"
    }
  }
}
```

- `mode`: `login` (default) or `nonLogin`. The latter still starts an
  interactive shell and preserves cmux shell integration.
- `command`: optional one-shot input sent after the shell starts. It is not
  applied to surfaces with explicit commands or input, remote sessions,
  restored surfaces, manual tmux mirrors, or Ghostty-owned commands.

Keyboard shortcuts and other app settings are read from the same schema-backed
`cmux.json` surface. The legacy fallback settings file remains readable for
backwards compatibility while its final removal is tracked separately.

<!-- BEGIN GENERATED CONFIGURATION REFERENCE. Do not edit. -->

## Generated schema key reference

Source: [`web/data/cmux.schema.json`](../web/data/cmux.schema.json)

This section is generated by `scripts/generate-config-docs.py`. Every explicit schema property is listed; `.*` and `[]` rows describe dynamic map keys and array members.

| Key | Type | Default | Constraints | Description |
| --- | --- | --- | --- | --- |
| `$schema` | string | `"https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"` | format: `"uri"` | Optional schema URL for editor completion and validation. |
| `schemaVersion` | integer | `1` | min: `1` | Schema version for forward-compatible migrations. Newer versions are parsed on a best-effort basis. |
| `paneBorderColor` | string \| null | `null` | — | Override the cmux pane divider color in split workspaces. This affects cmux pane boundaries, not Ghostty internal splits. |
| `activePaneBorderColor` | string \| null | `null` | — | Optional border color drawn around the focused cmux pane in split workspaces. |
| `actions` | object | — | — | Action registry used by the surface tab bar, Command Palette, shortcuts, and plus-button menu. Each entry supports type "builtin", "command", "agent" (any CLI agent name, e.g. claude, codex, opencode, or a custom binary, with optional args), "workspaceCommand", or "workspace" (inline workspace with name/cwd/color/env/setup/layout, plus optional restart). Inline workspace entries are auto-offered in the new-workspace plus-button menu; set newWorkspaceMenu true/false on any action to override. "Save Workspace as Layout" in the plus-button menu writes entries here. |
| `actions.*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `ui` | object | — | — | UI action wiring, including surface tab bar buttons and plus-button behavior. The plus-button context menu shows ui.newWorkspace.contextMenu (or the default items) followed by actions that opt in via newWorkspaceMenu. |
| `ui.newWorkspace` | object | — | — | New Workspace button behavior and context-menu wiring. |
| `ui.newWorkspace.action` | string | — | — | ID of the action run by plain New Workspace. This is the default workspace layout; omit or remove it for None (Blank Terminal). Project-local ui.newWorkspace.action wins over the global value. |
| `ui.newWorkspace.*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `ui.*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `commands` | array<object> | — | — | Custom shell commands and workspace layout definitions. Workspace definitions support name, cwd, color, env, layout, and setup (a bootstrap command sent to the first terminal before its own command). |
| `commands[]` | object | — | — | One array member accepted by this setting. |
| `commands[].*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `agentChat` | object | — | — | Agent Chat GUI server settings. The built-in New agent chat action opens this URL in a browser workspace, probing /healthz first and optionally starting the server with startCommand. |
| `agentChat.url` | string | `"http://127.0.0.1:7739"` | min length: `1`; pattern: `"^https?://"`; format: `"uri"` | Base URL for the machine-local Agent Chat GUI server. cmux probes <url>/healthz before opening the workspace. |
| `agentChat.startCommand` | string | — | min length: `1` | Optional shell command to start the Agent Chat server when <url>/healthz is unreachable. cmux runs it detached with the user's SHELL, polls healthz for a short bounded window, then opens the workspace either way. |
| `agentChat.keys` | object | — | — | Keyboard behavior overrides for the Agent Chat web UI. |
| `agentChat.keys.ctrlJ` | string | `"newline"` | enum: `"newline"`, `"menu"` | Behavior for Ctrl+J in Agent Chat text fields. Use newline to insert a line break, or menu to move to the next popup item while a menu is open. |
| `agentChat.fonts` | object | — | — | Font overrides for the Agent Chat web UI. Omitted values fall back to Ghostty and built-in defaults. |
| `agentChat.fonts.sansFamily` | string | — | min length: `1` | CSS font family used for Agent Chat body and UI text. |
| `agentChat.fonts.bodyFamily` | string | — | min length: `1` | Alias for sansFamily. |
| `agentChat.fonts.family` | string | — | min length: `1` | Alias for sansFamily. |
| `agentChat.fonts.baseSize` | number | — | exclusive min: `0` | Base Agent Chat font size in CSS pixels. |
| `agentChat.fonts.bodySize` | number | — | exclusive min: `0` | Alias for baseSize. |
| `agentChat.fonts.monoFamily` | string | — | min length: `1` | CSS font family used for Agent Chat code and monospace text. |
| `agentChat.fonts.codeFamily` | string | — | min length: `1` | Alias for monoFamily. |
| `agentChat.fonts.codeSize` | number | — | exclusive min: `0` | Agent Chat code font size in CSS pixels. |
| `agentChat.fonts.monoSize` | number | — | exclusive min: `0` | Alias for codeSize. |
| `agentChat.fonts.codeLineHeight` | number | — | exclusive min: `0` | Line-height multiplier used for Agent Chat code blocks. |
| `vault` | object | — | — | Vault session restore agent registrations. cmux includes Pi by default; use this section to add or override JSONL-backed coding agents without an app update. |
| `vault.agents` | array<object> | `[]` | — | Custom coding agents that Vault can detect, list, and resume. |
| `vault.agents[]` | object | — | — | One array member accepted by this setting. |
| `vault.agents[].id` | string | — | pattern: `"^[A-Za-z0-9._-]+$"` | Stable lowercase-ish identifier used in Vault persistence, for example pi. |
| `vault.agents[].name` | string | — | — | Display name shown in Vault. |
| `vault.agents[].iconAssetName` | string | — | — | Optional asset catalog image name shown for this agent in Vault. |
| `vault.agents[].detect` | object | — | — | Rules for detecting a running agent process inside a cmux terminal. |
| `vault.agents[].detect.processName` | string | — | — | Executable basename to match, for example pi. |
| `vault.agents[].detect.argvContains` | string \| array<string> | — | — | Substring or substrings that must appear in the process argv. |
| `vault.agents[].detect.argvContains[]` | string | — | — | One array member accepted by this setting. |
| `vault.agents[].sessionIdSource` | string \| object | — | — | Where cmux reads the native session id for an active process. |
| `vault.agents[].sessionIdSource.type` | string | — | enum: `"argvOption"`, `"piSessionFile"` | Strategy used to extract the session identifier: from an argv option or a Pi session file. |
| `vault.agents[].sessionIdSource.argvOption` | string | — | — | Option whose following value is the session id, for example --session. |
| `vault.agents[].resumeCommand` | string | — | — | Shell-like argv template used to resume a session. Supported placeholders: {{sessionId}}, {{sessionPath}}, {{executable}}, {{cwd}}, {{sessionDir}}. Must include {{sessionId}} or {{sessionPath}}. |
| `vault.agents[].forkCommand` | string | — | — | Optional shell-like argv template used to fork (branch) a session into a new copy, for example "{{executable}} --session {{sessionId}} --fork". Same placeholders as resumeCommand. Omit when the agent has no fork capability; Fork Conversation stays hidden for it. |
| `vault.agents[].cwd` | string | `"preserve"` | enum: `"preserve"`, `"ignore"` | Whether Vault should cd to the saved working directory before running resumeCommand. |
| `vault.agents[].sessionDirectory` | string | — | — | Optional root directory for JSONL session discovery, such as ~/.pi/agent/sessions. |
| `vault.agents[].*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `newWorkspaceCommand` | string | — | — | Legacy name of a workspace command to run when creating a new workspace. Prefer ui.newWorkspace.action for new configs. |
| `workspaceGroups` | object | — | — | Per-cwd customization for sidebar workspace groups. The anchor workspace's cwd is matched against the keys in `byCwd`; longest-match wins. Keys containing `*` or `?` are matched as fnmatch globs (with `~` expanded); other keys are path prefixes. |
| `workspaceGroups.newWorkspacePlacement` | string | `"afterCurrent"` | enum: `"afterCurrent"`, `"top"`, `"end"` | Global default for where Cmd-N inside a group, the group header + button, and configured group actions place the new workspace: `afterCurrent` (after the active in-group workspace, falling back to top), `top` (second slot, just after the anchor), or `end` (after the last member). |
| `workspaceGroups.byCwd` | object | — | — | Map of cwd patterns to group customization. Empty when omitted. |
| `workspaceGroups.byCwd.*` | map<string, any> | — | dynamic key | One dynamic entry accepted under this setting. |
| `workspaceGroups.byCwd.*.color` | string | — | — | Hex color (e.g. "#7A4FD8") applied as the group header tint when the group itself has no explicit customColor. |
| `workspaceGroups.byCwd.*.icon` | string | — | — | SF Symbol name (e.g. "folder.fill", "ladybug.fill") for the group header. Falls back to "folder.fill" when omitted. |
| `workspaceGroups.byCwd.*.contextMenu` | array<string \| object> | — | — | Items appearing in the right-click menu on the group's + button. Same schema as the global ui.newWorkspace.contextMenu entries. |
| `workspaceGroups.byCwd.*.contextMenu[]` | string \| object | — | — | One array member accepted by this setting. |
| `workspaceGroups.byCwd.*.contextMenu[].*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `workspaceGroups.byCwd.*.newWorkspacePlacement` | string | — | enum: `"afterCurrent"`, `"top"`, `"end"` | Per-cwd override for where Cmd-N inside the group, the group header + button, and configured group actions place the new workspace: `afterCurrent` (after the active in-group workspace, falling back to top), `top` (second slot, just after the anchor), or `end` (after the last member). Falls back to the global default when omitted. |
| `surfaceTabBarButtons` | array<string \| object> | — | — | Legacy root-level surface tab bar buttons. Prefer ui.surfaceTabBar.buttons for new configs. |
| `surfaceTabBarButtons[]` | string \| object | — | — | One array member accepted by this setting. |
| `surfaceTabBarButtons[].*` | any | — | dynamic key | Dynamic configuration entry. Any JSON value is accepted. |
| `app` | object | — | — | General app preferences from Settings > App. |
| `app.language` | string | `"system"` | enum: `"system"`, `"en"`, `"ar"`, `"bs"`, `"zh-Hans"`, `"zh-Hant"`, `"da"`, `"de"`, `"es"`, `"fr"`, `"it"`, `"ja"`, `"ko"`, `"nb"`, `"pl"`, `"pt-BR"`, `"ru"`, `"th"`, `"tr"` | Preferred app language. |
| `app.appearance` | string | `"system"` | enum: `"system"`, `"light"`, `"dark"` | App appearance mode. |
| `app.appIcon` | string | `"automatic"` | enum: `"automatic"`, `"light"`, `"dark"` | Dock and app switcher icon style. |
| `app.windowTitleTemplate` | string | `""` | — | Optional NSWindow title template. Blank preserves cmux's existing default title behavior, including the current-directory fallback. Supported placeholders: {windowId}, {windowToken}, {activeWorkspace}, {activeDirectory}, {defaultTitle}, {appName}. |
| `app.menuBarOnly` | boolean | `false` | — | Hide the Dock icon and app switcher entry while keeping cmux available from the menu bar. |
| `app.newWorkspacePlacement` | string | `"afterCurrent"` | enum: `"top"`, `"afterCurrent"`, `"end"` | Where new workspaces are inserted in the sidebar. |
| `app.forkConversationDefaultDestination` | string | `"right"` | enum: `"right"`, `"left"`, `"top"`, `"bottom"`, `"newTab"`, `"newWorkspace"` | Default destination for the tab context menu's primary Fork Conversation action. The submenu still exposes every destination. |
| `app.workspaceInheritWorkingDirectory` | boolean | `true` | — | Legacy compatibility fallback used only when terminal.newSurfaceWorkingDirectory.policy is absent. Prefer the three-way terminal policy for new configurations. |
| `app.minimalMode` | boolean | `false` | — | Hide the workspace title bar and move controls into the sidebar. |
| `app.keepWorkspaceOpenWhenClosingLastSurface` | boolean | `false` | — | When true, closing the last surface keeps the workspace open. |
| `app.focusPaneOnFirstClick` | boolean | `true` | — | When cmux is inactive, the first click can activate and focus the clicked pane. |
| `app.focusHistoryIncludesPanesAndTabs` | boolean | `false` | — | When true, Back and Forward include focus changes between panes and tabs. When false, they navigate between workspaces only. |
| `app.preferredEditor` | string | `""` | — | Custom editor command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty to use the default. |
| `app.devWindowDisplay` | string | `""` | — | DEBUG builds only: preferred display localized name for newly-created windows. Leave empty to use the system default. |
| `app.openSupportedFilesInCmux` | boolean | `true` | — | When enabled, Cmd-clicking readable local files opens supported previews in cmux, including text, code, PDFs, images, audio, video, and Quick Look files. Preview headers include an Open With menu based on the user's default and compatible macOS apps for that file. |
| `app.openMarkdownInCmuxViewer` | boolean | `true` | — | When enabled, Cmd-clicking .md/.markdown/.mkd/.mdx files opens the rendered cmux markdown viewer panel (with live reload) instead of the generic file preview. |
| `app.globalFontMagnification` | integer | `100` | min: `50`; max: `200`; step: `10` | Scales cmux-owned terminals, tab titles, sidebars, settings, overlays, and app chrome by this percentage. Rendered browser page content is excluded. |
| `app.reorderOnNotification` | boolean | `true` | — | Move workspaces with new notifications toward the top. |
| `app.iMessageMode` | boolean | `false` | — | Move a workspace to the top and show the submitted message when sending an agent prompt. |
| `app.sendAnonymousTelemetry` | boolean | `true` | — | Allow anonymous telemetry. |
| `app.confirmQuit` | string | `"always"` | enum: `"always"`, `"dirty-only"`, `"never"` | Control when cmux asks for confirmation before quitting. DEV builds always quit immediately regardless of this setting. Legacy app.warnBeforeQuit is still accepted as a boolean fallback. |
| `app.warnBeforeQuit` | boolean | `true` | — | Legacy boolean fallback for quit confirmation. Use app.confirmQuit for new configs. |
| `app.warnBeforeClosingTab` | boolean | `true` | — | Show a confirmation before closing a tab. |
| `app.warnBeforeClosingTabXButton` | boolean | `false` | — | Show a confirmation before closing a tab with the tab close button. |
| `app.hideTabCloseButton` | boolean | `false` | — | Hide tab close buttons in the pane tab bar. |
| `app.renameSelectsExistingName` | boolean | `true` | — | Select the current name when opening rename flows. |
| `app.commandPaletteSearchesAllSurfaces` | boolean | `false` | — | Search every surface in the command palette switcher instead of only the active workspace. |
| `customSidebars` | object | — | — | Rendering policy for user- and agent-authored custom sidebars. |
| `customSidebars.renderer` | string | `"inProcess"` | enum: `"inProcess"`, `"remote"` | Choose the in-process SwiftUI renderer for native hover, focus, and keyboard input, or the isolated remote renderer for crash containment. |
| `terminal` | object | — | — | Terminal presentation settings from Settings > Terminal. |
| `terminal.showScrollBar` | boolean | `true` | — | Show the right-edge terminal scroll bar when scrollback is available. cmux automatically suppresses it for alternate-screen style TUI surfaces. |
| `terminal.scrollSpeed` | number | `1.0` | min: `0.25`; max: `3.0` | Multiplier applied to terminal scroll wheel and trackpad deltas. Higher values scroll faster; lower values scroll slower. |
| `terminal.sessionContentMaxWidth` | boolean \| number | `false` | — | Optional maximum width, in points, for terminal and built-in agent chat content. Set false to use the full pane width. |
| `terminal.sessionContentAlignment` | string | `"center"` | enum: `"left"`, `"center"`, `"right"` | Horizontal placement for terminal and built-in agent chat content when sessionContentMaxWidth is enabled. |
| `terminal.copyOnSelect` | boolean | `false` | — | When true, copy selected terminal text to the system clipboard when the selection is committed. When false, cmux does not emit a Ghostty copy-on-select override; Ghostty config and defaults control selection-clipboard behavior. |
| `terminal.autoResumeAgentSessions` | boolean | `true` | — | Automatically run agent resume commands for restored terminal sessions when cmux reopens after quit. Set false to restore panes while keeping Claude Code, Codex, OpenCode, and other saved agent sessions idle until you resume them manually. |
| `terminal.newSurfaceWorkingDirectory` | object | — | — | Working-directory defaults for ordinary new local panes, tabs, splits, and workspaces. Explicit working directories, remote commands, and restored surfaces always take precedence. |
| `terminal.newSurfaceWorkingDirectory.policy` | string | `"inheritActivePane"` | enum: `"inheritActivePane"`, `"workspaceRoot"`, `"fixedPath"` | Choose whether new local surfaces inherit the active pane directory, use the directory captured when the workspace was created, or use the configured fixed path. |
| `terminal.newSurfaceWorkingDirectory.path` | string | `""` | — | Path used by fixedPath. Use an absolute path or one beginning with a tilde. If the path is missing or is not a directory, cmux safely falls back to the workspace root. |
| `terminal.shellStartup` | object | — | — | Default shell startup behavior for ordinary new local surfaces. Explicit commands and inputs, remote sessions, restored surfaces, and manual tmux mirrors are not changed. |
| `terminal.shellStartup.mode` | string | `"login"` | enum: `"login"`, `"nonLogin"` | Start the user's shell as an interactive login shell or an interactive non-login shell. |
| `terminal.shellStartup.command` | string | `""` | — | Optional command sent as startup input after an ordinary new local shell starts. The command is not applied when a surface already has explicit startup work. |
| `terminal.showTextBoxOnNewTerminals` | boolean | `false` | — | Show the beta TextBox input by default for newly created workspaces, terminal tabs, and terminal splits. |
| `terminal.focusTextBoxOnNewTerminals` | boolean | `false` | — | Focus the beta TextBox input by default for newly created workspaces, terminal tabs, and terminal splits. Focusing also shows the TextBox. |
| `terminal.agentHibernation` | object | — | — | Routine Agent Hibernation settings. cmux kills idle background agent processes to free RAM and CPU, then resumes them with their saved session when their tab is visited. Routine hibernation requires a restorable coding agent whose lifecycle reports idle, an off-screen terminal, a live-terminal count above the configured limit, and unchanged output through the idle and confirmation windows. Independently, during critical memory pressure cmux may hibernate a bounded batch of safe idle background agents even when enabled is false; visible, running, needs-input, recently changed, and unprotectable agents remain excluded. The placeholder Resume button is a manual fallback. |
| `terminal.agentHibernation.enabled` | boolean | `false` | — | Enable routine Agent Hibernation based on the live-terminal limit. Critical-pressure safety hibernation remains active when false. |
| `terminal.agentHibernation.idleSeconds` | integer | `5` | min: `5`; max: `604800` | Minimum seconds with no terminal output or input before an idle restorable agent terminal can hibernate. A short confirmation settle window (~60s) still applies on top of this before the agent is killed. |
| `terminal.agentHibernation.maxLiveTerminals` | integer | `12` | min: `1`; max: `256` | Maximum live restorable agent terminals to keep before cmux hibernates eligible background terminals, oldest first. |
| `terminal.rendererRealization` | object | — | — | Reclaim off-screen terminal GPU renderer memory. cmux releases the Metal renderer (IOSurface) of a terminal that has stayed off-screen and idle while keeping its process and terminal state alive, then rebuilds the renderer instantly when the tab is visited again. Non-destructive and on by default. |
| `terminal.rendererRealization.enabled` | boolean | `true` | — | Reclaim off-screen terminal renderer memory. |
| `terminal.rendererRealization.idleSeconds` | integer | `5` | min: `5`; max: `604800` | Minimum seconds a terminal must stay off-screen before its GPU renderer memory is reclaimed. |
| `terminal.rendererRealization.maxWarmRenderers` | integer | `1` | min: `1`; max: `256` | Most recently visible terminals to keep renderer-ready so switching stays instant. Extra off-screen renderers are reclaimed oldest first. |
| `terminal.textBoxMaxLines` | integer | `10` | min: `1`; max: `20` | Maximum number of lines the rich terminal TextBox input can grow to before it scrolls. |
| `terminal.textBoxDefaultSubmitAction` | string | `"text-entry"` | — | Default TextBox submit action ID for new terminal sessions. Use text-entry for plain input or one of the configured action IDs. |
| `terminal.textBoxSubmitActions` | array<object> | `[]` | — | Configurable TextBox submit actions shown on the submit button, Shift-Tab cycle, and right-click menu. |
| `terminal.textBoxSubmitActions[]` | object | — | — | One array member accepted by this setting. |
| `terminal.textBoxSubmitActions[].id` | string | — | pattern: `"^[A-Za-z0-9._-]+$"` | Stable action ID referenced by terminal.textBoxDefaultSubmitAction. |
| `terminal.textBoxSubmitActions[].title` | string | — | — | Menu label for this submit action. |
| `terminal.textBoxSubmitActions[].kind` | string | — | enum: `"textEntry"`, `"commandTemplate"` | Whether this action submits plain Text Entry or expands a shell command template. |
| `terminal.textBoxSubmitActions[].commandTemplate` | string | — | — | Shell command template for commandTemplate actions. Include {{prompt}} to shell-quote the prompt into the command. |
| `terminal.textBoxSubmitActions[].preservePromptAfterLaunch` | boolean | — | — | When true, launch commandTemplate without the prompt and keep the prompt in the TextBox for the active agent. |
| `terminal.textBoxSubmitActions[].systemImage` | string | — | — | Fallback SF Symbol name shown on the submit button. |
| `terminal.textBoxSubmitActions[].assetName` | string | — | — | Optional app asset catalog image name shown on the submit button. |
| `terminal.textBoxSubmitActions[].imagePath` | string | — | — | Optional PNG or image file path shown on the submit button. Tilde is expanded. |
| `terminal.textBoxSubmitActions[].backgroundColorHex` | string | — | pattern: `"^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"` | Action color metadata as RGB or RGBA hex. The submit button fill stays white and only changes opacity between enabled and disabled states. |
| `terminal.resumeCommands` | array<object> | `[]` | — | Signed command-prefix approvals for restoring non-agent terminal surfaces. cmux writes this list when you approve a surface resume command. |
| `terminal.resumeCommands[]` | object | — | — | One array member accepted by this setting. |
| `terminal.resumeCommands[].version` | integer | — | const: `1` | Record format version. Version 1 is currently supported. |
| `terminal.resumeCommands[].id` | string | — | — | Stable identifier for this signed resume approval. |
| `terminal.resumeCommands[].name` | string | — | — | Optional user-facing label for this resume approval. |
| `terminal.resumeCommands[].commandPrefix` | array<string> | — | min items: `1` | Shell argv prefix that must match the saved resume command. |
| `terminal.resumeCommands[].commandPrefix[]` | string | — | min length: `1` | One array member accepted by this setting. |
| `terminal.resumeCommands[].cwd` | string | — | — | Optional working directory that must match the saved resume command. |
| `terminal.resumeCommands[].environment` | object | — | — | Optional non-sensitive environment values that must match the saved resume command. |
| `terminal.resumeCommands[].environment.*` | string | — | dynamic key | One dynamic entry accepted under this setting. |
| `terminal.resumeCommands[].environmentKeys` | array<string> | — | — | Names of environment variables included in the signed resume-command match. |
| `terminal.resumeCommands[].environmentKeys[]` | string | — | — | One array member accepted by this setting. |
| `terminal.resumeCommands[].source` | string | — | — | Optional provenance label describing where this approval was created. |
| `terminal.resumeCommands[].policy` | string | — | enum: `"manual"`, `"prompt"`, `"auto"` | How cmux may use the approval: manually, after prompting, or automatically. |
| `terminal.resumeCommands[].createdAt` | number | — | — | Creation time as seconds since the Unix epoch. |
| `terminal.resumeCommands[].updatedAt` | number | — | — | Last modification time as seconds since the Unix epoch. |
| `terminal.resumeCommands[].lastUsedAt` | number | — | — | Most recent use time as seconds since the Unix epoch, when available. |
| `terminal.resumeCommands[].signature` | string | — | — | HMAC signature for the record. Changing signed fields invalidates the approval. |
| `terminal.uploadCommands` | array<object> | `[]` | — | Host-scoped rules that replace the built-in scp for terminal file drops and pastes over SSH. When the ssh destination matches a rule, cmux runs that rule's command once per file instead of scp, and inserts the command's stdout at the cursor (verbatim, with control characters stripped); if the command prints nothing, cmux inserts the shell-escaped remote path it chose instead. Per-file outputs are space-joined. First matching enabled rule wins; no match runs the built-in scp unchanged. A non-zero exit, timeout, or cancel inserts nothing. |
| `terminal.uploadCommands[]` | object | — | — | One array member accepted by this setting. |
| `terminal.uploadCommands[].hostPattern` | string \| null | — | min length: `1` | fnmatch glob matched against the ssh destination (user@ and IPv6 brackets stripped, lowercased), like a single ssh_config Host pattern. Omit the key or set it to null for a catch-all (a blank string is rejected). |
| `terminal.uploadCommands[].command` | string | — | min length: `1`; pattern: `"\\S"` | Shell command run via /bin/sh -c, once per file. It receives the file and endpoint on its environment (CMUX_UPLOAD_LOCAL_PATH, CMUX_UPLOAD_REMOTE_PATH, CMUX_UPLOAD_DESTINATION, CMUX_UPLOAD_PORT, CMUX_UPLOAD_IDENTITY_FILE, CMUX_UPLOAD_SSH_OPTIONS). Its stdout is what cmux inserts at the cursor. |
| `terminal.uploadCommands[].enabled` | boolean | `true` | — | Whether this rule is active. Defaults to true. |
| `notifications` | object | — | — | Notification behavior from Settings > Notifications. |
| `notifications.dockBadge` | boolean | `true` | — | Show the unread count in the Dock tile. |
| `notifications.showInMenuBar` | boolean | `true` | — | Show the menu bar extra. |
| `notifications.unreadPaneRing` | boolean | `true` | — | Highlight panes with unread notifications. |
| `notifications.paneFlash` | boolean | `true` | — | Flash the focused pane when requested. |
| `notifications.paneFlashColor` | string \| null | `null` | — | Override the pane flash and unread ring color. Null keeps the built-in blue. |
| `notifications.suppressOnlyFocusedSurface` | boolean | `false` | — | When enabled, a notification banner is auto-withdrawn only when its surface is the exact focused surface. A banner delivered for a non-focused surface in the currently visible workspace stays up until you focus that surface (or click/dismiss it), instead of being retracted when the workspace becomes visible. Off preserves the legacy workspace-visibility withdraw. |
| `notifications.agentPermissionPrompt` | boolean | `true` | — | Notify when an agent (e.g. Claude Code) is blocked waiting for your permission to run a tool. On by default, since this is the alert you must act on to unblock the agent. |
| `notifications.agentTurnComplete` | string | `"whenIdle"` | enum: `"whenIdle"`, `"always"`, `"never"` | When to notify that an agent finished a turn. whenIdle (default) suppresses the notification while the agent still has a running background task or a pending scheduled wakeup, so you are pinged once work truly drains. always notifies on every turn end; never disables it. |
| `notifications.agentIdleReminder` | boolean | `true` | — | Notify when an agent has been idle waiting for your input (about 60s after a turn ends). Suppressed while background work from the last turn is still pending, so a running build or watcher does not trigger a false waiting alert. |
| `notifications.sound` | string | `"default"` | enum: `"default"`, `"Basso"`, `"Blow"`, `"Bottle"`, `"Frog"`, `"Funk"`, `"Glass"`, `"Hero"`, `"Morse"`, `"Ping"`, `"Pop"`, `"Purr"`, `"Sosumi"`, `"Submarine"`, `"Tink"`, `"custom_file"`, `"none"` | Notification sound preset. |
| `notifications.customSoundFilePath` | string | `""` | — | Local path to the custom notification sound file. |
| `notifications.command` | string | `""` | — | Optional shell command to run alongside notification delivery. |
| `notifications.hooksMode` | string | `"append"` | enum: `"append"`, `"replace"` | Controls whether project-local notification hooks append to inherited hooks or replace them. |
| `notifications.hooks` | array<object> | `[]` | — | Composable shell hooks that receive notification policy JSON on stdin and return updated policy JSON on stdout. |
| `notifications.hooks[]` | object | — | — | One array member accepted by this setting. |
| `notifications.hooks[].id` | string | — | min length: `1` | Stable hook identifier used in logs and failure alerts. |
| `notifications.hooks[].command` | string | — | min length: `1`; pattern: `".*\\S.*"` | Shell command run with notification policy JSON on stdin. |
| `notifications.hooks[].timeoutSeconds` | number | `20` | exclusive min: `0` | Maximum time cmux waits for this hook before falling back to default notification behavior. |
| `notifications.hooks[].enabled` | boolean | `true` | — | Disable this hook without removing it. |
| `sidebar` | object | — | — | Sidebar content and metadata visibility from Settings > Sidebar. |
| `sidebar.hideAllDetails` | boolean | `false` | — | Hide all per-workspace detail rows. |
| `sidebar.wrapWorkspaceTitles` | boolean | `false` | — | Allow workspace titles in the sidebar to wrap to multiple lines instead of truncating after one line. |
| `sidebar.showWorkspaceDescription` | boolean | `true` | — | Show custom workspace descriptions in the sidebar. |
| `sidebar.beta` | object | — | — | Experimental sidebar features. |
| `sidebar.beta.workspaceTodos` | object | — | — | Workspace todos checklist presentation. |
| `sidebar.beta.workspaceTodos.controls` | object | — | — | Enable controls for adding checklist items and changing workspace todo status. |
| `sidebar.beta.workspaceTodos.controls.enabled` | boolean | `false` | — | Show controls for adding checklist items and changing workspace todo status. |
| `sidebar.beta.workspaceTodos.checklistStyle` | string | `"popover"` | enum: `"popover"`, `"inline"` | How a row's checklist opens from its summary line: an anchored popover or inline expansion. |
| `sidebar.branchLayout` | string | `"vertical"` | enum: `"vertical"`, `"inline"` | Show git branch details stacked vertically or inline. |
| `sidebar.stackBranchDirectory` | boolean | `false` | — | When enabled, render the git branch and working directory on separate rows in compact sidebar layouts. |
| `sidebar.pathLastSegmentOnly` | boolean | `false` | — | When enabled, show as much of the trailing working-directory path as fits, abbreviating its leading components. |
| `sidebar.showNotificationMessage` | boolean | `true` | — | Show the latest notification text in the sidebar. |
| `sidebar.notificationMessageLineLimit` | integer | `12` | min: `1`; max: `50` | Maximum lines shown for the latest notification below each workspace title. |
| `sidebar.showBranchDirectory` | boolean | `true` | — | Show the workspace working directory. |
| `sidebar.showPullRequests` | boolean | `true` | — | Show pull request metadata in the sidebar. |
| `sidebar.watchGitStatus` | boolean | `true` | — | Watch repository files for sidebar branch and pull request metadata without polling git. |
| `sidebar.makePullRequestsClickable` | boolean | `true` | — | Allow sidebar pull request metadata to open links when clicked. |
| `sidebar.openPullRequestLinksInCmuxBrowser` | boolean | `true` | — | Open sidebar pull request links in the embedded cmux browser. |
| `sidebar.openPortLinksInCmuxBrowser` | boolean | `true` | — | Open sidebar port links in the embedded cmux browser. |
| `sidebar.showSSH` | boolean | `true` | — | Show SSH connection details. |
| `sidebar.showPorts` | boolean | `true` | — | Show listening ports. |
| `sidebar.showLog` | boolean | `true` | — | Show recent log snippets. |
| `sidebar.showProgress` | boolean | `true` | — | Show progress indicators. |
| `sidebar.showAgentActivity` | boolean | `true` | — | Show the loading spinner on workspaces with running coding agents or active loaders. |
| `sidebar.loadingSpinnerPosition` | string | `"leading"` | enum: `"leading"`, `"trailing"` | Which side of the workspace row the loading spinner appears on: leading (left, sharing the unread-badge slot) or trailing (right). |
| `sidebar.notificationBadgePosition` | string | `"leading"` | enum: `"leading"`, `"trailing"` | Which side of the workspace row the unread notification badge appears on: leading (left) or trailing (right). |
| `sidebar.showCustomMetadata` | boolean | `true` | — | Show custom metadata pills. |
| `sidebar.rightMaxWidth` | number | — | exclusive min: `0` | Maximum width in points for the right sidebar. When omitted, the built-in dynamic cap applies. |
| `workspaceColors` | object | — | — | Workspace tab and badge colors from Settings > Workspace Colors. |
| `workspaceColors.indicatorStyle` | string | `"leftRail"` | enum: `"leftRail"`, `"solidFill"`, `"rail"`, `"border"`, `"wash"`, `"lift"`, `"typography"`, `"washRail"`, `"blueWashColorRail"` | Active workspace indicator style. Legacy aliases are accepted and normalized. |
| `workspaceColors.selectionColor` | string \| null | `null` | — | Override the selected workspace background color. |
| `workspaceColors.notificationBadgeColor` | string \| null | `null` | — | Override the unread notification badge color. |
| `workspaceColors.colors` | object | `{"Amber": "#7D6608", "Aqua": "#0E6B8C", "Blue": "#1565C0", "Brown": "#7B3F00", "Charcoal": "#3E4B5E", "Crimson": "#922B21", "Green": "#196F3D", "Indigo": "#283593", "Magenta": "#AD1457", "Navy": "#1A5276", "Olive": "#4A5C18", "Orange": "#A04000", "Purple": "#6A1B9A", "Red": "#C0392B", "Rose": "#880E4F", "Teal": "#006B6B"}` | — | Full named workspace color palette. Include built-in entries you want to keep, remove keys to remove colors, and add more named entries to extend the picker. |
| `workspaceColors.colors.*` | string | — | pattern: `"^#[0-9A-Fa-f]{6}$"`; dynamic key | Uppercase or lowercase 6-digit hex color. |
| `workspaceColors.paletteOverrides` | object | `{}` | — | Legacy workspace color overrides for built-in palette names. Prefer workspaceColors.colors for new configs. |
| `workspaceColors.paletteOverrides.*` | string | — | pattern: `"^#[0-9A-Fa-f]{6}$"`; dynamic key | Uppercase or lowercase 6-digit hex color. |
| `workspaceColors.customColors` | array<string> | `[]` | — | Legacy list of custom workspace colors. Prefer workspaceColors.colors for new configs. |
| `workspaceColors.customColors[]` | string | — | pattern: `"^#[0-9A-Fa-f]{6}$"` | Uppercase or lowercase 6-digit hex color. |
| `sidebarAppearance` | object | — | — | Sidebar tint settings from Settings > Sidebar Appearance. |
| `sidebarAppearance.matchTerminalBackground` | boolean | `false` | — | Use the terminal background instead of the sidebar tint. |
| `sidebarAppearance.tintColor` | string | `"#000000"` | pattern: `"^#[0-9A-Fa-f]{6}$"` | Base sidebar tint color used when light/dark overrides are not set. |
| `sidebarAppearance.lightModeTintColor` | string \| null | `null` | — | Sidebar tint override for light appearance. |
| `sidebarAppearance.darkModeTintColor` | string \| null | `null` | — | Sidebar tint override for dark appearance. |
| `sidebarAppearance.tintOpacity` | number | `0.03` | min: `0`; max: `1` | Sidebar tint opacity from 0 to 1. Note: this only controls the sidebar tint, not terminal/window transparency. For terminal background transparency or blur, set `background-opacity` and `background-blur` in `~/.config/ghostty/config` and run `cmux reload-config`. |
| `automation` | object | — | — | Socket control and automation settings from Settings > Automation. |
| `automation.socketControlMode` | string | `"cmuxOnly"` | enum: `"off"`, `"cmuxOnly"`, `"automation"`, `"password"`, `"allowAll"`, `"openAccess"`, `"fullOpenAccess"`, `"notifications"`, `"full"` | Socket control mode. Legacy aliases are accepted and normalized. |
| `automation.socketPassword` | string \| null | `""` | — | Password for password-mode socket access. Use null or an empty string to clear it. |
| `automation.claudeCodeIntegration` | boolean | `true` | — | Enable cmux integration hooks for Claude Code. |
| `automation.claudeBinaryPath` | string | `""` | — | Custom path to the claude binary. |
| `automation.workspaceAutoNaming` | boolean | `false` | — | Opt-in AI auto-naming of workspaces and tabs from agent conversation content. When enabled, cmux summarizes supported agent sessions into short titles using each agent's own binary; manual renames always win. |
| `automation.autoNamingAgent` | string | `"auto"` | — | Which agent generates auto-names for every session. "auto" (default) names each session with its own agent; any agent slug (claude, codex, grok, opencode, pi, omp, …) overrides naming for all sessions, even other agents' sessions. Undriveable or uninstalled agents fall back to the session's own agent, so naming never breaks. |
| `automation.ripgrepBinaryPath` | string | `""` | — | Custom path to the ripgrep (rg) binary used by project search. |
| `automation.suppressSubagentNotifications` | boolean | `true` | — | Suppress visible completion notifications and status mutations from nested Codex or Claude child agents while keeping their events in Feed telemetry. |
| `automation.ampIntegration` | boolean | `true` | — | Enable cmux integration hooks for Amp. When disabled, the bundled plugin stays inactive without needing to be removed. |
| `automation.cursorIntegration` | boolean | `true` | — | Enable cmux integration hooks for Cursor. |
| `automation.geminiIntegration` | boolean | `true` | — | Enable cmux integration hooks for Gemini. |
| `automation.kiroIntegration` | boolean | `true` | — | Enable cmux integration hooks for Kiro CLI. |
| `automation.kiroNotificationLevel` | string | `"standard"` | enum: `"minimal"`, `"standard"`, `"verbose"` | Controls how many Kiro tool events appear in Feed. |
| `automation.portBase` | integer | `9100` | min: `1` | Starting value for workspace CMUX_PORT assignments. |
| `automation.portRange` | integer | `10` | min: `1` | Number of ports reserved per workspace. |
| `browser` | object | — | — | Embedded browser settings from Settings > Browser. |
| `browser.defaultSearchEngine` | string | `"google"` | enum: `"google"`, `"duckduckgo"`, `"bing"`, `"kagi"`, `"startpage"`, `"brave"`, `"perplexity"`, `"exa"`, `"yahoo"`, `"ecosia"`, `"qwant"`, `"mojeek"`, `"wikipedia"`, `"github"`, `"baidu"`, `"yandex"`, `"custom"` | Default search engine for non-URL browser address bar queries. Use custom with customSearchEngineURLTemplate for arbitrary providers. |
| `browser.customSearchEngineName` | string | `""` | — | Display name used when defaultSearchEngine is custom. |
| `browser.customSearchEngineURLTemplate` | string | `"https://www.google.com/search?q={query}"` | — | Search URL used when defaultSearchEngine is custom. Include {query} or %s for the encoded query. If omitted, cmux appends q= to the URL. |
| `browser.showSearchSuggestions` | boolean | `true` | — | Show omnibar search suggestions. |
| `browser.theme` | string | `"system"` | enum: `"system"`, `"light"`, `"dark"` | Embedded browser theme. |
| `browser.defaultZoomLevel` | number | `1` | min: `0.25`; max: `5` | Default page zoom factor applied to newly opened browser pages (1 = 100%). Zoom In, Zoom Out, and Actual Size still adjust each page. |
| `browser.discardHiddenWebViews` | boolean | `true` | — | Allow hidden browser tabs to release page memory and restore when shown again. |
| `browser.hiddenWebViewDiscardDelaySeconds` | number | `300` | min: `0`; max: `3600` | Seconds a browser tab must stay hidden before cmux frees its page memory. |
| `browser.askWhereToSaveDownloads` | boolean | `false` | — | Show a save panel for browser downloads instead of saving directly to Downloads. |
| `browser.openTerminalLinksInCmuxBrowser` | boolean | `true` | — | Open clicked terminal links in the embedded browser. |
| `browser.interceptTerminalOpenCommandInCmuxBrowser` | boolean | `true` | — | Intercept terminal open http(s) commands and route them through the embedded browser. |
| `browser.hostsToOpenInEmbeddedBrowser` | array<string> | `[]` | — | Allowlist of hosts that should stay inside the embedded browser. |
| `browser.hostsToOpenInEmbeddedBrowser[]` | string | — | — | One array member accepted by this setting. |
| `browser.urlsToAlwaysOpenExternally` | array<string> | `[]` | — | Rules that always open matching URLs in the system browser. |
| `browser.urlsToAlwaysOpenExternally[]` | string | — | — | One array member accepted by this setting. |
| `browser.insecureHttpHostsAllowedInEmbeddedBrowser` | array<string> | `["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]` | — | HTTP hosts allowed in the embedded browser without a warning prompt. |
| `browser.insecureHttpHostsAllowedInEmbeddedBrowser[]` | string | — | — | One array member accepted by this setting. |
| `browser.showImportHintOnBlankTabs` | boolean | `true` | — | Show the browser import hint on blank tabs. |
| `browser.reactGrabVersion` | string | `"0.1.29"` | — | Pinned react-grab version for the browser toolbar helper. |
| `mobile` | object | — | — | Mac-side settings for cmux on iOS. |
| `mobile.artifactFolderAccess` | string | `"subtree"` | enum: `"subtree"`, `"oneLevel"` | Controls whether a referenced or terminal-visible directory authorizes its full canonical subtree or only immediate children. |
| `markdown` | object | — | — | Built-in markdown viewer settings. |
| `markdown.fontSize` | integer | `15` | min: `8`; max: `96` | Default body font size, in points, for newly opened markdown viewers. Zoom a viewer live with Cmd-+ / Cmd-- / Cmd-0. |
| `markdown.fontFamily` | string | `""` | — | Default body font family for newly opened markdown viewers. Leave empty for the system markdown font stack. |
| `markdown.maxWidth` | integer | `980` | min: `320`; max: `2400` | Default maximum reading column width, in CSS pixels, for newly opened markdown viewers. |
| `canvas` | object | — | — | Freeform canvas workspace layout settings. |
| `canvas.paneGap` | integer | `16` | min: `0`; max: `64` | Spacing between panes in the canvas layout, in points. Snapping, tidy, and new-pane placement all use this one gap. |
| `canvas.snappingEnabled` | boolean | `true` | — | Snap pane drags and resizes to neighbor edges and the pane gap. Hold Command to suspend snapping for one gesture. |
| `fileEditor` | object | — | — | Built-in plain-text file editor settings. |
| `fileEditor.wordWrap` | boolean | `false` | — | Wrap long lines at the editor's right edge instead of scrolling horizontally. |
| `fileExplorer` | object | — | — | Right-sidebar file explorer (file tree) settings. |
| `fileExplorer.doubleClickAction` | string | `"preview"` | enum: `"preview"`, `"defaultEditor"`, `"preferredEditor"` | What double-clicking (or pressing Return on a search result for) a file in the file explorer does. `preview` opens the built-in cmux file preview (the default and historical behavior). `defaultEditor` opens with the macOS default app for the file type. `preferredEditor` opens with the `app.preferredEditor` command, falling back to the default app when none is set. Only applies to files; directories always expand/collapse, and non-local (remote) file explorers always open the cmux preview. |
| `diffViewer` | object | — | — | Built-in diff viewer settings. |
| `diffViewer.defaultLayout` | string | `"unified"` | enum: `"unified"`, `"split"` | Default layout for newly opened diff viewers. The toolbar layout toggle persists the user's last choice; an explicit `cmux diff --layout` option overrides both. |
| `shortcuts` | object | — | — | Keyboard shortcut settings from Settings > Keyboard Shortcuts. |
| `shortcuts.showModifierHoldHints` | boolean | `true` | — | Show shortcut-hint chips while holding Cmd or Control. |
| `shortcuts.bindings` | object | `{}` | — | Shortcut overrides keyed by cmux action id. Use a string for a single shortcut, an array for a chord, null, an empty string, none, clear, unbound, or disabled to unbind. |
| `shortcuts.bindings.fileExplorerOpenSelection` | string \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. |
| `shortcuts.bindings.fileExplorerOpenSelectionFinderAlias` | string \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. |
| `shortcuts.bindings.diffViewerScrollDown` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollUp` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollHalfPageDown` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollHalfPageUp` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollDownEmacs` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollUpEmacs` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollToBottom` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerScrollToTop` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerOpenFileSearch` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerNextFile` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.diffViewerPreviousFile` | string \| array<string> \| null | — | — | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut. Bare first strokes are accepted for this action. Chorded shortcut. Bare first strokes are accepted for this action. Example: ["g", "g"]. |
| `shortcuts.bindings.*` | string \| array<string> \| null | — | key enum: `openSettings`, `reloadConfiguration`, `showHideAllWindows`, `globalSearch`, `newWindow`, `closeWindow`, `toggleFullScreen`, `quit`, `toggleSidebar`, `newTab`, `newBrowserWorkspace`, `saveLayoutTemplate`, `openFolder`, `reopenPreviousSession`, `goToWorkspace`, `commandPalette`, `commandPaletteNext`, `commandPalettePrevious`, `sendFeedback`, `showNotifications`, `jumpToUnread`, `toggleUnread`, `markOldestUnreadAndJumpNext`, `focusRightSidebar`, `switchRightSidebarToFiles`, `switchRightSidebarToFind`, `switchRightSidebarToSessions`, `switchRightSidebarToFeed`, `switchRightSidebarToDock`, `triggerFlash`, `nextSurface`, `prevSurface`, `moveSurfaceLeft`, `moveSurfaceRight`, `moveSurfaceToPreviousPane`, `moveSurfaceToNextPane`, `moveSurfaceToPaneLeft`, `moveSurfaceToPaneRight`, `moveSurfaceToPaneUp`, `moveSurfaceToPaneDown`, `selectSurfaceByNumber`, `nextSidebarTab`, `prevSidebarTab`, `nextSidebarTabInGroup`, `prevSidebarTabInGroup`, `moveWorkspaceUp`, `moveWorkspaceDown`, `focusHistoryBack`, `focusHistoryForward`, `selectWorkspaceByNumber`, `renameTab`, `renameWorkspace`, `editWorkspaceDescription`, `markWorkspaceDone`, `cycleWorkspaceStatus`, `toggleChecklistItemComplete`, `closeTab`, `closeOtherTabsInPane`, `closeWorkspace`, `newWorkspaceGroup`, `groupSelectedWorkspaces`, `toggleFocusedWorkspaceGroupCollapsed`, `reopenClosedWorkspace`, `reopenClosedBrowserPanel`, `newSurface`, `toggleTerminalCopyMode`, `focusTextBoxInput`, `cycleTextBoxSubmitAction`, `attachTextBoxFile`, `sendCtrlFToTerminal`, `clearScreenKeepScrollback`, `simulatorHome`, `simulatorRotateLeft`, `simulatorRotateRight`, `simulatorToggleAppearance`, `simulatorToggleSoftwareKeyboard`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `focusPreviousPane`, `focusNextPane`, `splitRight`, `splitDown`, `toggleSplitZoom`, `increaseWorkspaceTerminalFontSize`, `decreaseWorkspaceTerminalFontSize`, `resetWorkspaceTerminalFontSize`, `equalizeSplits`, `splitBrowserRight`, `splitBrowserDown`, `toggleCanvasLayout`, `canvasRevealFocusedPane`, `canvasOverview`, `canvasZoomIn`, `canvasZoomOut`, `canvasZoomReset`, `canvasTidy`, `canvasAlignLeft`, `canvasAlignRight`, `canvasAlignTop`, `canvasAlignBottom`, `canvasEqualizeWidths`, `canvasEqualizeHeights`, `canvasDistributeHorizontally`, `canvasDistributeVertically`, `toggleFileExplorer`, `fileExplorerOpenSelection`, `fileExplorerOpenSelectionFinderAlias`, `saveFilePreview`, `openBrowser`, `focusBrowserAddressBar`, `browserBack`, `browserForward`, `browserReload`, `browserHardReload`, `browserZoomIn`, `browserZoomOut`, `browserZoomReset`, `markdownZoomIn`, `markdownZoomOut`, `markdownZoomReset`, `find`, `findInDirectory`, `findNext`, `findPrevious`, `hideFind`, `useSelectionForFind`, `toggleBrowserDeveloperTools`, `showBrowserJavaScriptConsole`, `toggleBrowserFocusMode`, `toggleBrowserDesignMode`, `toggleReactGrab`, `openDiffViewer`, `diffViewerScrollDown`, `diffViewerScrollUp`, `diffViewerScrollHalfPageDown`, `diffViewerScrollHalfPageUp`, `diffViewerScrollDownEmacs`, `diffViewerScrollUpEmacs`, `diffViewerScrollToBottom`, `diffViewerScrollToTop`, `diffViewerOpenFileSearch`, `diffViewerNextFile`, `diffViewerPreviousFile`; dynamic key | Unbind this shortcut. Accepted values are an empty string, none, clear, unbound, or disabled. Single-stroke shortcut, for example cmd+n or cmd+space. Chorded shortcut. Example: ["ctrl+b", "c"]. |
| `shortcuts.when` | object | `{}` | — | Optional per-action context predicates (VS Code-style `when` clauses), keyed by cmux action id. Each value is a boolean expression over context keys combined with !, &&, \|\|, and parentheses. Boolean keys: sidebarFocus, browserFocus, markdownFocus, filePreviewTextEditorFocus, simulatorFocus, terminalFocus, commandPaletteVisible, terminalFindVisible, workspaceCanvasLayout. Typed keys support comparisons: the string sidebarMode (files, find, sessions, feed, or dock) and the integers paneCount and workspaceCount. Comparison operators are ==, !=, =~ (regex), <, <=, >, >=, and `in [a, b]`; an unknown or absent key reads as false. The boolean literals true and false are also accepted; `key == false` is the same as `!key`. The action's shortcut only fires (and only conflicts with other shortcuts) when the clause holds. Examples: { "selectWorkspaceByNumber": "!sidebarFocus" } selects workspaces with Ctrl+1–9 everywhere except when the right sidebar is focused; { "selectSurfaceByNumber": "sidebarMode == 'find' && paneCount > 1" } scopes a binding to the Find sidebar when the workspace has multiple panes. |
| `shortcuts.when.*` | string | — | key enum: `openSettings`, `reloadConfiguration`, `showHideAllWindows`, `globalSearch`, `newWindow`, `closeWindow`, `toggleFullScreen`, `quit`, `toggleSidebar`, `newTab`, `newBrowserWorkspace`, `saveLayoutTemplate`, `openFolder`, `reopenPreviousSession`, `goToWorkspace`, `commandPalette`, `commandPaletteNext`, `commandPalettePrevious`, `sendFeedback`, `showNotifications`, `jumpToUnread`, `toggleUnread`, `markOldestUnreadAndJumpNext`, `focusRightSidebar`, `switchRightSidebarToFiles`, `switchRightSidebarToFind`, `switchRightSidebarToSessions`, `switchRightSidebarToFeed`, `switchRightSidebarToDock`, `triggerFlash`, `nextSurface`, `prevSurface`, `moveSurfaceLeft`, `moveSurfaceRight`, `moveSurfaceToPreviousPane`, `moveSurfaceToNextPane`, `moveSurfaceToPaneLeft`, `moveSurfaceToPaneRight`, `moveSurfaceToPaneUp`, `moveSurfaceToPaneDown`, `selectSurfaceByNumber`, `nextSidebarTab`, `prevSidebarTab`, `nextSidebarTabInGroup`, `prevSidebarTabInGroup`, `moveWorkspaceUp`, `moveWorkspaceDown`, `focusHistoryBack`, `focusHistoryForward`, `selectWorkspaceByNumber`, `renameTab`, `renameWorkspace`, `editWorkspaceDescription`, `markWorkspaceDone`, `cycleWorkspaceStatus`, `toggleChecklistItemComplete`, `closeTab`, `closeOtherTabsInPane`, `closeWorkspace`, `newWorkspaceGroup`, `groupSelectedWorkspaces`, `toggleFocusedWorkspaceGroupCollapsed`, `reopenClosedWorkspace`, `reopenClosedBrowserPanel`, `newSurface`, `toggleTerminalCopyMode`, `focusTextBoxInput`, `cycleTextBoxSubmitAction`, `attachTextBoxFile`, `sendCtrlFToTerminal`, `clearScreenKeepScrollback`, `simulatorHome`, `simulatorRotateLeft`, `simulatorRotateRight`, `simulatorToggleAppearance`, `simulatorToggleSoftwareKeyboard`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `focusPreviousPane`, `focusNextPane`, `splitRight`, `splitDown`, `toggleSplitZoom`, `increaseWorkspaceTerminalFontSize`, `decreaseWorkspaceTerminalFontSize`, `resetWorkspaceTerminalFontSize`, `equalizeSplits`, `splitBrowserRight`, `splitBrowserDown`, `toggleCanvasLayout`, `canvasRevealFocusedPane`, `canvasOverview`, `canvasZoomIn`, `canvasZoomOut`, `canvasZoomReset`, `canvasTidy`, `canvasAlignLeft`, `canvasAlignRight`, `canvasAlignTop`, `canvasAlignBottom`, `canvasEqualizeWidths`, `canvasEqualizeHeights`, `canvasDistributeHorizontally`, `canvasDistributeVertically`, `toggleFileExplorer`, `fileExplorerOpenSelection`, `fileExplorerOpenSelectionFinderAlias`, `saveFilePreview`, `openBrowser`, `focusBrowserAddressBar`, `browserBack`, `browserForward`, `browserReload`, `browserHardReload`, `browserZoomIn`, `browserZoomOut`, `browserZoomReset`, `markdownZoomIn`, `markdownZoomOut`, `markdownZoomReset`, `find`, `findInDirectory`, `findNext`, `findPrevious`, `hideFind`, `useSelectionForFind`, `toggleBrowserDeveloperTools`, `showBrowserJavaScriptConsole`, `toggleBrowserFocusMode`, `toggleBrowserDesignMode`, `toggleReactGrab`, `openDiffViewer`, `diffViewerScrollDown`, `diffViewerScrollUp`, `diffViewerScrollHalfPageDown`, `diffViewerScrollHalfPageUp`, `diffViewerScrollDownEmacs`, `diffViewerScrollUpEmacs`, `diffViewerScrollToBottom`, `diffViewerScrollToTop`, `diffViewerOpenFileSearch`, `diffViewerNextFile`, `diffViewerPreviousFile`; dynamic key | Boolean expression that scopes the corresponding shortcut to a UI context. |

<!-- END GENERATED CONFIGURATION REFERENCE. -->
