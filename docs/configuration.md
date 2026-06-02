# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

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

## `directoryTools`

Adds Command Palette tools that open the focused terminal directory in a cmux browser split.

Built-in ids:

- `vscode-inline`: starts VS Code `code-tunnel serve-web` and opens the directory inline.
- `jupyter`: starts `jupyter lab` in the focused directory and opens the printed local URL.

Use the same id to override a built-in. Set `enabled` to `false` to hide one.

Example:

```json
{
  "directoryTools": [
    {
      "id": "notebook",
      "title": "Open Current Directory in Notebook",
      "subtitle": "Notebook",
      "keywords": ["notebook", "python"],
      "kind": "shellWebServer",
      "executablePathCandidates": ["/opt/homebrew/bin/jupyter"],
      "command": "TOOL=\"${CMUX_TOOL_EXECUTABLE:-$(command -v jupyter || true)}\"; if [ -z \"$TOOL\" ]; then echo \"Notebook is not installed\" >&2; exit 127; fi; exec \"$TOOL\" lab --no-browser --ip=127.0.0.1 --port=8888 --ServerApp.port_retries=50",
      "cwd": "{directory}",
      "urlRegex": "(http://(?:127\\.0\\.0\\.1|localhost):[^\\s]+)",
      "failureMessage": "Notebook is not installed or did not print a local URL.",
      "installCommand": "python3 -m pip install --user jupyterlab",
      "startupTimeoutSeconds": 20
    }
  ]
}
```

For `shellWebServer`, cmux sets `CMUX_DIRECTORY`, `CMUX_TOOL_ID`, and `CMUX_TOOL_EXECUTABLE`. If startup fails, cmux shows `failureMessage`, captured output, and an optional `installCommand` button. Install commands run in a visible terminal tab after the user clicks the button. Project-local tools are prompted through the same trust flow as project-local custom commands.
