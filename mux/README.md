# cmux-mux

`cmux-mux` is the Rust TUI multiplexer in this repository. It keeps a tmux-style tree of workspaces, screens, split panes, and tabs, uses Ghostty's VT engine for PTY state, and exposes the same state over a JSON-lines control socket for attach clients and other frontends.

## Documentation

- [Docs index](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Concepts](docs/concepts.md)
- [Keyboard](docs/keyboard.md)
- [Mouse](docs/mouse.md)
- [Configuration](docs/configuration.md)
- [Control socket protocol](docs/protocol.md)
- [Browser panes](docs/browser-panes.md)

## Build

Builds need zig 0.15.2, a Rust toolchain, and the `ghostty` submodule initialized. The `ghostty-vt-sys` crate builds `libghostty-vt.a` from the submodule with zig before compiling the Rust crates.

```bash
cd mux
cargo build -p mux-tui
```

## Run

```bash
cd mux
cargo run -p mux-tui
cargo run -p mux-tui -- --session agents
cargo run -p mux-tui -- --headless --session agents
cargo run -p mux-tui -- attach --session agents
```

The default session is `main`. Default sockets live at `$TMPDIR/cmux-mux-<uid>/<session>.sock`; use `--socket <path>` for an explicit path. Detach from an attached TUI with prefix `d`, which is `Ctrl-b d` by default.

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; `CMUX_MUX_TERM` can override the process default in the surface layer.

## Browser Realism

By default, browser panes launch your real Google Chrome or another Chrome-family binary in `browser.mode: "headful"` with a visible window and a persistent per-session profile. Log into Google or other sites once in that visible window; cookies and logins persist across sessions. Set `browser.mode: "headless"` to hide the launched Chrome window. Both modes keep the anti-throttle flags, `--disable-blink-features=AutomationControlled`, the persistent `--user-data-dir`, and `about:blank` startup.

Chrome 136 and newer reject CDP remote debugging on the OS-default profile directory, and a running normal Chrome owns its profile `SingletonLock`. Use the mux profile, set `browser.user_data_dir` to a copy or a dedicated directory after quitting normal Chrome, or attach to a Chrome you started with `--remote-debugging-port`.

To attach instead of launching, set `browser.cdp_url`, `CMUX_MUX_CDP_URL`, or enable discovery. Agent Browser works the same way: run `agent-browser get cdp-url` and use the returned `ws://` URL. This build supports `ws://` and `http://` CDP endpoints; `wss://` is not supported.

## Development

```bash
cd mux
cargo test
```

The smoke scripts expect a built `cmux-mux` binary unless `CMUX_MUX_BIN` is set.

```bash
cd mux
cargo build -p mux-tui
python3 scripts/smoke-tui.py
python3 scripts/smoke-attach.py
```
