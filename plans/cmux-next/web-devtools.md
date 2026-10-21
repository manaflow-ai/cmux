# Web view developer tools (Cmd-Shift-P)

User asks (Oct 20): "For all web views I want to be able to use Command+Shift+P, select Inspect
Element, and have it show the web inspector"; then: a full Developer Tools command set (Console,
Network, Performance, Memory, ...) like Chrome DevTools' Command Menu and Safari's Develop menu.

## Target

`WebInspectorTargets` (CmuxNextApp) picks the web view the commands act on:

1. The window's focus below any overlay (`FocusState.underlying`: what the palette's commands act
   on), so the web view focused before Cmd-Shift-P stays the target. A browser pane gives its tab
   (WebKit or Chromium); any other pane (Markdown, agent chat, internal page, gallery page) gives
   the shown `WKWebView` in it, the one holding the first responder first.
2. Else the key window's first responder inside a `WKWebView` (Settings or popover windows).
3. Else a shown top page's web view.

Home's chat transcript is native AppKit, not a web view: there the commands are disabled (Home's
Channels page is a web view and works).

## Commands

- **Inspect Element** (`inspectBrowserElement`, Cmd-Opt-C), **Toggle Developer Tools**
  (Cmd-Opt-I) and **Show JavaScript Console** (Cmd-Opt-J) now need no browser focus
  (`requires` is empty; content key tier): always listed, disabled with "Click in a browser tab or
  another web view first." while there is no target. WebKit: Web Inspector plus element selection
  (`_WKInspector toggleElementSelection`). Chromium: DevTools' element picker.
- **The `devtools.*` set** (`WebDevToolsCommand`, CmuxNextBrowser): needs the new
  `webViewFocused` context bit, so it is listed only while a web view has focus. A command the
  target's engine cannot run stays listed, disabled, with its `WebDevToolsLimit` reason.
