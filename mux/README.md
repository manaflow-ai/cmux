# cmux-mux

A decoupled terminal-multiplexer backend for cmux, with a bundled tmux-like TUI. The multiplexer core owns workspaces → screens → split panes → tabs: a workspace holds screens (like tmux windows; the status bar switches between them), each screen is a binary split tree of panes mirroring the cmux app's pane system, and each pane holds one or more tabs (surfaces). A surface can be a real PTY whose output feeds libghostty-vt, or a local Chrome/Chromium page driven over the Chrome DevTools Protocol and rendered in the TUI with kitty graphics. Frontends only read render snapshots and send input, so PTY session state can be drawn by the Ratatui TUI in any terminal today and attached to real Ghostty surfaces in the cmux app later.

## Layout

- `crates/ghostty-vt-sys` — raw FFI. build.rs compiles `libghostty-vt.a` from `../ghostty` with zig (`-Demit-lib-vt=true`, ReleaseFast) and generates bindings from `include/ghostty/vt.h` with bindgen.
- `crates/ghostty-vt` — safe wrapper: `Terminal` (vt parsing, modes, callbacks, plain-text dump), `RenderState` (dirty-tracked viewport snapshots), `KeyEncoder` (legacy + kitty keyboard protocol, synced from terminal modes).
- `crates/mux-cdp` — sync CDP transport and Chrome lifecycle for local browser surfaces.
- `crates/mux-core` — the backend: session model (`model.rs`), orchestrator (`mux.rs`), surface runtimes (`surface.rs` / `browser.rs`), layout math shared by frontends (`layout.rs`), and the JSON control socket (`server.rs`).
- `crates/mux-tui` — the `cmux-mux` binary: crossterm + Ratatui frontend (`app.rs` event loop, `ui/` drawing, `session/` local-or-remote session abstraction).

## Build and run

Requires zig 0.15.2 (same pin as CI, see `scripts/install-zig-ci.sh`) and a Rust toolchain. The ghostty submodule must be initialized.

```bash
cd mux
cargo run -p mux-tui            # TUI, session "main"
cargo run -p mux-tui -- --headless --session agents   # backend only
cargo run -p mux-tui -- attach --session agents       # attach/reattach a TUI to it
cargo test                      # unit + integration tests
```

Detach with prefix-d while attached; the headless session keeps running and `attach` reconnects with full screen state (VT replay + live stream). A local (non-attach) `cmux-mux` ends its session on quit.

Keys (prefix Ctrl-b, tmux-style): `c` new PTY tab in the active pane, `B` new browser tab with a focused omnibar, `n`/`p`/`1`-`9` switch tab within the pane, `%` split right, `"` split down, `h j k l`/arrows move focus, `x` close tab (a pane collapses with its last tab), `,` rename tab, `$` rename workspace, `Tab` next screen, `S` new screen, `w` next workspace, `W` new workspace, `s` toggle the workspace sidebar, PageUp/PageDown scrollback, browser panes use `<` back, `>` forward, `r` reload, and `u` edit URL, `d` quit, `Ctrl-b` twice sends a literal Ctrl-b. In browser panes, `Ctrl-L` focuses the omnibar without sending the chord to the page.

