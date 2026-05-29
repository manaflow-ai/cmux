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
- Settings panel for themes, accent colors, workspace names/colors, background image URL, density, tabs/status bar visibility, advanced toolbar visibility, and terminal text size.
- Notification drawer, session tools, active focus rings, workspace colors, and pane attention indicators.
- Session layout persistence under `%APPDATA%\cmux-windows\session.json`.

Not complete yet:

- Full Ghostty renderer parity.
- WebView2-native browser automation.
- Windows installer/updater.
- Complete macOS shortcut/config parity.
