# Local Rust PTY Migration Plan

This plan replaces the current local macOS child-process adapter with direct Swift-to-Rust socket transport.

## Decision

Use two Unix sockets.

- App socket: Swift UI/control plane
- Rust daemon socket: terminal and tmux/amux/PTY data plane

This is already the direction of the codebase:

- app socket env is `CMUX_SOCKET_PATH` in [GhosttyTerminalView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/GhosttyTerminalView.swift#L2920)
- daemon socket env is `CMUXD_UNIX_PATH` in [Workspace.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/Workspace.swift#L5457)

## Branch target

This migration is for the branch that targets `task-move-ios-app-into-cmux-repo`.

It should not be merged by this task. "Done" here means:

- implemented in this feature branch
- tested in this feature branch
- ready to merge into `task-move-ios-app-into-cmux-repo`

## Current problem

Local macOS terminal surfaces are still provisioned by spawning a child command:

- [Workspace.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/Workspace.swift#L311)
- [Workspace.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/Workspace.swift#L5776)

That child command is:

```sh
cmuxd-remote amux new <surface-id> --socket <daemon-socket> -- <shell-command>
```

This is the part we should remove.

## Key constraint

We should not guess about Ghostty.

The good news is the embedded Ghostty API already supports manual I/O:

- [ghostty.h](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/ghostty/include/ghostty.h#L6)
- [ghostty.h](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/ghostty/include/ghostty.h#L441)
- [ghostty.h](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/ghostty/include/ghostty.h#L1102)

And iOS already uses it today:

- sets `io_mode = GHOSTTY_SURFACE_IO_MANUAL` and `io_write_cb` in [GhosttySurfaceView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/ios/Sources/Terminal/GhosttySurfaceView.swift#L898)
- feeds remote output with `ghostty_surface_process_output` in [GhosttySurfaceView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/ios/Sources/Terminal/GhosttySurfaceView.swift#L596)

macOS is still using exec mode with `command` and `working_directory`:

- [GhosttyTerminalView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/GhosttyTerminalView.swift#L3495)
- [GhosttyTerminalView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/GhosttyTerminalView.swift#L3568)

So the right plan is to port the iOS manual-I/O pattern to macOS for local Rust-backed surfaces.

## Required end state

When this migration is done:

1. Creating a local terminal surface does not spawn `cmuxd-remote amux new ...`.
2. `Cmd+N`, `cmux new-workspace`, new splits, new surfaces, restored workspaces, and any other local terminal creation path all provision through direct Rust RPC.
3. macOS terminal input goes to Rust over the daemon socket, not through a child shell command wrapper.
4. macOS terminal output comes from Rust over the daemon socket and is pushed into Ghostty with manual surface I/O.
5. resize, detach, close, EOF, and exit are handled by the direct transport.
6. `cmux pty` works and is a thin Swift forwarder to Rust.
7. the old local child-process adapter path is removed, not merely bypassed in one code path.

## Hard acceptance gates

This work is not done unless every gate below is true at the same time.

1. There is exactly one local macOS PTY transport path, direct Swift to Rust over the daemon socket.
2. No local workspace or pane creation path shells out to `cmuxd-remote amux new ...`.
3. `cmux pty` forwards to Rust and does not implement a second PTY model in Swift.
4. The same Rust session is exercised by app UI, `cmux pty`, and tmux/amux calls.
5. The old local adapter code is deleted after cutover, not left behind as a silent fallback.
6. Tagged macOS dogfood works for new workspace, split, restore, resize, type, close, EOF, and exit.
7. Automated tests cover the direct path and run in CI.
8. A tmux-ground-truth comparison suite exists for the agreed common tmux subset and passes against both real `tmux` and our Rust backend.
9. A TUI and resize suite exists and passes for the direct Rust PTY path, including `cmux pty`.
10. CI runs the tmux-ground-truth and TUI/resize suites and blocks handoff if either fails.

If any one of those is false, this migration is incomplete.

## Things that do not count as done

These are the lazy versions of the migration and should be rejected:

- adding a new direct path but leaving the old child bootstrap active for some local creation flows
- making `cmux pty` work by talking to Swift-only state instead of forwarding to Rust
- leaving Swift and Rust with separate PTY lifecycle logic for attach, read, write, resize, or exit
- proving only `Cmd+N` while splits, restore, or CLI flows still use the old path
- relying on manual spot checks without CI coverage for the new path
- keeping a hidden emergency fallback to exec-mode local startup for normal macOS terminals
- claiming tmux parity from eyeballing a terminal instead of from side-by-side assertions against real `tmux`
- testing only line-oriented shell commands while skipping fullscreen TUIs, alternate screen, and resize behavior
- comparing one happy-path pane while skipping window navigation, buffers, `wait-for`, `pipe-pane`, and respawn or kill flows
- adding parity tests that do not actually run in CI

## Implementation plan

### 1. Build a macOS manual-I/O terminal bridge

Add a macOS equivalent of the iOS `GhosttySurfaceBridge` pattern inside [GhosttyTerminalView.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/GhosttyTerminalView.swift).

It must:

- create selected surfaces with `GHOSTTY_SURFACE_IO_MANUAL`
- install `io_write_cb`
- forward outbound bytes to a Swift delegate or bridge object
- expose an API to feed inbound bytes via `ghostty_surface_process_output`
- keep existing text input behavior intact for manual surfaces

Done means:

- a macOS terminal surface can exist with no `command` and no `working_directory`
- user keystrokes still produce outbound bytes
- injected output still renders in the surface

### 2. Add a local Rust session controller in Swift

Create a dedicated Swift-side controller for local Rust-backed sessions.

It must own:

- daemon socket discovery
- `terminal.open`
- `terminal.read`
- `terminal.write`
- `session.resize`
- `session.detach`
- `session.status` or equivalent close-state polling if needed

It should reuse the direct JSON-RPC style already present in [Workspace.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/Workspace.swift#L1053), but for local daemon Unix sockets instead of the remote SSH transport wrapper.

Done means:

- one Swift object can open a Rust session for a specific `surface.id`
- one read loop continuously feeds Ghostty output
- one write path sends bytes back to Rust

### 3. Bind `surface.id` to Rust `session_id`

Keep the clean identity rule:

- local terminal `session_id == surface.id`

That is already how the current child-process path behaves in [Workspace.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/Sources/Workspace.swift#L5777).

Done means:

- any local panel can deterministically resolve its Rust session ID without lookup hacks

### 4. Replace local startup provisioning

Remove macOS local terminal startup from `LocalTerminalDaemonBridge.startupCommand(...)` for local Rust-backed surfaces.

Instead:

- create the Ghostty surface in manual mode
- call `terminal.open` directly against the Rust daemon socket
- start the Swift read loop immediately

This applies to:

- initial workspace terminal
- new terminal surface in pane
- split terminal surface
- restored local terminal surfaces

Done means:

- these code paths no longer depend on `startupCommandOverride` or shelling out to `cmuxd-remote amux new`

### 5. Wire terminal lifecycle fully

The direct bridge must handle:

- initial open
- steady-state read
- write from UI input
- resize on surface size changes
- detach on close
- EOF and exit propagation
- close cleanup if daemon dies

Done means:

- closing a pane or workspace detaches and cleans up the Rust session
- daemon EOF closes the terminal cleanly
- resizing a pane updates Rust session size

### 6. Keep app socket and Rust socket responsibilities separate

Do not tunnel PTY traffic through the app socket.

Use:

- app socket for workspace, pane, focus, browser, notifications, and UI selection
- Rust daemon socket for terminal bytes, tmux session behavior, amux behavior, and `cmux pty`

Done means:

- app socket APIs do not become a hidden PTY proxy layer

### 7. Implement `cmux pty` as a thin forwarder

Add a `cmux pty` command in [cmux.swift](/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-amux-rust-backend/CLI/cmux.swift).

It should:

- resolve target workspace, pane, surface, and daemon socket from Swift app state
- resolve `session_id`
- forward to Rust for attach, read, write, resize, and wait behavior

It must not reimplement PTY semantics locally.

Done means:

- Swift CLI becomes control-plane resolution plus forwarding
- PTY semantics live in Rust

### 8. Migrate PTY-shaped tmux compatibility behavior out of Swift

Move or forward the parts of tmux compatibility that are really terminal-session behavior:

- attach-like PTY flows
- capture and wait where Rust already owns the session state
- buffer and pipe behaviors if they depend on terminal session semantics

Do not leave split ownership where Swift has a second local tmux model for PTY features.

Done means:

- no duplicate PTY semantics in Swift for the migrated subset

### 9. Delete the old local child-process adapter

After the direct path works, remove the old local path for macOS local terminals:

- no local `sh -c "cmuxd-remote amux new ..."` startup path
- no hidden fallback for local surfaces

Remote workspace transport can remain separate if it still legitimately uses other startup semantics, but local macOS terminals should not.

Done means:

- process tree inspection during local workspace creation shows no `cmuxd-remote amux new ...` child terminal bootstrap

## Verification plan

This migration is not done because one or two commands work. It is done when the direct Rust path survives the same command and TUI workloads that people actually use, and when those checks run automatically.

### A. Real tmux as the comparison oracle

For the common tmux subset, real `tmux` should be treated as close to ground truth.

The plan is:

1. build one parity harness that can drive the same scenario against:
   - real `tmux`
   - our Rust backend through `cmuxd-remote tmux exec`
2. normalize only volatile fields:
   - UUIDs
   - generated pane or window ids
   - timestamps
   - socket paths
   - host-specific cwd prefixes where needed
3. compare the rest directly:
   - command success or failure
   - pane and window topology
   - selected pane and window
   - captured terminal text
   - buffer contents
   - wait semantics
   - resize-visible state

The suite must fail loudly on behavior drift. It should not silently accept major differences because normalization was too broad.

### B. Common tmux command matrix

These command families need explicit parity coverage against real `tmux`:

- session and window lifecycle:
  - `new-session`
  - `has-session`
  - `new-window`
  - `kill-window`
  - `rename-window`
  - `last-window`
  - `next-window`
  - `previous-window`
- pane lifecycle and navigation:
  - `split-window`
  - `select-window`
  - `select-pane`
  - `last-pane`
  - `resize-pane`
  - `kill-pane`
  - `respawn-pane`
- terminal I/O and capture:
  - `send-keys`
  - `capture-pane`
  - `display-message`
  - `pipe-pane`
- discovery:
  - `list-windows`
  - `list-panes`
  - `find-window`
- synchronization and clipboard-like behavior:
  - `wait-for`
  - `set-buffer`
  - `show-buffer`
  - `save-buffer`
  - `list-buffers`
  - `paste-buffer`

For each command family, tests should assert both:

- the immediate command result
- the resulting session state after the command

### C. TUI matrix

The direct Rust PTY path must be exercised with interactive programs, not just shell prompts.

At minimum, the suite must cover:

- shell prompt baseline:
  - prompt appears
  - commands echo and render correctly
  - scrollback capture remains sane
- fullscreen or alternate-screen behavior:
  - a real TUI if available in CI, or a repo-owned fixture TUI if not
  - enter alternate screen
  - render updates
  - exit alternate screen cleanly
- editor or pager behavior:
  - `vim -Nu NONE` or equivalent if available
  - otherwise a repo-owned minimal fullscreen editor fixture
- long-running output:
  - repeated writes
  - capture after output growth
  - no truncation or stuck offset handling
- `cmux pty` attach path:
  - attach to an existing session
  - observe prior output
  - write input through the CLI
  - detach cleanly

The plan should prefer pinned fixture TUIs in the repo where host tools are not guaranteed. We should not build a suite that only works on one developer laptop.

### D. Resize matrix

Resize needs its own coverage because it breaks terminal apps in ways simple shell tests will not catch.

The suite must cover:

- initial open size
- repeated grow and shrink cycles
- split-pane resize behavior
- `cmux pty` `SIGWINCH` propagation
- resize while a fullscreen TUI is active
- resize after detach and reattach

Assertions should include:

- terminal-reported rows and columns
- capture-pane output that reflects new wrapping
- continued TUI rendering after resize

### E. CI gates

These suites need named CI coverage, not an aspirational note.

CI should include at least:

- `remote-daemon-tmux-parity`
  - installs or uses real `tmux`
  - runs the common-command parity harness
- `remote-daemon-tui-resize`
  - runs the direct PTY, TUI, and resize matrix
- both jobs upload parity diffs, captures, and logs on failure

The tmux baseline run is part of the gate. If the baseline `tmux` run itself fails, the job should fail instead of skipping the comparison.

### F. Execution standard

There is no lazy version of this verification.

Before calling this ready to merge into `task-move-ios-app-into-cmux-repo`, we need all of these to be true:

1. the parity suite exists
2. the TUI and resize suite exists
3. both suites were executed on this branch
4. both suites passed
5. both suites run in CI and are green

If any of those are false, the work is not ready.

## Handoff gate

Do not call this ready on "mostly migrated" status.

Only call this ready to merge into `task-move-ios-app-into-cmux-repo` when all of this is true:

1. The direct manual-I/O path is the only local macOS terminal path in production code.
2. `cmux pty` is wired and verified against the live tagged app.
3. The old local child bootstrap code is removed.
4. CI includes the new direct-path coverage and is green.
5. Real `tmux` parity coverage for the agreed common subset is green.
6. TUI and resize coverage for the direct Rust path is green.
7. Manual dogfood on the tagged app passes the behavior checklist below.
8. The final status reported to the user is "ready to merge into `task-move-ios-app-into-cmux-repo`", not "merged".

## Test plan

This migration is only done if these all pass.

### Behavior tests

Verify all of these on the tagged macOS app:

- `Cmd+N`
- `cmux new-workspace`
- split terminal
- new surface in existing pane
- restored workspace from saved session
- typing, paste, resize, close
- long-running output
- EOF and exit handling

### CLI tests

Verify:

- `cmux pty ...` against a live tagged app
- tmux subset commands that rely on the same local Rust session IDs

### Negative proof

Verify process tree during local workspace creation:

- Rust daemon `serve --unix` exists
- no `cmuxd-remote amux new ...` child process is created for local terminal startup

### CI

Add or update automated coverage so CI proves:

- manual-I/O macOS surfaces still build
- local Rust daemon startup path works without child bootstrap
- `cmux pty` path works
- existing remote-daemon tests still pass

### Exit checklist

Before calling this finished, explicitly confirm all of these:

- `Cmd+N` uses direct Rust provisioning
- `cmux new-workspace` uses direct Rust provisioning
- split/new pane uses direct Rust provisioning
- restored local workspaces use direct Rust provisioning
- `cmux pty` uses the same Rust session path
- no local child bootstrap remains in code or process tree
- CI is green on the new path

## Non-goals for the first migration

These are not excuses to leave the local path half-done. They are simply outside this specific migration:

- replacing the app socket with the Rust socket
- rewriting browser or notification flows to Rust
- changing remote SSH workspace transport unless needed by shared abstractions

## Acceptance rule

Do not call this finished until:

- the local child-process bootstrap is gone
- the direct Swift-to-Rust PTY path is the only local macOS terminal path
- `cmux pty` works
- app creation flows and CLI flows are tested end to end
