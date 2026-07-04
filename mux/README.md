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

Keys (prefix Ctrl-b, tmux-style): `c` new screen, `n`/`p` next/previous screen, `&` close screen, `,` rename screen, `t` new PTY tab, `B` new browser tab URL prompt, `Tab`/`BackTab` next/previous tab, `1`-`9` select tab, `%` split right, `"` split down, `h j k l`/arrows move focus, `x` close tab, `X` close pane, `$` rename workspace, `w`/`W` switch/create workspace, `s` toggle the workspace sidebar, PageUp/PageDown scrollback, `d` quit, `Ctrl-b` twice sends a literal Ctrl-b. Modeless Alt shortcuts are also on by default: `Alt-n` smart-splits the focused pane, `Alt-h/j/k/l` or Alt-arrows move focus, `Alt-[`/`Alt-]` switch screens, `Alt-t` opens a tab, and `Alt-=`/`Alt--` resize the focused split.

Every pane draws a border box; the active pane's border is highlighted, the pane under the mouse gets a hover shade, and the box is where flashing notifications will hook in later. The top border doubles as an always-visible tab bar: tabs are numbered (`1`, `2`, ...; the process title follows the number when reported), clicking a title switches, dragging a tab reorders it within the pane or moves it to another pane's tab bar, the trailing `+` opens a new tab, and when tabs overflow, `‹`/`›` arrows (or the wheel over the bar) scroll them while the active tab stays visible. User-assigned tab names replace the generated number/title label outright. Drag a shared pane border to resize that split live; dragging a corner moves both intersecting splits, and outer pane edges are inert. Click anywhere in a pane to focus it. The status bar shows the active workspace's screens: click an entry to switch, the trailing `+` for a new screen; it spans only the pane region (not the sidebar). Right-click a pane for rename tab / new tab / split right / split down / close tab / close pane; right-click a workspace in the sidebar for rename/close; right-click a screen in the status bar for rename/close. Context menus and prompts draw muted borders; menu items keep one-cell side padding and the hover/selection highlight spans the full inner row. Right-press, drag, and release on a row activates that row. Prompts use readline-style editing with shortcut buttons (`Clear ^C`, `Cancel esc`, `OK ⏎`); Enter commits, Esc cancels, Ctrl-C clears, and empty tab/screen names fall back to defaults. Right-clicking while the prompt is open shakes it instead of opening a menu. The sidebar reserves two lines per workspace (name, then the active pane's title) under a `workspaces` header with a blank line after it and between entries; click an entry to switch, drag entries to reorder workspaces, `+ new workspace` to create one, and drag the sidebar's right border to resize it for the current session.

Drag to select text in PTY panes; on release the selection is copied to the host clipboard via OSC 52 (works over SSH). The highlight is scroll-stable: it survives viewport scrolling, and holding a selection drag on the top or bottom content edge auto-scrolls while extending the range. Typing clears the selection. Wheel scrolls the PTY pane under the mouse, focusing it first (arrow keys on the alternate screen). Browser panes receive text input, Enter/Backspace/Tab/Esc/navigation keys, left click/drag/release, and wheel scroll through CDP. The scrollbar defaults to a dedicated column just inside the right border; `scrollbar.position = "border"` restores the old border-overlay placement. A `▕` thumb appears whenever the surface has any scrollback (hidden only when no scrolling is possible at all). Hovering or dragging the thumb renders it as `▐`; clicking the thumb anchors a drag without moving the viewport, while clicking the track outside the thumb jumps there and then drags relative to that anchor.

Indexed colors pass through to the host terminal's palette, so `cmux-mux` inherits the host theme like tmux. Truecolor cells pass through unchanged; palette entries overridden by an inner app with OSC 4 render as the override RGB because the host palette does not know about that inner override.

## Browser panes

Press prefix-`B` or right-click a pane and choose `New browser tab` to open a URL prompt. Bare domains get `https://` prepended; `about:blank` and explicit schemes pass through unchanged. Browser panes share one local Chrome DevTools Protocol connection per mux session. cmux first uses `CMUX_MUX_CDP_URL`, then `browser.cdp_url`, then probes `127.0.0.1` discovery ports such as 9222, and only then launches its own Chrome/Chromium-family binary in `--headless=new` mode. Launched Chrome uses a persistent cmux profile by default so logins survive restarts; set `browser.ephemeral` to use a temporary profile deleted on shutdown.

Chrome 136 and newer ignore `--remote-debugging-port` for the default user data directory, so everyday Chrome profiles are not attachable. Reuse works with Chrome instances started with a custom `--user-data-dir` and a debugging port, or with other tooling/headless instances that expose `/json/version`. Headful Chrome may throttle screencast frames when its window or tab is hidden or occluded.

