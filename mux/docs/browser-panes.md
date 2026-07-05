# Browser Panes

Browser panes are local Chrome/Chromium targets controlled with the Chrome DevTools Protocol. They live in the same pane and tab tree as PTY tabs, but their rendering and input path are CDP-based instead of VT-based.

## Requirements

Browser panes need a local CDP endpoint or a launchable Chrome/Chromium-family binary. The TUI can reuse an external endpoint, discover one on configured local ports, or launch Chrome itself in `--headless=new` mode.

Endpoint selection order:

1. `CMUX_MUX_CDP_URL`
2. `browser.cdp_url` in `mux.json`
3. Discovery on `browser.discover_ports` when `browser.discover` is true
4. A launched Chrome using `browser.chrome_binary` or binary discovery in `mux-cdp`

Binary discovery checks configured paths, known macOS and Linux Chrome-family paths, then `PATH` names such as `google-chrome`, `chromium`, `brave-browser`, and `microsoft-edge`.

Set `CMUX_MUX_CDP_DEBUG` to print browser runtime debug messages to stderr.

## Creating Panes

Use prefix `B`, or right-click a pane and choose `New browser tab`. The prompt starts with `https://`.

Bare domains get `https://` prepended. Inputs containing `://`, or starting with `about:`, `file:`, `data:`, `chrome:`, or `devtools:`, pass through unchanged.

Browser tabs are created inside an existing pane when one is active. If the session has no workspaces, creating a browser tab creates a workspace, screen, and pane around it.

## Rendering

The browser runtime creates a target, attaches with CDP, enables the page domain, sets device metrics from the pane's cell size and detected cell pixels, and starts `Page.screencastFrame`.

The TUI draws the latest PNG frame with the kitty graphics protocol after each Ratatui frame. If a context menu or prompt overlaps the pane, the graphics placement is omitted for that frame so the terminal UI stays readable.

If the host terminal does not support kitty graphics, the pane displays `terminal has no kitty graphics support`. If the browser frame has not arrived yet, it displays a loading message.

## Input

Printable character keys and paste use CDP insert-text. Enter, Backspace, Tab, Esc, arrows, Home, End, PageUp, PageDown, and Delete use CDP key events with modifier bits for Alt, Control, Super, and Shift.

Left click, drag, release, and wheel events inside browser content are forwarded as CDP mouse input. Wheel deltas are scaled by the detected cell height.

## Profiles and Lifecycle

Browser panes share one browser runtime per mux session. Closing a browser tab closes only its target. Mux shutdown kills Chrome only when cmux launched it.

Launched Chrome uses a persistent cmux profile unless `browser.ephemeral` is true. `browser.user_data_dir` overrides the persistent profile path. When ephemeral mode is true, Chrome uses a temporary profile that is deleted on shutdown and ignores `browser.user_data_dir`.

The default launched profile is `~/Library/Application Support/cmux-mux/chrome-profile` on macOS. On non-macOS targets it is `$XDG_DATA_HOME/cmux-mux/chrome-profile` when `XDG_DATA_HOME` is set, then `~/.local/share/cmux-mux/chrome-profile`.

## Limitations

Browser panes are local-only as of protocol v6. `attach-surface` returns an error for browser surfaces, attach clients do not receive browser frame streams, and a remote TUI shows a placeholder for browser panes.

Headful external Chrome can throttle screencast frames when the window or tab is hidden or occluded. Chrome 136 and newer do not allow `--remote-debugging-port` with the default user data directory, so reusable everyday Chrome profiles may not expose CDP.
