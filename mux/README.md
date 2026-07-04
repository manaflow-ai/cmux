# cmux-mux

A decoupled terminal-multiplexer backend for cmux, with a bundled tmux-like TUI. The multiplexer core owns workspaces → screens → split panes → tabs: a workspace holds screens (like tmux windows; the status bar switches between them), each screen is a binary split tree of panes mirroring the cmux app's pane system, and each pane holds one or more tabs (surfaces). Each tab is a real PTY whose output feeds libghostty-vt, the terminal engine extracted from Ghostty and built from this repo's `ghostty/` submodule. Frontends only read render snapshots and send input, so the same session state can be drawn by the Ratatui TUI in any terminal today and attached to real Ghostty surfaces in the cmux app later.

## Layout

- `crates/ghostty-vt-sys` — raw FFI. build.rs compiles `libghostty-vt.a` from `../ghostty` with zig (`-Demit-lib-vt=true`, ReleaseFast) and generates bindings from `include/ghostty/vt.h` with bindgen.
- `crates/ghostty-vt` — safe wrapper: `Terminal` (vt parsing, modes, callbacks, plain-text dump), `RenderState` (dirty-tracked viewport snapshots), `KeyEncoder` (legacy + kitty keyboard protocol, synced from terminal modes).
- `crates/mux-core` — the backend: session model (`model.rs`), orchestrator (`mux.rs`), surface runtime (`surface.rs`: portable-pty, one reader thread per surface), layout math shared by frontends (`layout.rs`), and the JSON control socket (`server.rs`).
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

Keys (prefix Ctrl-b, tmux-style): `c` new tab in the active pane, `n`/`p`/`1`-`9` switch tab within the pane, `%` split right, `"` split down, `h j k l`/arrows move focus, `x` close tab (a pane collapses with its last tab), `,` rename pane, `$` rename workspace, `Tab` next screen, `S` new screen, `w` next workspace, `W` new workspace, `s` toggle the workspace sidebar, PageUp/PageDown scrollback, `d` quit, `Ctrl-b` twice sends a literal Ctrl-b.

Every pane draws a border box; the active pane's border is highlighted, the pane under the mouse gets a hover shade, and the box is where flashing notifications will hook in later. The top border doubles as an always-visible tab bar: tabs are numbered (`1`, `2`, ...; the process title follows the number when reported), clicking a title switches, the trailing `+` opens a new tab, and when tabs overflow, `‹`/`›` arrows (or the wheel over the bar) scroll them while the active tab stays visible. Drag a shared pane border to resize that split live; dragging a corner moves both intersecting splits, and outer pane edges are inert. Click anywhere in a pane to focus it. The status bar shows the active workspace's screens: click an entry to switch, the trailing `+` for a new screen; it spans only the pane region (not the sidebar), with the session label right-aligned. Right-click a pane for rename pane / new tab / split right / split down / close pane; right-click a workspace in the sidebar for rename/close; right-click a screen in the status bar for rename/close. Context menu items have a one-cell side padding and the hover/selection highlight spans the full row; right-press, drag, and release on a row activates that row. Renames use a centered prompt (Enter commits, Esc cancels; empty pane/screen names fall back to defaults); right-clicking while the prompt is open shakes it instead of opening a menu. The sidebar reserves two lines per workspace (name, then the active pane's title) under a `workspaces` header with a blank line after it and between entries; click an entry to switch, `+ new workspace` to create one, and drag the sidebar's right border to resize it for the current session.

Drag to select text; on release the selection is copied to the host clipboard via OSC 52 (works over SSH). The highlight is viewport-anchored and clears on scroll or typing. Wheel scrolls the pane under the mouse, focusing it first (arrow keys on the alternate screen). The scrollbar defaults to a dedicated column just inside the right border; `scrollbar.position = "border"` restores the old border-overlay placement. A `▕` thumb appears whenever the surface has any scrollback (hidden only when no scrolling is possible at all). Hovering or dragging the thumb renders it as `▐`; clicking the thumb anchors a drag without moving the viewport, while clicking the track outside the thumb jumps there and then drags relative to that anchor.

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
  "scrollbar": { "position": "column" },
  "keys": {
    "prefix": "ctrl+b",
    "new-tab": "c", "next-tab": "n", "prev-tab": "p",
    "split-right": "%", "split-down": "\"", "close-tab": "x",
    "rename-pane": ",", "rename-workspace": "$",
    "next-screen": "tab", "new-screen": "S",
    "next-workspace": "w", "new-workspace": "W",
    "toggle-sidebar": "s",
    "focus-left": "h", "focus-right": "l", "focus-up": "k", "focus-down": "j",
    "scroll-up": "pageup", "scroll-down": "pagedown",
    "detach": "d"
  }
}
```

Colors are `#rrggbb`, `#rgb`, or an xterm-256 index. The selection colors default to the user's Ghostty config (`selection-background`/`selection-foreground` from `~/.config/ghostty/config`), falling back to a dark grey. `sidebar_rail` controls the active workspace rail, `sidebar_active_bg` its two-row background, `tab_rail` the active tab chip rail, `tab_bg` inactive solid tab chips, and `tab_active_bg` overrides the focused/unfocused active tab chip backgrounds when set. Tabs are numbered `1 2 3…` by default; recognized agent programs (the `agents` list) surface after the number, and `show_titles` restores full process titles. `scrollbar.position` is `"column"` by default or `"border"` for the old right-border overlay. Every prefix binding is remappable via `keys` (formats: `"c"`, `"%"`, `"ctrl+b"`, `"alt+enter"`, `"tab"`, `"pageup"`); `1`-`9` stay fixed to tab selection.

