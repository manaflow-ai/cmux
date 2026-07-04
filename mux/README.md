# cmux-mux

`cmux-mux` is a tmux-style terminal multiplexer for cmux. The backend owns sessions, workspaces, screens, split panes, and tabs, while PTY surfaces are parsed by Ghostty's VT engine and rendered by the bundled Ratatui TUI. Browser panes are local Chrome/Chromium pages driven through CDP and drawn with kitty graphics when the host terminal supports it.

## Documentation

- [Getting started](docs/getting-started.md)
- [Concepts](docs/concepts.md)
- [Keyboard](docs/keyboard.md)
- [Mouse](docs/mouse.md)
- [Configuration](docs/configuration.md)
- [Control socket protocol](docs/protocol.md)
- [Browser panes](docs/browser-panes.md)

## Layout

- `crates/ghostty-vt-sys` is the raw Ghostty VT FFI. Its build script compiles `libghostty-vt.a` from the `ghostty` submodule with zig and generates bindings from `include/ghostty/vt.h`.
- `crates/ghostty-vt` is the safe Rust wrapper around terminal parsing, render snapshots, VT replay, palette state, and Ghostty key encoding.
- `crates/mux-cdp` contains the synchronous CDP transport and Chrome lifecycle helpers for browser panes.
- `crates/mux-core` is the backend session model, surface runtime, shared layout math, browser runtime, and JSON control socket.
- `crates/mux-tui` builds the `cmux-mux` binary with crossterm, Ratatui, config loading, local sessions, and attach clients.

## Build and run

Requires zig 0.15.2, a Rust toolchain, and an initialized `ghostty` submodule.

```bash
cd mux
cargo run -p mux-tui
cargo run -p mux-tui -- --headless --session agents
cargo run -p mux-tui -- attach --session agents
cargo test
```

Use `--term <value>` or `CMUX_MUX_TERM` for child shells when the default `xterm-256color` is not what you want.

## Smoke checks

Every running server exposes a JSON-lines Unix socket. The default path is `$TMPDIR/cmux-mux-<uid>/<session>.sock`.

```bash
SOCK="${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock"
printf '%s\n' '{"id":1,"cmd":"identify"}' | nc -U "$SOCK"
printf '%s\n' '{"id":2,"cmd":"list-workspaces"}' | nc -U "$SOCK"
printf '%s\n' '{"id":3,"cmd":"new-tab"}' | nc -U "$SOCK"
```

Detach an attached TUI with prefix `d`; the headless server keeps the session alive. A local non-attach TUI owns its in-process session and shuts it down when it exits.
