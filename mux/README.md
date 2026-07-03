# cmux-mux

A decoupled terminal-multiplexer backend for cmux, with a bundled tmux-like TUI. The multiplexer core owns workspaces → tabs → panes; each pane is a real PTY whose output feeds libghostty-vt, the terminal engine extracted from Ghostty and built from this repo's `ghostty/` submodule. Frontends only read render snapshots and send input, so the same session state can be drawn by the Ratatui TUI in any terminal today and attached to real Ghostty surfaces in the cmux app later.

## Layout

- `crates/ghostty-vt-sys` — raw FFI. build.rs compiles `libghostty-vt.a` from `../ghostty` with zig (`-Demit-lib-vt=true`, ReleaseFast) and generates bindings from `include/ghostty/vt.h` with bindgen.
- `crates/ghostty-vt` — safe wrapper: `Terminal` (vt parsing, modes, callbacks, plain-text dump), `RenderState` (dirty-tracked viewport snapshots), `KeyEncoder` (legacy + kitty keyboard protocol, synced from terminal modes).
- `crates/mux-core` — the backend: session model, PTY runtime (portable-pty, one reader thread per pane), layout math shared by frontends, and the JSON control socket.
- `crates/mux-tui` — the `cmux-mux` binary: crossterm + Ratatui frontend.

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

Keys (prefix Ctrl-b, tmux-style): `c` new tab, `n`/`p`/`1`-`9` switch tab, `%` split right, `"` split down, `h j k l`/arrows move focus, `x` kill pane, `w` next workspace, `W` new workspace, `s` toggle the workspace sidebar, PageUp/PageDown scrollback, `d` quit, `Ctrl-b` twice sends a literal Ctrl-b. Mouse: click focuses panes, click a sidebar entry to switch workspaces (or `+ new workspace` to create one), wheel scrolls (arrow keys on the alternate screen).

## Control socket

Every instance serves a JSON-lines protocol on a unix socket (default `$TMPDIR/cmux-mux-<uid>/<session>.sock`, also exported to panes as `CMUX_MUX_SOCKET`). One request per line:

```bash
SOCK=${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock
printf '%s\n' '{"id":1,"cmd":"identify"}' | nc -U "$SOCK"
printf '%s\n' '{"id":2,"cmd":"list-workspaces"}' | nc -U "$SOCK"
printf '%s\n' '{"id":3,"cmd":"send","pane":1,"text":"ls\r"}' | nc -U "$SOCK"
printf '%s\n' '{"id":4,"cmd":"read-screen","pane":1}' | nc -U "$SOCK"
```

Commands: `identify`, `list-workspaces` (includes each tab's split-tree `layout`), `send` (text or base64 `bytes`), `read-screen`, `vt-state`, `new-tab`, `new-workspace`, `split` (`dir`: `right`/`down`), `kill-pane`, `resize-pane`, `focus-pane`, `select-tab`, `select-workspace`, `scroll-pane`, `subscribe`, `attach-pane`.

`subscribe` turns the connection full-duplex: the server pushes `{"event":...}` lines (tree-changed, pane-output, pane-exited, title-changed, bell). `attach-pane` sends a `vt-state` event carrying a base64 VT replay of the pane's complete state (screen, styles, cursor, modes, palette, kitty keyboard state, charsets — produced by ghostty's formatter), then streams every subsequent pty byte as `output` events. Replaying state then stream into a fresh terminal reproduces the pane exactly; the snapshot and stream tap are taken under the same terminal lock, so there is no gap and no duplication. This is the attach surface for the cmux app: a real Ghostty surface can adopt a pane by replaying `vt-state` and following the stream, because both sides speak the same VT engine.

## Design notes

- The pty reader thread is the only writer into a pane's `Terminal`; renderers take the terminal lock just long enough to snapshot into their own `RenderState`, so slow frontends never block pty IO.
- Query responses (DSR, DECRQM, ...) generated during parsing are queued by the write-pty callback and flushed to the pty after each parse batch.
- Input is encoded with ghostty's key encoder synced from the pane's terminal modes each keystroke, so cursor-key application mode and the kitty keyboard protocol work end to end.
- Children get `TERM=xterm-256color` by default; set `--term xterm-ghostty` (or `CMUX_MUX_TERM`) when the ghostty terminfo is installed.

## Current limitations

- Scrollback from before an attach is not replayed (the VT replay covers the screen and state, not history); the mirror accumulates its own scrollback from the live stream.
- No mouse-event forwarding to applications (viewport scroll and alternate-screen arrow fallback only).
- Kitty graphics state is tracked by the engine but not rendered by the TUI.
- Split ratios are fixed at 50% (no interactive divider drag yet).
