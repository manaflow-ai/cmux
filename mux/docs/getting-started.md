# Getting started

## Prerequisites

Builds need zig 0.15.2, a Rust toolchain, and the `ghostty` submodule. `ghostty-vt-sys` compiles `libghostty-vt.a` from that submodule, so an uninitialized submodule fails before the TUI starts.

```bash
cd mux
cargo build -p mux-tui
```

## Local session

A normal run starts an in-process mux, opens the TUI, and serves the control socket.

```bash
cd mux
cargo run -p mux-tui
cargo run -p mux-tui -- --session agents
```

The default session is `main`. Quitting a local TUI shuts down that in-process session and removes its socket.

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; the surface layer also honors `CMUX_MUX_TERM` when no CLI value is supplied.

## Headless server and attach

Headless mode starts only the mux backend and control socket.

```bash
cd mux
cargo run -p mux-tui -- --headless --session agents
```

Attach a TUI to that session from another terminal.

```bash
cd mux
cargo run -p mux-tui -- attach --session agents
```

Detach from an attached TUI with prefix `d`. With default keys, that is `Ctrl-b d`. The server keeps running, and another `attach` reconnects to the same tree. PTY tabs attach with a Ghostty VT-state replay followed by a live output stream.

## Sessions and sockets

The default socket path is:

```text
$TMPDIR/cmux-mux-<uid>/<session>.sock
```

The usual default is `$XDG_RUNTIME_DIR/cmux-mux-<uid>/main.sock` when `XDG_RUNTIME_DIR` is set, then `$TMPDIR/cmux-mux-<uid>/main.sock`, then `/tmp/cmux-mux-<uid>/main.sock`. `--session <name>` changes the final file name. `--socket <path>` bypasses the session-derived path. Server-started child processes receive `CMUX_MUX_SOCKET` with the socket path.

## Platforms and XDG

cmux-mux supports macOS and Linux; Windows support via ConPTY is planned for phase 2. The TUI config path resolves `CMUX_MUX_CONFIG`, then `$XDG_CONFIG_HOME/cmux/mux.json`, then `~/.config/cmux/mux.json`.

Launched Chrome profile paths are platform-specific. On macOS the default is `~/Library/Application Support/cmux-mux/chrome-profile`. On Linux and other non-macOS targets, `XDG_DATA_HOME` is used when set, then `~/.local/share/cmux-mux/chrome-profile`.

## Development flow

Run tests from `mux/`.

```bash
cargo test
```

Run the smoke scripts against a built binary. Set `CMUX_MUX_BIN` to test a non-default binary.

```bash
cargo build -p mux-tui
python3 scripts/smoke-tui.py
python3 scripts/smoke-attach.py
```

This checkout does not contain `scripts/mux-dev.sh`; use the cargo and smoke commands above for the TUI flow.