Frames stream as `Page.screencastFrame` PNGs into the TUI. The frame is rendered with the kitty graphics protocol after each Ratatui draw; overlapping cmux menus and prompts temporarily delete the image placement so terminal UI stays readable.

Terminal support:

| Terminal | Browser frame rendering |
| --- | --- |
| Ghostty | Supported via kitty graphics |
| kitty | Supported via kitty graphics |
| WezTerm | Supported when kitty graphics are enabled |
| Other terminals | TUI remains usable and shows `terminal has no kitty graphics support` |

If no reusable browser is found and no Chrome binary is found, browser tab creation fails in the status line with an error naming `browser.chrome_binary`. Attach clients do not stream browser pixels in v1: remote attach shows a placeholder for browser surfaces, and browser creation over attach returns `browser panes are not supported over attach yet`. `list-workspaces` reports browser tabs with `kind: "browser"` and `browser_source: "external"` or `"launched"`.

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
  "sidebar": { "width": 22, "max_width": 0 },
  "browser": {
    "chrome_binary": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "cdp_url": "http://127.0.0.1:9222",
    "discover": true,
    "discover_ports": [9222],
    "user_data_dir": "/Users/me/Library/Application Support/cmux-mux/chrome-profile",
    "ephemeral": false
  },
  "scrollbar": { "position": "column" },
  "keys": {
    "prefix": "ctrl+b",
    "alt_shortcuts": true,
    "new-screen": "c", "next-screen": ["n", "alt+]"], "prev-screen": ["p", "alt+["],
    "close-screen": "&", "rename-screen": ",",
    "new-tab": ["t", "alt+t"], "new_browser_tab": "B",
    "next-tab": "tab", "prev-tab": "backtab", "close-tab": "x", "close-pane": "X",
    "new-pane-smart": "alt+n",
    "split-right": "%", "split-down": "\"",
    "rename-tab": "none", "rename-workspace": "$",
    "next-workspace": "w", "new-workspace": "W",
    "toggle-sidebar": "s",
    "focus-left": ["h", "left", "alt+h", "alt+left"],
    "focus-right": ["l", "right", "alt+l", "alt+right"],
    "focus-up": ["k", "up", "alt+k", "alt+up"],
    "focus-down": ["j", "down", "alt+j", "alt+down"],
    "resize-grow": "alt+=", "resize-shrink": "alt+-",
    "scroll-up": "pageup", "scroll-down": "pagedown",
    "detach": "d"
  }
}
```

Colors are `#rrggbb`, `#rgb`, or an xterm-256 index. The selection colors default to the user's Ghostty config (`selection-background`/`selection-foreground` from `~/.config/ghostty/config`), falling back to a dark grey. `sidebar_rail` controls the active workspace rail, `sidebar_active_bg` its two-row background, `tab_rail` the active tab chip rail, `tab_bg` inactive solid tab chips, and `tab_active_bg` overrides the focused/unfocused active tab chip backgrounds when set. Tabs are numbered `1 2 3…` by default; recognized agent programs (the `agents` list) surface after the number, `show_titles` restores full process titles, and a user-assigned tab name overrides both. `sidebar.max_width` defaults to `0` for unlimited, while live drag still leaves at least 40 columns for panes. `scrollbar.position` is `"column"` by default or `"border"` for the old right-border overlay. Browser config is optional: `chrome_binary` overrides binary discovery, `cdp_url` accepts `ws://...` or `http://host:port`, `discover` defaults to true, `discover_ports` defaults to `[9222]`, `user_data_dir` overrides the launched profile path, and `ephemeral` restores temporary-profile behavior. When `ephemeral` is true it takes precedence over `user_data_dir`: cmux creates and later deletes a fresh temp profile and never deletes the configured directory. Every prefix/modeless binding is remappable via `keys` (formats: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"backtab"`, `"pageup"`); values may be a string, an array of strings, or `"none"` to unbind. Set `"alt_shortcuts": false` to remove default Alt chords without blocking user-configured Alt chords. `1`-`9` stay fixed to tab selection. The old key name `"rename-pane"` is still accepted as an alias for `"rename-tab"`.

## Control socket

Every instance serves a JSON-lines protocol on a unix socket (default `$TMPDIR/cmux-mux-<uid>/<session>.sock`, also exported to children as `CMUX_MUX_SOCKET`). One request per line:

```bash
SOCK=${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock
printf '%s\n' '{"id":1,"cmd":"identify"}' | nc -U "$SOCK"
printf '%s\n' '{"id":2,"cmd":"list-workspaces"}' | nc -U "$SOCK"
printf '%s\n' '{"id":3,"cmd":"send","surface":1,"text":"ls\r"}' | nc -U "$SOCK"
printf '%s\n' '{"id":4,"cmd":"read-screen","surface":1}' | nc -U "$SOCK"
```

