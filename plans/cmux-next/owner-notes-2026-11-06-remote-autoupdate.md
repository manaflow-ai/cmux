# Owner notes, 2026-11-06: remote cmux auto-update, macOS clippy, Zig pin

Written by a Chief subagent. The pre-push gate asked to notify the owners below. Their
sessions (cmux-b6, cmux-1c) could not be reached, so the notes are here. Read them, then
delete this file or move the parts you keep into your own plan.

## PL-daemon (cmux-tui-core, session cmux-b6)

Changes in your crates (all on feat-cmux-next):

- `cmux-tui/crates/cmux-tui-core/src/remote_host/macos.rs`:
  - `Staged` lost its unread `app` field.
  - `std::mem::size_of` became `size_of` (prelude).
- `cmux-tui/crates/cmux-tui-core/src/remote_host/unix.rs`: `bundle_digest: staged.digest`
  (no clone).
- Why: macOS clippy (`-D warnings`) failed on dead code and a redundant clone. Commit
  754010d9ff2e7.
- Related behavior (cmux-tui crate, commits 87634fb..263bb0f):
  - The static install `~/.cmux/bin/cmux` gets a newer build as `cmux.staged`.
  - The session server swaps it in at its next start (`staged_update.rs`). A live server is
    never stopped.
  - The TUI shows a stale-build notice.
  - The Mac app stages on connect (`RemoteStaticInstallStager`) and shows the notice in the
    machine header.

## PL-holder (cmux-process, session cmux-1c)

- `cmux-tui/crates/cmux-process/src/spawn_apple.rs`: `type Disclaim` and
  `fn disclaim_function()` moved above `#[cfg(test)] mod daemon_spawn`, so the test module is
  last. No behavior change. Commit 754010d9ff2e7.
- `cmux-tui/src/staged_update.rs` runs the promoted build through `cmux_process::Command` and
  `cmux_process::Stdio`. The raw-spawn guard refused `std::process::Command` and `libc::execv`.

## Also touched, no owner row

- acpmux `chats/activity.rs` scale tests and `hub/peer_snapshot.rs` `thread_allocations`
  re-export: now Linux only (`#[cfg(all(test, target_os = "linux"))]`). They were dead code
  on macOS.

## Fleet owner: Zig on the glaeda macOS runners

- Symptom: on 2026-11-06 the job "macOS lint and tests" of
  [run 42213655767](https://github.com/manaflow-ai/cmux/actions/runs/42213655767), attempt 1
  on `cmuxs-mac-mini-5-glaeda-5`, failed before clippy. The error was "Your Zig version
  v0.16.0 does not meet the required build version of v0.17.0" (ghostty-vt-sys build.rs).
- Cause:
  - `scripts/install-zig-ci.sh` installed the pinned 0.17 and published `CMUX_ZIG`.
  - `ghostty-vt-sys/build.rs` read only `ZIG`, then `zig` on PATH.
  - `setup-cmux-tui-rust` adds `~/.cargo/bin` to PATH after the pin, and on these hosts
    `~/.cargo/bin/zig` is a symlink to Zig 0.16.
- Read-only check, 2026-11-06:
  - `cmuxs-mac-mini-5` and `cmux-mini-4`: `~/.cargo/bin/zig` -> `~/.local/lib/zig-aarch64-macos-0.16.0/zig`.
  - `cmux9s-mac-mini`: `~/.local/bin/zig` -> 0.16.
  - All three: Homebrew zig 0.16.0 and `/usr/local/bin/zig` 0.15.2.
- Code fix (on feat-cmux-next): build.rs now runs `ZIG`, else `CMUX_ZIG`, else `zig` on PATH.
  The pin wins on these runners.
- Hosts not changed: other jobs (classic Ghostty) can need an older Zig.
- Fleet owner, decide one of these:
  - Remove the `zig` symlink from `~/.cargo/bin` on the runner user's hosts. A Zig there
    shadows every pinned Zig.
  - Keep the symlink, because the code fix is sufficient.