## Control socket

Every instance serves a JSON-lines protocol on a unix socket (default `$TMPDIR/cmux-mux-<uid>/<session>.sock`, also exported to children as `CMUX_MUX_SOCKET`). One request per line:

```bash
SOCK=${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock
printf '%s\n' '{"id":1,"cmd":"identify"}' | nc -U "$SOCK"
printf '%s\n' '{"id":2,"cmd":"list-workspaces"}' | nc -U "$SOCK"
printf '%s\n' '{"id":3,"cmd":"send","surface":1,"text":"ls\r"}' | nc -U "$SOCK"
printf '%s\n' '{"id":4,"cmd":"read-screen","surface":1}' | nc -U "$SOCK"
```

Commands: `identify`, `list-workspaces` (each workspace carries `screens`, each with its split-tree `layout` plus `panes` with their `tabs`), `send` (text or base64 `bytes`), `read-screen`, `vt-state`, `new-tab` (in a pane), `new-screen` (in a workspace), `new-workspace`, `split` (`dir`: `right`/`down`), `set-ratio` (`pane`, `dir`: `right`/`down`, `ratio`), `close-surface`, `close-pane`, `close-screen`, `close-workspace`, `rename-pane`, `rename-screen`, `rename-workspace`, `resize-surface`, `focus-pane`, `select-tab` (within a pane), `select-screen`, `select-workspace`, `scroll-surface`, `subscribe`, `attach-surface`.

`subscribe` turns the connection full-duplex: the server pushes `{"event":...}` lines (tree-changed, surface-output, surface-exited, title-changed, bell). `attach-surface` sends a `vt-state` event carrying a base64 VT replay of the surface's complete state (screen, styles, cursor, modes, palette, kitty keyboard state, charsets — produced by ghostty's formatter), then streams every subsequent pty byte as `output` events. Replaying state then stream into a fresh terminal reproduces the surface exactly; the snapshot and stream tap are taken under the same terminal lock, so there is no gap and no duplication. This is the attach surface for the cmux app: a real Ghostty surface can adopt a tab by replaying `vt-state` and following the stream, because both sides speak the same VT engine.

## Design notes

- The pty reader thread is the only writer into a surface's `Terminal`; renderers take the terminal lock just long enough to snapshot into their own `RenderState`, so slow frontends never block pty IO.
- Query responses (DSR, DECRQM, ...) generated during parsing are queued by the write-pty callback and flushed to the pty after each parse batch.
- Input is encoded with ghostty's key encoder synced from the active surface's terminal modes each keystroke, so cursor-key application mode and the kitty keyboard protocol work end to end.
- Exited surfaces are reaped by the mux itself (tab removed, pane/workspace collapsed), so headless sessions and every frontend see the same tree without frontend-side cleanup.
- Surfaces spawn at their final render size (`new-tab`/`new-workspace`/`split` take optional `cols`/`rows`, and the TUI predicts sizes from its layout): spawning at 80x24 and resizing a frame later makes shells repaint their first prompt, which left zsh's reverse-video `%` partial-line marker on screen.
- Children get `TERM=xterm-256color` by default; set `--term xterm-ghostty` (or `CMUX_MUX_TERM`) when the ghostty terminfo is installed.

## Current limitations

- Scrollback from before an attach is not replayed (the VT replay covers the screen and state, not history); the mirror accumulates its own scrollback from the live stream.
- No mouse-event forwarding to applications (viewport scroll and alternate-screen arrow fallback only).
- Kitty graphics state is tracked by the engine but not rendered by the TUI.
- Pane split ratios are adjustable from the TUI and control socket, but not persisted across new splits.
