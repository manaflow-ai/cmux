# cmux for Windows

This is the first runnable Windows port milestone. It is intentionally additive and does not touch the macOS Xcode app.

## Run

```powershell
cd windows
npm install
npm start
```

`npm start` builds the Vite/React settings renderer before launching Electron. Use
`npm run build:renderer` when you only need to refresh the renderer bundle.

## Build the Windows installer

```powershell
cd windows
npm install
npm run dist:win
```

The installer is written to `windows/release/cmux-0.1.0-setup.exe`.
The app, shortcut, executable, and installer are named `cmux`. This is an
unofficial community Windows build; official upstream cmux releases remain
macOS-focused.

## CLI

With the app running, run these commands from a cmux terminal pane so the
panel-scoped authentication environment is already present. For automation
outside a pane, provide the app launch token through `CMUX_WINDOWS_TOKEN`.

```powershell
npm run cli -- ping
npm run cli -- list-workspaces
npm run cli -- reset-session
npm run cli -- new-workspace "API"
npm run cli -- new-terminal
npm run cli -- restart-terminal
npm run cli -- browser-open https://example.com
npm run cli -- notify "Build finished"
npm run cli -- send "echo hello from cmux"
```

The runtime listens on `\\.\pipe\cmux-windows` on Windows and falls back to a temp Unix socket on other platforms.

## Scope

Implemented in this milestone:

- Windows desktop shell with workspace sidebar, surface tabs, split panes, and command palette for commands, workspaces, panes, and Settings categories.
- Terminal panes backed by the native terminal bridge when available, with a compatibility fallback.
- Browser panes through Electron `webview`, with iframe fallback outside Electron.
- Named-pipe CLI/control protocol.
- Native Windows window controls, draggable split dividers, terminal font-size controls, restart, and close-to-empty workspace home state.
- Settings panel split into Quick, Workspace, Look, Browser, Layout, Terminal, and Data pages, with tokenized cross-page search, one-click setup presets, expanded themes/accent palettes, custom accent/workspace colors, workspace names/colors, terminal background/text/cursor colors, built-in/URL/local-file backgrounds, browser home page, import/export/reset, density, compact/standard/expanded toolbar modes, sidebar width, tabs/status bar visibility, performance mode, terminal font family, text size, line height, padding, cursor style/blink, default shell profile, and terminal scrollback.
- Compact Tools menu for workspace/session actions so the default top bar stays simple.
- Chrome-style surface tabs with a new-tab button, drag reordering, workspace drop targets, right-click rename/duplicate/focus/move/close/close-others actions, and swatch/custom per-tab colors.
- Browser panes with address/search normalization, back/forward/reload/home controls, open-external fallback, and configurable home page.
- Workspace right-click menus for focus, rename, color, new terminal/browser, new workspace, and close actions.
- Pane drag/drop docking hints for left, right, top, and bottom terminal placement, active-pane focus mode, percent-based active-pane resizing from Settings/Tools, and optimistic workspace/tab updates so moves, closes, and focus changes feel immediate.
- Large terminal output is flushed incrementally across animation frames so heavy command output does not monopolize the renderer.
- Terminal appearance updates from Settings are coalesced per animation frame so dragging font and layout sliders does not repeatedly refresh every terminal.
- Renderer settings/theme/profile data is split into `renderer/config.js`, with the app loaded as an ES module so the frontend can keep moving away from one monolithic file.
- Settings search and page navigation are rendered through a small Vite/React bundle under `renderer/react`, with the existing vanilla controls kept as a fallback.
- Notification drawer, session tools, active focus rings, workspace colors, and pane attention indicators.
- Session layout persistence under `%APPDATA%\cmux-windows\session.json`.

Not complete yet:

- Full Ghostty renderer parity.
- WebView2-native browser automation.
- Automatic Windows updater.
- Complete macOS shortcut/config parity.
