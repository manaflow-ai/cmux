# cmux Windows

This is the first runnable Windows port milestone. It is intentionally additive and does not touch the macOS Xcode app.

## Run

```powershell
cd windows
npm install
npm start
```

## CLI

With the app running:

```powershell
npm run cli -- ping
npm run cli -- list-workspaces
npm run cli -- reset-session
npm run cli -- new-workspace "API"
npm run cli -- new-terminal
npm run cli -- restart-terminal
npm run cli -- browser-open https://example.com
npm run cli -- notify "Build finished"
npm run cli -- send "echo hello from cmux Windows"
```

The runtime listens on `\\.\pipe\cmux-windows` on Windows and falls back to a temp Unix socket on other platforms.

## Scope

Implemented in this milestone:

- Windows desktop shell with workspace sidebar, surface tabs, split panes, and command palette.
- Terminal panes backed by `node-pty` when available, with a pipe-based process fallback.
- Browser panes through Electron `webview`, with iframe fallback outside Electron.
- Named-pipe CLI/control protocol.
- Native Windows window controls, draggable split dividers, terminal font-size controls, restart, and close-to-empty workspace home state.
- Settings panel for expanded themes/accent palettes, workspace names/colors, built-in/custom backgrounds, import/export/reset, density, sidebar width, tabs/status bar visibility, toolbar shortcut visibility, performance mode, terminal text size, terminal padding, and terminal scrollback.
- Compact Tools menu for workspace/session actions so the default top bar stays simple.
- Chrome-style surface tabs with a new-tab button, drag reordering, workspace drop targets, right-click rename/duplicate/move/close actions, and per-tab colors.
- Notification drawer, session tools, active focus rings, workspace colors, and pane attention indicators.
- Session layout persistence under `%APPDATA%\cmux-windows\session.json`.

Not complete yet:

- Full Ghostty renderer parity.
- WebView2-native browser automation.
- Windows installer/updater.
- Complete macOS shortcut/config parity.
