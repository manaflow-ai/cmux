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
