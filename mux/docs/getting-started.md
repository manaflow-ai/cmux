# Getting started

## Prerequisites

Builds need zig 0.15.2, a Rust toolchain, and the `ghostty` submodule. The Ghostty VT FFI crate builds `libghostty-vt.a` from that submodule, so an uninitialized submodule fails before the TUI starts.

```bash
cd mux
cargo run -p mux-tui
```

By default this starts session `main`, opens the TUI, and serves a control socket.

## Local session

A local run owns an in-process mux. Quitting the TUI shuts the session down and removes the socket.

```bash
cd mux
cargo run -p mux-tui -- --session main
```

Use `--term <value>` to set `TERM` for child shells. Without it, children get `xterm-256color`.

## Headless server and attach

Headless mode starts only the mux backend and its control socket.

```bash
cd mux
cargo run -p mux-tui -- --headless --session agents
```

Attach a TUI to the same session from another terminal:

```bash
cd mux
cargo run -p mux-tui -- attach --session agents
```

Detach from an attached TUI with prefix `d`. The server keeps running, and another `attach` reconnects to the same tree. PTY tabs attach with a Ghostty VT-state replay followed by a live output stream.

## Sessions and sockets

The default socket path is:

```text
$TMPDIR/cmux-mux-<uid>/<session>.sock
```

The default session name is `main`, so the usual path is `${TMPDIR:-/tmp}/cmux-mux-$(id -u)/main.sock`. Use `--socket <path>` to choose an explicit socket path. Server-started child processes receive `CMUX_MUX_SOCKET` with the socket path.

## Development flow

Run tests from `mux/`:

```bash
cargo test
```

This branch does not contain `scripts/mux-dev.sh`; use the `cargo run -p mux-tui` commands above for local, headless, and attach workflows.