Every pane draws a border box; the active pane's border is highlighted, the pane under the mouse gets a hover shade, and the box is where flashing notifications will hook in later. The top border doubles as an always-visible tab bar: tabs are numbered (`1`, `2`, ...; the process title follows the number when reported), clicking a title switches, the trailing `+` opens a new tab, and when tabs overflow, `‹`/`›` arrows (or the wheel over the bar) scroll them while the active tab stays visible. Browser panes draw an in-pane omnibar above the rendered page with back, forward, reload, and editable URL/search text; Enter navigates, Esc blurs, and plain mouse movement over the page is forwarded so CSS hover states update. User-assigned tab names replace the generated number/title label outright. Drag a shared pane border to resize that split live; dragging a corner moves both intersecting splits, and outer pane edges are inert. Click anywhere in a pane to focus it. The status bar shows the active workspace's screens: click an entry to switch, the trailing `+` for a new screen; it spans only the pane region (not the sidebar), with the session label right-aligned. Right-click a pane for rename tab / new tab / split right / split down / close tab / close pane; browser panes add Back / Forward / Reload / Edit URL / Copy URL, and external/headful browser panes add Show in Chrome. Right-click a workspace in the sidebar for rename/close; right-click a screen in the status bar for rename/close. Context menus and rename dialogs draw muted borders; menu items keep one-cell side padding and the hover/selection highlight spans the full inner row. Right-press, drag, and release on a row activates that row. Renames use a centered prompt (Enter commits, Esc cancels; empty tab/screen names fall back to defaults); right-clicking while the prompt is open shakes it instead of opening a menu. The sidebar reserves two lines per workspace (name, then the active pane's title) under a `workspaces` header with a blank line after it and between entries; click an entry to switch, `+ new workspace` to create one, and drag the sidebar's right border to resize it for the current session.

Drag to select text in PTY panes; on release the selection is copied to the host clipboard via OSC 52 (works over SSH). The highlight is viewport-anchored and clears on scroll or typing. Wheel scrolls the PTY pane under the mouse, focusing it first (arrow keys on the alternate screen). Browser panes receive text input, Enter/Backspace/Tab/Esc/navigation keys, left click/drag/release, and wheel scroll through CDP. The scrollbar defaults to a dedicated column just inside the right border; `scrollbar.position = "border"` restores the old border-overlay placement. A `▕` thumb appears whenever the surface has any scrollback (hidden only when no scrolling is possible at all). Hovering or dragging the thumb renders it as `▐`; clicking the thumb anchors a drag without moving the viewport, while clicking the track outside the thumb jumps there and then drags relative to that anchor.

Indexed colors pass through to the host terminal's palette, so `cmux-mux` inherits the host theme like tmux. Truecolor cells pass through unchanged; palette entries overridden by an inner app with OSC 4 render as the override RGB because the host palette does not know about that inner override.

## Browser panes

Press prefix-`B` or right-click a pane and choose `New browser tab` to create an `about:blank` browser tab and focus its omnibar. The omnibar passes explicit `://` URLs through, prefixes localhost/loopback addresses with `http://`, prefixes dotted domains with `https://`, and turns other text into a Google search URL. Browser panes share one local Chrome DevTools Protocol connection per mux session. cmux first uses `CMUX_MUX_CDP_URL`, then `browser.cdp_url`, then probes `127.0.0.1` discovery ports such as 9222, and only then launches its own Chrome/Chromium-family binary in `--headless=new` mode. Launched Chrome uses a persistent cmux profile by default so logins survive restarts; set `browser.ephemeral` to use a temporary profile deleted on shutdown.

Chrome 136 and newer ignore `--remote-debugging-port` for the default user data directory, so everyday Chrome profiles are not attachable. Reuse works with Chrome instances started with a custom `--user-data-dir` and a debugging port, or with other tooling/headless instances that expose `/json/version`. Headful Chrome may throttle screencast frames when its window or tab is hidden or occluded.

Frames stream as `Page.screencastFrame` PNGs into the TUI. The frame is rendered with the kitty graphics protocol after each Ratatui draw; overlapping cmux menus and prompts temporarily delete the image placement so terminal UI stays readable. Large panes are captured at a scaled viewport by default: `browser.max_capture_megapixels` is 2.0, and `browser.capture_scale` can force a fixed scale from `0 < scale <= 1`.

Terminal support:

| Terminal | Browser frame rendering |
| --- | --- |
| Ghostty | Supported via kitty graphics |
| kitty | Supported via kitty graphics |
| WezTerm | Supported when kitty graphics are enabled |
| Other terminals | TUI remains usable and shows `terminal has no kitty graphics support` |

Browser tab creation inserts the tab immediately with a `starting browser...` placeholder while Chrome/CDP setup runs in the background. Failures stay in the pane as `browser failed: ...` and also appear in the status line, so a bad binary, dead CDP endpoint, or page-load failure does not freeze the TUI. JavaScript dialogs are auto-handled (`beforeunload` accepted, alert/confirm/prompt dismissed) and reported in the status line. `window.open` and `_blank` page targets whose opener is a mux browser tab are adopted as new tabs in the same pane; unrelated external targets are ignored. External headful Chrome can still throttle hidden tabs; when a live browser surface stops producing frames, the omnibar shows `⏸ chrome tab hidden`, and clicking, typing, or scrolling the pane nudges Chrome with `Target.activateTarget` once for that stall episode.

Attach clients stream browser panes over protocol 6. `attach-surface` sends the current browser state and latest PNG frame if one exists, then streams subsequent frames; mouse, hover, wheel, keyboard, text insertion, URL navigation, back, forward, reload, and activate are forwarded over the control socket. Older protocol 4/5 servers still show the clear `browser panes are not supported over attach yet` placeholder. Browser device metrics use the rendering client's detected terminal cell pixel size, scaled by the capture budget; with multiple concurrent attach clients, the last `set-cell-pixels` writer wins. `list-workspaces` reports browser tabs with `kind: "browser"`, `browser_source: "external"` or `"launched"` once live, and additive `browser_status` / `browser_error` / `browser_frames_stalled` fields.

## Performance

Browser capture is budgeted before it reaches the socket or kitty graphics path. The default `browser.max_capture_megapixels` value of 2.0 scales oversized panes down for both `Emulation.setDeviceMetricsOverride` and `Page.startScreencast`; `browser.capture_scale` overrides the budget with a fixed scale. Input coordinates stay in pane pixels and are scaled inside mux-core, so attached clients do not need protocol changes.

Use `scripts/measure-frames.py` against a running session to keep the evidence loop tight:

```bash
python3 scripts/measure-frames.py --socket /path/to/session.sock --surface 42 --seconds 10
python3 scripts/measure-frames.py --socket /path/to/session.sock --url https://example.com --seconds 10
```

The script reports FPS, frame byte sizes, inter-frame gaps, and wheel-to-next-frame latency. If it receives zero frames, it exits nonzero with a hint to check hidden or occluded external Chrome tabs.

## Configuration

`~/.config/cmux/mux.json` (override with `CMUX_MUX_CONFIG`); every key is optional:

```json
{
  "theme": {
    "selection_background": "#3a3a3a",
    "selection_foreground": null,
    "sidebar_rail": "#87afd7",
    "sidebar_active_bg": 236,
    "tab_rail": "#87afd7",
    "tab_bg": 236,
    "tab_active_bg": null,
    "border_active": "#87afd7",
    "border_inactive": "#444444"
  },
  "tabs": {
    "min_width": 7,
    "solid_background": true,
    "show_titles": false,
    "agents": ["claude", "codex", "opencode", "pi"]
  },
  "sidebar": { "width": 22 },
  "browser": {
    "chrome_binary": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "cdp_url": "http://127.0.0.1:9222",
    "discover": true,
    "discover_ports": [9222],
    "user_data_dir": "/Users/me/Library/Application Support/cmux-mux/chrome-profile",
    "ephemeral": false,
    "max_capture_megapixels": 2.0,
    "capture_scale": null
  },
  "scrollbar": { "position": "column" },
  "keys": {
    "prefix": "ctrl+b",
    "new-tab": "c", "new_browser_tab": "B",
    "next-tab": "n", "prev-tab": "p",
    "split-right": "%", "split-down": "\"", "close-tab": "x",
    "rename-tab": ",", "rename-workspace": "$",
    "next-screen": "tab", "new-screen": "S",
    "next-workspace": "w", "new-workspace": "W",
    "toggle-sidebar": "s",
    "focus-left": "h", "focus-right": "l", "focus-up": "k", "focus-down": "j",
    "scroll-up": "pageup", "scroll-down": "pagedown",
    "detach": "d"
  }
}
```

Colors are `#rrggbb`, `#rgb`, or an xterm-256 index. The selection colors default to the user's Ghostty config (`selection-background`/`selection-foreground` from `~/.config/ghostty/config`), falling back to a dark grey. `sidebar_rail` controls the active workspace rail, `sidebar_active_bg` its two-row background, `tab_rail` the active tab chip rail, `tab_bg` inactive solid tab chips, and `tab_active_bg` overrides the focused/unfocused active tab chip backgrounds when set. Tabs are numbered `1 2 3…` by default; recognized agent programs (the `agents` list) surface after the number, `show_titles` restores full process titles, and a user-assigned tab name overrides both. `scrollbar.position` is `"column"` by default or `"border"` for the old right-border overlay. Browser config is optional: `chrome_binary` overrides binary discovery, `cdp_url` accepts `ws://...` or `http://host:port`, `discover` defaults to true, `discover_ports` defaults to `[9222]`, `user_data_dir` overrides the launched profile path, and `ephemeral` restores temporary-profile behavior. `max_capture_megapixels` must be greater than zero and defaults to 2.0; `capture_scale`, when set, must satisfy `0 < scale <= 1` and overrides the megapixel budget. When `ephemeral` is true it takes precedence over `user_data_dir`: cmux creates and later deletes a fresh temp profile and never deletes the configured directory. Every prefix binding is remappable via `keys` (formats: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"pageup"`); `1`-`9` stay fixed to tab selection. The old key name `"rename-pane"` is still accepted as an alias for `"rename-tab"`.

## Control socket

Every instance serves a JSON-lines protocol on a unix socket (default `$TMPDIR/cmux-mux-<uid>/<session>.sock`, also exported to children as `CMUX_MUX_SOCKET`). One request per line:

```bash
SOCK=${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock
printf '%s\n' '{"id":1,"cmd":"identify"}' | nc -U "$SOCK"
printf '%s\n' '{"id":2,"cmd":"list-workspaces"}' | nc -U "$SOCK"
printf '%s\n' '{"id":3,"cmd":"send","surface":1,"text":"ls\r"}' | nc -U "$SOCK"
printf '%s\n' '{"id":4,"cmd":"read-screen","surface":1}' | nc -U "$SOCK"
```

Commands: `identify`, `list-workspaces` (each workspace carries `screens`, each with its split-tree `layout` plus `panes` with their `tabs`; each tab includes `kind: "pty" | "browser"` and browser tabs include `browser_source`), `send` (text or base64 `bytes`, PTY only), `read-screen` (PTY only), `vt-state` (PTY only), `new-tab` (PTY tab in a pane), `new-browser-tab` (browser tab in a pane; returns after tree insertion, before CDP bootstrap may be complete), `new-screen` (in a workspace), `new-workspace`, `split` (`dir`: `right`/`down`), `set-ratio` (`pane`, `dir`: `right`/`down`, `ratio`), `set-default-colors` (`fg`/`bg`: `#rrggbb`), `set-cell-pixels` (`width_px`, `height_px`), `close-surface`, `close-pane`, `close-screen`, `close-workspace`, `rename-surface`, `rename-pane`, `rename-screen`, `rename-workspace`, `resize-surface`, `focus-pane`, `select-tab` (within a pane), `select-screen`, `select-workspace`, `scroll-surface` (PTY only), `browser-mouse`, `browser-wheel`, `browser-key`, `browser-insert-text`, `browser-navigate`, `browser-back`, `browser-forward`, `browser-reload`, `browser-activate`, `subscribe`, `attach-surface`.

`subscribe` turns the connection full-duplex: the server pushes `{"event":...}` lines (tree-changed, surface-output, surface-exited, title-changed, bell, status). `attach-surface` on PTYs sends a `vt-state` event carrying a base64 VT replay of the complete state (screen, styles, cursor, modes, palette, kitty keyboard state, charsets — produced by ghostty's formatter), then streams every subsequent pty byte as `output` events. Replaying state then stream into a fresh terminal reproduces the surface exactly; the snapshot and stream tap are taken under the same terminal lock, so there is no gap and no duplication. `attach-surface` on browsers sends `browser-state` with URL/title/size/status/stall state and optional latest frame, then streams `frame` events with base64 PNG payloads and finishes with `detached` when the surface or tap ends. Browser frame snapshot and tap registration happen under the same frame-state lock; each tap keeps one latest-frame slot plus a wakeup, so slow clients skip old frames instead of accumulating latency or being detached. PTY-only socket commands against browser surfaces return `ok:false` with a clear error.

## Design notes

- The pty reader thread is the only writer into a surface's `Terminal`; renderers take the terminal lock just long enough to snapshot into their own `RenderState`, so slow frontends never block pty IO.
- Query responses (DSR, DECRQM, ...) generated during parsing are queued by the write-pty callback and flushed to the pty after each parse batch.
- On TUI startup, cmux-mux probes the host terminal's default foreground/background with OSC 10/11 and caches any replies on the session. Inner apps that query OSC 10/11/4, such as Codex blending UI backgrounds from the terminal background, get libghostty-vt replies that match the host terminal. If the host does not answer the startup probe, dynamic color queries stay unanswered as before.
- Input is encoded with ghostty's key encoder synced from the active surface's terminal modes each keystroke, so cursor-key application mode and the kitty keyboard protocol work end to end.
- Browser input is sent through CDP `Input.*` commands; CDP screencast frames are acknowledged immediately so Chrome keeps streaming.
- Browser surfaces share a single CDP browser connection; closing a tab closes only its target, and mux shutdown kills Chrome only when cmux launched it.
- SIGTERM, SIGINT, and SIGHUP set a signal flag that the TUI/headless loops check, then normal teardown restores the terminal, shuts down browser runtimes, and removes the socket.
- Exited surfaces are reaped by the mux itself (tab removed, pane/workspace collapsed), so headless sessions and every frontend see the same tree without frontend-side cleanup.
- Surfaces spawn at their final render size (`new-tab`/`new-workspace`/`split` take optional `cols`/`rows`, and the TUI predicts sizes from its layout): spawning at 80x24 and resizing a frame later makes shells repaint their first prompt, which left zsh's reverse-video `%` partial-line marker on screen.
- Children get `TERM=xterm-256color` by default; set `--term xterm-ghostty` (or `CMUX_MUX_TERM`) when the ghostty terminfo is installed.

## Current limitations

- Scrollback from before an attach is not replayed (the VT replay covers the screen and state, not history); the mirror accumulates its own scrollback from the live stream.
- Reused headful Chrome instances can pause screencast frames when their windows or tabs are hidden; the omnibar stall indicator and interaction nudge make this visible but cannot prevent all external Chrome throttling.
- No PTY mouse-event forwarding to applications (viewport scroll and alternate-screen arrow fallback only).
- Kitty graphics generated by PTY applications are tracked by the engine but not rendered by the TUI.
- Pane split ratios are adjustable from the TUI and control socket, but not persisted across new splits.