- Existing actions cover the rest: Emulate Device (`browserDevice`, a129's list), color scheme
  (`browserTheme`), Hard Reload (`browserHardReload`), Screenshot Page, Delete Site Data.

`isInspectable` is now true in every build (it was DEBUG-only for pages, agent chats and agent
activity); `WebKitInspector.prepare()` also sets it on any web view before it shows.

## Chromium panels

The CEF shim had DevTools show, console and inspect only. New `cmux_shim_devtools_show_panel`
opens DevTools when closed and runs `DevToolsAPI.showPanel(id)` in the frontend (the call Chrome
makes for a panel), once its frontend has loaded (`CefLoadHandler::OnLoadEnd`), retrying at 300
and 1200 ms in the frontend's own timers on a cold open. Panel ids are `[a-z0-9-]` only.

## Chromium modes

`WebDevToolsToggles` (stored on `CEFTab.devToolsModes`) records each toggle and returns the
protocol calls. cmux's DevTools session lives as long as the tab, so modes hold across navigations
until switched off. The color scheme and reduced motion share `Emulation.setEmulatedMedia`, so both
go in one call (`emulatedMedia`) and neither clears the other.

## Support matrix

| Action | Title | Chromium | WebKit (tabs and other web views) |
|---|---|---|---|
| `devtools.openDocked` | Developer Tools: Open Docked | yes (dock bottom + show) | yes (`attach`) |
| `devtools.openDockedRight` | Developer Tools: Dock to Right | yes (dock right + show) | no: Web Inspector picks its side |
| `devtools.openInWindow` | Developer Tools: Open in Separate Window | yes (dock window + show) | yes (`detach`) |
| `devtools.close` | Developer Tools: Close | yes (close) | yes |
| `devtools.showElements` | Developer Tools: Show Elements | yes (`DevToolsAPI.showPanel`) | yes (`show`) |
| `devtools.showSources` | Developer Tools: Show Sources | yes (`DevToolsAPI.showPanel`) | yes (`showResources`) |
| `devtools.showNetwork` | Developer Tools: Show Network | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showPerformance` | Developer Tools: Show Performance | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showMemory` | Developer Tools: Show Memory | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showApplication` | Developer Tools: Show Application | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showLighthouse` | Developer Tools: Show Lighthouse | yes (`DevToolsAPI.showPanel`) | no: Chromium only |
| `devtools.showLayers` | Developer Tools: Show Layers | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showRendering` | Developer Tools: Show Rendering | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showSensors` | Developer Tools: Show Sensors | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showSecurity` | Developer Tools: Show Security | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.showAnimations` | Developer Tools: Show Animations | yes (`DevToolsAPI.showPanel`) | no: no Web Inspector command for the tab |
| `devtools.pauseScript` | Developer Tools: Pause Script Execution | yes (`Debugger.pause`) | no: Chromium only |
| `devtools.resumeScript` | Developer Tools: Resume Script Execution | yes (`Debugger.resume`) | no: Chromium only |
| `devtools.clearConsole` | Developer Tools: Clear Console | yes (script) | yes (script) |
| `devtools.copyConsoleLog` | Developer Tools: Copy Console Log | no: Console > Save as | no: Console > Save as |
| `devtools.toggleCache` | Developer Tools: Disable Cache | yes (`Network.setCacheDisabled`) | no: Chromium only |
| `devtools.throttleOffline` | Network: Go Offline | yes (`Network.emulateNetworkConditions`) | no: Chromium only |
| `devtools.throttleSlow3G` | Network: Throttle to Slow 3G | yes (`Network.emulateNetworkConditions`) | no: Chromium only |
| `devtools.throttleFast3G` | Network: Throttle to Fast 3G | yes (`Network.emulateNetworkConditions`) | no: Chromium only |
| `devtools.throttleOff` | Network: No Throttling | yes (`Network.emulateNetworkConditions`) | no: Chromium only |
| `devtools.emptyCacheAndHardReload` | Developer Tools: Empty Cache and Hard Reload | yes (`Network.clearBrowserCache` + `Page.reload`) | yes (data store + `reloadFromOrigin`) |
| `devtools.clearSiteData` | Developer Tools: Clear Site Data and Cookies | yes (`Storage.clearDataForOrigin`) | yes (data store) |
| `devtools.toggleJavaScript` | Developer Tools: Disable JavaScript | yes (`Emulation.setScriptExecutionDisabled`) | no: Chromium only |
| `devtools.toggleCSS` | Developer Tools: Disable CSS | yes (script) | yes (script) |
| `devtools.toggleReducedMotion` | Rendering: Emulate Reduced Motion | yes (`Emulation.setEmulatedMedia`) | no: Chromium only |
| `devtools.toggleFocusEmulation` | Rendering: Emulate a Focused Page | yes (`Emulation.setFocusEmulationEnabled`) | no: Chromium only |
| `devtools.togglePaintFlashing` | Rendering: Show Paint Flashing | yes (`Overlay.setShowPaintRects`) | no: Chromium only |
| `devtools.toggleLayoutShiftRegions` | Rendering: Show Layout Shift Regions | yes (`Overlay.setShowLayoutShiftRegions`) | no: Chromium only |
| `devtools.toggleLayerBorders` | Rendering: Show Layer Borders | yes (`Overlay.setShowDebugBorders`) | no: Chromium only |
| `devtools.toggleFPSMeter` | Rendering: Show Frame Rendering Stats | yes (`Overlay.setShowFPSCounter`) | no: Chromium only |
| `devtools.togglePerformanceRecording` | Developer Tools: Start or Stop Performance Recording | no: Record in the Performance panel | yes (`togglePageProfiling`, Timelines) |
| `devtools.takeHeapSnapshot` | Developer Tools: Take Heap Snapshot | no: Take snapshot in the Memory panel | no: Timelines tab |
| `devtools.captureScreenshot` | Developer Tools: Capture Screenshot | yes (tab snapshot) | yes (`takeSnapshot`) |
| `devtools.captureFullPageScreenshot` | Developer Tools: Capture Full Size Screenshot | yes (full-page snapshot) | browser tabs only |
| `devtools.captureNodeScreenshot` | Developer Tools: Capture Node Screenshot | no: Elements node menu | no: node menu |
| `devtools.viewPageSource` | Developer Tools: View Page Source | yes (`view-source:` tab) | yes (Sources tab) |

## Not verified live

Unit tests cover the matrix, the protocol calls, the target finder and the registry wiring. The
shim change needs a fleet app build; `DevToolsAPI.showPanel` for drawer views (Rendering, Sensors,
Animations) and the cold-open retry were not run in an app.
