# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

Project-scoped action wiring can also live in `.cmux/cmux.json` inside a project directory. For pane tab bar customization, the nearest project config overrides the global button list for workspaces under that directory, while actions and commands can still fall back to global definitions.

## `ui.surfaceTabBar.buttons`

Controls the buttons shown at the end of each pane tab bar. cmux appends the built-in More button unless `ui.surfaceTabBar.hideMoreButton` is `true`.

The default More menu is pane-scoped: Vault pane, Files pane, Find pane, Diff Viewer, New Note, Reveal Current Directory in Finder, and Customize. Use the Customize item to open Settings and this documentation.

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
            "cmux.vaultPane",
            "cmux.filesPane",
            "cmux.findPane",
            "cmux.diffViewer",
            "cmux.revealCurrentDirectoryInFinder",
            "cmux.customizeSurfaceTabBar"
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
- `cmux.vaultPane`
- `cmux.filesPane`
- `cmux.findPane`
- `cmux.diffViewer`
- `cmux.revealCurrentDirectoryInFinder`
- `cmux.customizeSurfaceTabBar`

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
