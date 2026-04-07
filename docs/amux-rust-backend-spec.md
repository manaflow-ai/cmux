# AMux Rust Backend Spec

Last updated: April 5, 2026
Base branch: `task-move-ios-app-into-cmux-repo`

## Goal

Replace the current backend in this branch with a Rust daemon at `daemon/remote/rust`.

The Rust daemon must:
- preserve the current cmux JSON-RPC surface used by the app
- add `amux`-style capture, event, and wait primitives
- add a practical tmux compatibility layer for the approved common command subset
- build against the worktree Ghostty source via `GHOSTTY_SOURCE_DIR`

## Inputs Used For The Rewrite

- Current backend and transport code in `task-move-ios-app-into-cmux-repo`
- Existing tmux compatibility behavior in [`CLI/cmux.swift`](../CLI/cmux.swift)
- `weill-labs/amux` for the capture/events/wait model
- `libghostty-rs` as a design reference only

`libghostty-rs` was reviewed, but v1 keeps the daemon on a direct Ghostty shim built from `GHOSTTY_SOURCE_DIR` instead of switching the runtime to that wrapper.

## Explicit Non-Goals

- tmux control mode
- full tmux parity
- every tmux option, format variable, hook, or command
- exact tmux layout semantics

## Required Build Contract

- `daemon/remote/rust/build.rs` must fail clearly if `GHOSTTY_SOURCE_DIR` is missing or wrong
- the Ghostty shim must be built against the same macOS deployment target as Cargo
- the daemon must stay runnable in local debug builds

## JSON-RPC Surface

### Existing cmux RPC that must stay

- `hello`
- `ping`
- `proxy.open`
- `proxy.close`
- `proxy.write`
- `proxy.read`
- `session.open`
- `session.close`
- `session.attach`
- `session.resize`
- `session.detach`
- `session.status`
- `session.list`
- `session.history`
- `terminal.open`
- `terminal.read`
- `terminal.write`

### New or expanded amux RPC

#### `amux.capture`

Input:
- `session_id` or `pane_id`
- `history` optional bool, default `true`

Output:
- `pane_id`
- `session_id`
- `capture.cols`
- `capture.rows`
- `capture.cursor_x`
- `capture.cursor_y`
- `capture.history`
- `capture.visible`
- `closed`
- `offset`
- `base_offset`

#### `amux.events.read`

Input:
- `cursor`
- `timeout_ms`
- `filters` optional array of kinds
- `session_id` optional
- `pane_id` optional

Output:
- `cursor` for the next read
- `events[]`

Event kinds required in v1:
- `session.open`
- `session.close`
- `session.attach`
- `session.resize`
- `session.detach`
- `window.open`
- `window.close`
- `pane.open`
- `pane.close`
- `pane.output`
- `busy`
- `idle`
- `exited`

#### `amux.wait`

Input:
- `kind`
- `session_id` or `pane_id`
- `timeout_ms`

Additional input by kind:
- `signal`: `name`, optional `after_generation`
- `content`: `needle`

Supported wait kinds in v1:
- `signal`
- `content`
- `busy`
- `idle`
- `ready`
- `exited`

Output:
- `signal`: `{ "name", "generation" }`
- `content`: `{ "matched": true }`
- `busy`: `{ "busy": true }`
- `idle`: `{ "idle": true }`
- `ready`: `{ "ready": true }`
- `exited`: `{ "exited": true }`

## tmux Compatibility

### Transport

Expose tmux compatibility as:
- `tmux.exec`

Input:
- `{ "argv": ["command", "...args"] }`

Output:
- `stdout`
- command-specific fields when useful, such as `session_id`, `window_id`, `pane_id`, `buffer`, `path`, `cols`, `rows`, `generation`

### Supported tmux commands for v1

- `new-session`
- `new-window`
- `split-window`
- `select-window`
- `select-pane`
- `kill-window`
- `kill-pane`
- `send-keys`
- `capture-pane`
- `display-message`
- `list-windows`
- `list-panes`
- `rename-window`
- `resize-pane`
- `wait-for`
- `last-pane`
- `last-window`
- `next-window`
- `previous-window`
- `has-session`
- `set-buffer`
- `show-buffer`
- `save-buffer`
- `list-buffers`
- `paste-buffer`
- `pipe-pane`
- `find-window`
- `respawn-pane`

The older cmux subset from `CLI/cmux.swift` must remain included inside this list.

### Target Syntax Required In v1

- session id: `name` or `$name`
- window target: `session:window`, `@window-id`, bare window index
- pane target: `session:window.pane`, `%pane-id`, bare pane index in the active window
- commands that accept pane targets must also accept a window target and use that window's active pane

### Format Variables Required In v1

- `#{session_name}`
- `#{session_id}`
- `#{window_id}`
- `#{window_name}`
- `#{window_index}`
- `#{window_active}`
- `#{pane_id}`
- `#{pane_index}`
- `#{pane_active}`
- `#{pane_title}`
- `#{pane_current_path}`
- `#{pane_current_command}`

### Behavioral Notes

- `wait-for` is implemented as named signal generation tracking, not tmux control mode
- `capture-pane -p` prints captured text, otherwise stores the text in the default buffer
- `set-buffer` and `paste-buffer` operate on daemon-owned buffers
- `pipe-pane` runs a shell command and pipes the current pane capture to stdin, so it is only safe for trusted callers
- `resize-pane` is direct PTY resizing, not a real tmux layout engine
- `respawn-pane` recreates the pane process in place

## Acceptance For V1

V1 is acceptable when all of the following are true:

1. `cargo build` succeeds with `GHOSTTY_SOURCE_DIR` pointed at the worktree Ghostty checkout.
2. The daemon serves over a Unix socket and the existing cmux RPC surface still works.
3. `amux.capture`, `amux.events.read`, and `amux.wait` work for real panes.
4. The approved tmux command subset works through `tmux.exec`.
5. Common commands are validated against a live PTY smoke run, not only compile-time checks.
