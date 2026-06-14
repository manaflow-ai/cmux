# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

Project-scoped action wiring can also live in `.cmux/cmux.json` inside a project directory. For pane tab bar customization, the nearest project config overrides the global button list for workspaces under that directory, while actions and commands can still fall back to global definitions.

## `ui.surfaceTabBar.buttons`

Controls the buttons shown at the end of each pane tab bar. cmux appends the built-in More button unless `ui.surfaceTabBar.hideMoreButton` is `true`.

The default More menu is pane-scoped: Diff Viewer, Files pane, Find pane, Vault pane, and New Note.

```json
{
  "ui": {
    "surfaceTabBar": {
      "hideMoreButton": false,
      "buttons": [
        "cmux.newTerminal",
        "cmux.newBrowser",
        "cmux.splitRight",
        "cmux.splitDown",
        {
          "type": "menu",
          "id": "cmux.more",
          "title": "More",
          "icon": { "type": "symbol", "name": "ellipsis.vertical" },
          "items": [
            "cmux.diffViewer",
            "cmux.filesPane",
            "cmux.findPane",
            "cmux.vaultPane",
            "cmux.newNote"
          ]
        }
      ]
    }
  }
}
```

Useful built-ins:

- `cmux.newTerminal`
- `cmux.newBrowser`
- `cmux.splitRight`
- `cmux.splitDown`
- `cmux.more`
- `cmux.diffViewer`
- `cmux.filesPane`
- `cmux.findPane`
- `cmux.vaultPane`
- `cmux.newNote`

## `shortcuts.bindings`

Shortcut overrides are keyed by action id under `shortcuts.bindings`. `newNote` creates or focuses a note for the current surface.

```json
{
  "shortcuts": {
    "bindings": {
      "newNote": "ctrl+cmd+n"
    }
  }
}
```

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