Commands: `identify`, `list-workspaces` (each workspace carries `screens`, each with its split-tree `layout` plus `panes` with their `tabs`; each tab includes `kind: "pty" | "browser"` and browser tabs include `browser_source`), `send` (text or base64 `bytes`, PTY only), `read-screen` (PTY only), `vt-state` (PTY only), `new-tab` (PTY tab in a pane), `new-browser-tab` (local browser tab in a pane), `new-screen` (in a workspace), `new-workspace`, `split` (`dir`: `right`/`down`), `set-ratio` (`pane`, `dir`: `right`/`down`, `ratio`), `move-tab` (`surface`, target `pane`, insertion `index`), `move-workspace` (`workspace`, insertion `index`), `set-default-colors` (`fg`/`bg`: `#rrggbb`), `close-surface`, `close-pane`, `close-screen`, `close-workspace`, `rename-surface`, `rename-pane`, `rename-screen`, `rename-workspace`, `resize-surface`, `focus-pane`, `select-tab` (within a pane), `select-screen`, `select-workspace`, `scroll-surface` (PTY only), `subscribe`, `attach-surface` (PTY only).

`subscribe` turns the connection full-duplex: the server pushes `{"event":...}` lines (tree-changed, surface-output, surface-resized, surface-exited, title-changed, bell). A changed `resize-surface` broadcasts `{"event":"surface-resized","surface":1,"cols":120,"rows":40}` with the final cell size; a same-size resize emits no event. `attach-surface` sends a `vt-state` event carrying a base64 VT replay of a PTY surface's complete state (screen, styles, cursor, modes, palette, kitty keyboard state, charsets — produced by ghostty's formatter), then streams every subsequent pty byte as `output` events. Replaying state then stream into a fresh terminal reproduces the surface exactly; the snapshot and stream tap are taken under the same terminal lock, so there is no gap and no duplication. This is the attach surface for the cmux app: a real Ghostty surface can adopt a tab by replaying `vt-state` and following the stream, because both sides speak the same VT engine. Browser surfaces are local-only in v1; PTY-only socket commands against them return `ok:false` with a clear error.

When several attach clients render the same surface at different sizes, the PTY uses latest-interaction sizing: a client reasserts its visible pane sizes only after local user interaction (key, mouse, paste, focus gained, or terminal resize). Mux-driven redraws update each client's mirror from `surface-resized` but do not reassert that client's viewport, so idle clients cannot fight over the PTY size.

## Design notes

- The pty reader thread is the only writer into a surface's `Terminal`; renderers take the terminal lock just long enough to snapshot into their own `RenderState`, so slow frontends never block pty IO.
- Query responses (DSR, DECRQM, ...) generated during parsing are queued by the write-pty callback and flushed to the pty after each parse batch.
- On TUI startup, cmux-mux probes the host terminal's default foreground/background with OSC 10/11 and caches any replies on the session. Inner apps that query OSC 10/11/4, such as Codex blending UI backgrounds from the terminal background, get libghostty-vt replies that match the host terminal. If the host does not answer the startup probe, dynamic color queries stay unanswered as before.
- Input is encoded with ghostty's key encoder synced from the active surface's terminal modes each keystroke, so cursor-key application mode and the kitty keyboard protocol work end to end.
- Browser input is sent through CDP `Input.*` commands; CDP screencast frames are acknowledged immediately so Chrome keeps streaming.
- Browser surfaces share a single CDP browser connection; closing a tab closes only its target, and mux shutdown kills Chrome only when cmux launched it.
- Exited surfaces are reaped by the mux itself (tab removed, pane/workspace collapsed), so headless sessions and every frontend see the same tree without frontend-side cleanup.
- Surfaces spawn at their final render size (`new-tab`/`new-workspace`/`split` take optional `cols`/`rows`, and the TUI predicts sizes from its layout): spawning at 80x24 and resizing a frame later makes shells repaint their first prompt, which left zsh's reverse-video `%` partial-line marker on screen.
- Children get `TERM=xterm-256color` by default; set `--term xterm-ghostty` (or `CMUX_MUX_TERM`) when the ghostty terminfo is installed.

## Current limitations

- Scrollback from before an attach is not replayed (the VT replay covers the screen and state, not history); the mirror accumulates its own scrollback from the live stream.
- Browser frame streaming over attach is not implemented; attach clients show a placeholder for browser tabs.
- Reused headful Chrome instances can pause screencast frames when their windows or tabs are hidden.
- No PTY mouse-event forwarding to applications (viewport scroll and alternate-screen arrow fallback only).
- Kitty graphics generated by PTY applications are tracked by the engine but not rendered by the TUI.
- Pane split ratios are adjustable from the TUI and control socket, but not persisted across new splits.
