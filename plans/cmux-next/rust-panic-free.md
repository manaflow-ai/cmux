# Rust panic freedom (cmux-tui workspace)

Owner: the panic-free lane (Lawrence, 2026-10-21: "fix all rust issues from
first principles such that no crashes can ever occur"). This page extends
section 6 of [crash-elimination.md](crash-elimination.md) and replaces its
"Workspace lints" step with the ratchet below.

Goal: a long-running cmux process (the cmux-tui owner and its headless
service, the terminal hosts, the acpmux daemon and its agent hosts) never
ends or hangs because of a Rust panic, and a crash that still happens (abort,
stack overflow, out of memory, a signal) never loses user state.

## 1. Rules (decided)

1. Production code cannot panic by construction. No `unwrap`, `expect`,
   `panic!`, `unreachable!`, `todo!`, `unimplemented!`, no slice or `str`
   indexing (`get`, `get(a..b)`, `split_first`, `char_indices`,
   `strip_prefix`, `split_once`), no poisoned-lock panics
   (`lock().unwrap_or_else(PoisonError::into_inner)`), no `RefCell`
   double borrow. A failure is a typed `Result` handled at a boundary that
   logs it and keeps serving.
   Known gaps of the lint set (no clippy lint; reviewers and the fuzz
   targets cover them): `assert!`/`assert_eq!` outside `Result` functions,
   `copy_from_slice`, `split_at`, `Vec::remove`/`insert`/`drain(range)`,
   `RefCell` double borrow, `Duration` subtraction, and `/` or `%` by zero
   (tracked by `arithmetic_side_effects`, which only warns).
2. A reviewed exception is `#[allow(clippy::<lint>, reason = "...")]` on the
   smallest item, for an invariant the item proves locally (a const regex, an
   FFI contract). An allow without `reason` fails the ratchet. Use `allow`,
   not `expect`: the plain `clippy -D warnings` run does not enable these
   lints, so an `expect` there is unfulfilled.
3. The compiler enforces it (section 3); counts only go down.
4. What can still unwind (third-party code, a missed path) is contained by a
   supervisor at every task and connection boundary (section 5).
5. What cannot unwind (abort, stack overflow, out of memory, SIGKILL) ends the
   process fast; the process supervisor restarts it, and the state comes back
   from the journal and the output store (crash-only design, section 6).
6. Every parser that sees outside bytes has a fuzz target (section 7).

## 2. Inventory (before, feat-cmux-next 7c48cdf2c40e, 2026-10-22)

The baseline file is measured at the landing's merged head (65a4003019ad):
6623 deny hits. In between, core-socket landed (cmux-tui-core 3199 -> 2337),
protocol crates part 1 landed (4 crates to 0), and other lanes added about
120 hits (mostly cmux-tui `app/` indexing; new crate cmux-weft starts with 4). The
table below is the first measurement.

Compiler-accurate: `cargo clippy --workspace --lib --bins` on rbx (Linux),
production targets only, build scripts excluded, one count per source
location. `index` is `indexing_slicing`; `deny total` is the sum of the lints
that must reach 0. The lints `todo`, `unimplemented` and
`panic_in_result_fn` have 0 hits everywhere. 68 crates; 12 are at 0 already.

Not counted: macOS- and Windows-only code (`cfg(target_os)`; the CI ratchet
runs on Linux), and the crates outside the workspace (`cmux-rd-host`,
`cmux-rd-ffi`, `cmux-layout-reducer-ffi`; their FFI entry points already wrap
every call in `catch_unwind`).

| crate | unwrap | expect | panic+unreachable | index | str slice | deny total | arith (tracked) | cast trunc (tracked) | top files (deny+tracked hits) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| cmux-tui-core | 1434 | 267 | 38 | 1405 | 55 | 3199 | 867 | 91 | src/terminal_host_protocol.rs 51, src/terminal_host.rs 47, src/server/loopback_forward.rs 44 |
| cmux-tui | 354 | 70 | 31 | 965 | 82 | 1502 | 1104 | 133 | src/ui/overlay.rs 137, src/ui/graphics.rs 81, src/session/remote.rs 70 |
| acpmux | 192 | 24 | 4 | 787 | 99 | 1106 | 970 | 110 | src/tui/render/mod.rs 89, src/tui/render/transcript.rs 61, src/stats.rs 57 |
| cmux-remote | 25 | 57 | 10 | 154 | 11 | 257 | 114 | 11 | src/workspace/codex_patch.rs 51, src/link.rs 35, src/session.rs 30 |
| cmux-browser-host | 0 | 1 | 0 | 209 | 14 | 224 | 155 | 38 | src/secrets.rs 48, src/cdp/evaluate.rs 27, src/gate/fetch.rs 26 |
| chatmux-relay | 7 | 80 | 1 | 56 | 5 | 149 | 75 | 9 | src/pty.rs 54, src/workspace.rs 36, src/actions.rs 24 |
| ghostty-vt | 0 | 0 | 0 | 103 | 1 | 104 | 115 | 15 | src/terminal.rs 52, src/snapshot.rs 28, src/key.rs 26 |
| cmux-wg | 0 | 15 | 0 | 68 | 1 | 84 | 77 | 9 | src/pacing.rs 59, src/udp.rs 30, src/tcp_bridge.rs 15 |
| cmux-host | 0 | 0 | 0 | 81 | 1 | 82 | 60 | 16 | src/cloud/role.rs 28, src/cloud/client.rs 18, src/team_ssh/b64.rs 14 |
| cmux-layout-reducer | 0 | 0 | 0 | 69 | 7 | 76 | 56 | 5 | src/sidebar_doc/order_key.rs 27, src/sidebar_layout.rs 23, src/rows.rs 22 |
| cmux-palette-ranker | 0 | 0 | 0 | 58 | 0 | 58 | 46 | 1 | src/tier.rs 79, src/rank.rs 19, src/text.rs 4 |
| cmux-tui-cloud-conversations | 0 | 0 | 0 | 52 | 0 | 52 | 19 | 1 | src/host_replica.rs 27, src/service.rs 20, src/host_replica/ops.rs 10 |
| cmux-terminal-client | 30 | 1 | 0 | 18 | 0 | 49 | 2 | 0 | src/lib.rs 51 |
| cmux-config | 0 | 2 | 0 | 40 | 4 | 46 | 90 | 3 | src/jsonc/lex.rs 48, src/jsonc/array.rs 22, src/keybindings/bare.rs 16 |
| cmux-transport | 0 | 0 | 0 | 45 | 0 | 45 | 10 | 0 | src/stun.rs 25, src/relay_frame.rs 11, src/classify.rs 9 |
| cmux-server | 0 | 0 | 0 | 41 | 2 | 43 | 41 | 2 | src/keys.rs 32, src/pg/backup.rs 12, src/health/probe.rs 6 |
| cmux-chat-index | 0 | 0 | 0 | 32 | 10 | 42 | 65 | 6 | src/time.rs 21, src/adapters/kimi.rs 17, src/lines.rs 16 |
| cmux-tasks-core | 0 | 0 | 0 | 37 | 2 | 39 | 27 | 0 | src/sort_key.rs 30, src/reduce/tasks.rs 17, src/invariants.rs 4 |
| cmux-pane-protocol | 0 | 0 | 0 | 36 | 1 | 37 | 27 | 6 | src/vectors.rs 20, src/frame.rs 17, src/stream.rs 9 |
| cmux-rd-core | 0 | 0 | 0 | 34 | 0 | 34 | 51 | 17 | src/fec.rs 44, src/upstream.rs 12, src/packetize.rs 9 |
| cmux-api-compat | 0 | 0 | 0 | 32 | 2 | 34 | 30 | 0 | src/stream.rs 35, src/change.rs 13, src/trie.rs 7 |
| cmux-theme-tokens | 0 | 0 | 0 | 31 | 1 | 32 | 21 | 2 | src/app_theme.rs 28, src/spec.rs 18, src/colors.rs 3 |
| cmux-mux2 | 0 | 11 | 0 | 18 | 0 | 29 | 25 | 3 | src/lib.rs 23, src/bin/mux2-verify.rs 15, src/bin/mux2-wrapcheck.rs 14 |
| cmux-server-core | 0 | 0 | 0 | 26 | 0 | 26 | 29 | 5 | src/pairing/base32.rs 8, src/manifest/time.rs 7, src/pairing/enrollment.rs 7 |
| cmux-tui-util | 12 | 1 | 0 | 7 | 5 | 25 | 21 | 4 | src/user_settings.rs 27, src/stream_interrupt.rs 13, src/short_id.rs 5 |
| cmux-tui-image-paste | 22 | 0 | 0 | 0 | 0 | 22 | 11 | 1 | src/image_paste.rs 21, src/image_paste_file.rs 10, src/image_paste_ownership.rs 1 |
| cmux-rd-proto | 0 | 0 | 0 | 22 | 0 | 22 | 11 | 7 | src/stream.rs 13, src/error.rs 9, src/input.rs 9 |
| cmux-tui-platform | 14 | 0 | 0 | 4 | 1 | 19 | 10 | 4 | src/unix_process_scope.rs 22, src/platform.rs 4, src/process_resources.rs 3 |
| cmux-agent-pane-policy | 0 | 0 | 0 | 19 | 0 | 19 | 30 | 1 | src/json_keys.rs 49, src/frame.rs 1 |
| cmux-tui-hooks | 0 | 9 | 0 | 6 | 0 | 15 | 4 | 1 | src/lib.rs 20 |
| cmux-tui-cdp | 0 | 0 | 0 | 14 | 1 | 15 | 8 | 1 | src/client.rs 24 |
| cmux-encode | 0 | 0 | 0 | 14 | 0 | 14 | 25 | 3 | src/picture.rs 42 |
| bindings-rust | 0 | 3 | 3 | 7 | 1 | 14 | 7 | 5 | bindings/rust/src/codec.rs 7, bindings/rust/src/resource/client.rs 4, bindings/rust/src/resource/stream.rs 4 |
| cmux-terminal-sizing | 0 | 6 | 0 | 6 | 0 | 12 | 3 | 0 | src/lib.rs 15 |
| cmux-conversation | 0 | 0 | 0 | 10 | 2 | 12 | 29 | 1 | src/budget.rs 12, src/id.rs 12, src/search.rs 8 |
| cmux-remote-protocol | 0 | 0 | 0 | 11 | 0 | 11 | 6 | 1 | src/frame.rs 18 |
| cmux-focus-core | 0 | 0 | 0 | 11 | 0 | 11 | 2 | 0 | src/close_focus.rs 10, src/topology.rs 3 |
| cmux-remote-transcript | 0 | 0 | 0 | 10 | 0 | 10 | 14 | 3 | src/transcript.rs 27 |
| cmux-tasks | 0 | 0 | 0 | 9 | 0 | 9 | 17 | 3 | src/cli/mod.rs 9, src/store/segment.rs 7, src/store/mod.rs 4 |
| cmux-motion | 0 | 0 | 0 | 9 | 0 | 9 | 3 | 11 | src/spring.rs 6, src/tokens.rs 5, src/color.rs 4 |
| cmux-chief | 0 | 0 | 0 | 8 | 1 | 9 | 34 | 5 | src/memory.rs 26, src/core/children.rs 4, src/core/mod.rs 4 |
| cmux-tui-remote-access | 5 | 1 | 0 | 0 | 2 | 8 | 3 | 0 | src/pairing.rs 11 |
| cmux-git | 0 | 0 | 0 | 8 | 0 | 8 | 9 | 0 | src/parse.rs 6, src/run.rs 4, src/repository.rs 3 |
| cmux-worktree-care | 0 | 0 | 0 | 5 | 2 | 7 | 13 | 0 | src/inventory.rs 5, src/archive.rs 4, src/pass.rs 4 |
| cmux-local-auth | 0 | 2 | 0 | 4 | 1 | 7 | 7 | 0 | src/frontend_proof.rs 12, src/lib.rs 2 |
| cmux-pty | 0 | 0 | 0 | 5 | 0 | 5 | 4 | 1 | src/macos.rs 9, src/open_files.rs 1 |
| cmux-link | 0 | 0 | 0 | 4 | 0 | 4 | 4 | 2 | src/keyset.rs 5, src/caller.rs 2, src/owner_session.rs 2 |
| cmux-app-host | 0 | 1 | 0 | 3 | 0 | 4 | 11 | 13 | src/vm.rs 17, src/sandbox/linux.rs 7, src/script/session.rs 3 |
| bindings-rust-sidebar | 0 | 1 | 0 | 2 | 1 | 4 | 5 | 1 | bindings/rust-sidebar/src/lib.rs 10 |
| cmux-app-manifest | 0 | 0 | 0 | 3 | 0 | 3 | 0 | 0 | src/cli.rs 2, src/scopes.rs 1 |
| cmux-feed-core | 0 | 0 | 0 | 2 | 0 | 2 | 1 | 0 | src/reduce.rs 3 |
| cmux-coderouter | 0 | 0 | 0 | 2 | 0 | 2 | 29 | 2 | src/free_tier.rs 32, src/lib.rs 1 |
| cmux-terminal-iface | 0 | 0 | 0 | 1 | 0 | 1 | 3 | 0 | src/credit.rs 3, src/ids.rs 1 |
| cmux-relay | 0 | 0 | 0 | 1 | 0 | 1 | 10 | 1 | src/relay.rs 10, src/admission.rs 2 |
| cmux-history | 0 | 0 | 0 | 1 | 0 | 1 | 16 | 1 | src/visit_stores.rs 9, src/hidden.rs 3, src/search_index.rs 3 |
| cmux-build-identity | 0 | 0 | 0 | 1 | 0 | 1 | 2 | 0 | src/lib.rs 3 |
| ghostty-vt-sys | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |  |
| cmux-unix-socket | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |  |
| cmux-tui-machine-protocol | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | src/lib.rs 1 |
| cmux-tui-machine-agent-protocol | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | src/lib.rs 1 |
| cmux-remote-browser | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 0 | src/scroll.rs 3, src/menu.rs 1 |
| cmux-rd-engine | 0 | 0 | 0 | 0 | 0 | 0 | 7 | 2 | src/lib.rs 9 |
| cmux-panic-log | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | src/lib.rs 1 |
| cmux-mobile-ffi | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | src/ownership.rs 2 |
| cmux-mobile-core | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |  |
| cmux-cloud-wire | 0 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | src/mirror.rs 8 |
| cmux-cloud-cli | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |  |
| bindings-rust-daemon-client | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 0 | bindings/rust-daemon-client/src/app_connection.rs 1, bindings/rust-daemon-client/src/attach.rs 1, bindings/rust-daemon-client/src/client.rs 1 |
| **all** | 2095 | 552 | 87 | 4606 | 315 | 7655 | 4456 | 557 | |

### Where the hits are reachable from outside input

| Crate | Module (deny hits) | Input that reaches it | Risk |
| --- | --- | --- | --- |
| cmux-tui-core | `server/` (453) | every socket request and reply of the daemon | highest: one panic poisons a shared lock |
| cmux-tui-core | `terminal_host*`, `terminal_host_runtime/`, `terminal_backend/` (about 310) | terminal host frames, PTY output | highest: terminal output |
| cmux-tui-core | `mux/` (1142), `surface/` (247), `state/` (167), `workspace_registry/` (137) | socket requests (layout, tabs, surfaces); terminal output (surface) | high: `Mux::state` is shared by every connection |
| cmux-tui-core | `journal_*`, `output_store/`, `history_ops/` (about 90) | journal and output-store records on disk | high: a bad record must not stop a restart |
| cmux-tui | `session/` (182), `pty_input` (26), `browser_input` (38), `link/` (121), `remote_cli` (40) | remote session frames, terminal input bytes, link peers | high |
| cmux-tui | `cli/` (533), `ui/` (106), `app/` (172) | the CLI process and the TUI client (short-lived, one user) | medium |
| acpmux | `server/` (41), `claude_stdio/` (27), `hub/` (415), `store` (25), `peer` (13), `agent_host/` (11) | socket RPC, agent stream-json/ACP, peers, the session store | highest for server/stdio, high for hub |
| acpmux | `tui/` (116), `cli/` (195) | the client UI and CLI | medium |
| cmux-remote, chatmux-relay, cmux-wg, cmux-transport, cmux-remote-protocol, cmux-pane-protocol, cmux-rd-proto | frames, relay packets, WireGuard/STUN | network peers | highest per hit |
| ghostty-vt | `terminal`, `snapshot`, `key` (104) | terminal output through the VT wrapper | high |
| cmux-config | `jsonc/` (44) | the user's config files | medium |

## 3. Enforcement: the panic ratchet

`scripts/cmux-next/rust_panic_ratchet.py` with
`scripts/cmux-next/rust-panic-baseline.json`, run by the `Rust panic ratchet`
step of the cmux-tui lint job (cmux-tui.yml), after `cargo clippy -D warnings`:

```sh
cd cmux-tui
cargo clippy --workspace --lib --bins --locked --message-format=json -- $(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags) > /tmp/c.jsonl   # rbx/Testbox/CI
python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/c.jsonl [--update-baseline] [--report md]   # laptop OK
```

- Deny lints (must reach 0): `unwrap_used`, `expect_used`, `panic`,
  `unreachable`, `todo`, `unimplemented`, `indexing_slicing`,
  `string_slice`, `panic_in_result_fn`. A crate may not gain a hit; a crate
  not in the baseline must have 0 (new crates start panic-free); a crate at 0
  is "at deny": any hit fails, the same as `#![deny]`.
- Tracked lints (`arithmetic_side_effects`, `cast_possible_truncation`): the
  same baseline, but growth only warns (section 4).
- The step fails when the clippy run did not finish (`build-finished`
  success), and warns when counts went down without a baseline update or a
  baseline crate was not checked. A red run prints the hit locations, files
  changed by the branch first. Not checked: the root `cmux-tui-source-watch`
  package and bins with `required-features`.
- Run `--update-baseline` only from a Linux clippy run (rbx, Testbox):
  macOS compiles other `cfg` paths and would lower the Linux counts.
- Lower the deny-lint baseline with `--update-baseline` in the commit that removes
  hits. It refuses to run while the ratchet is red and never raises a deny count.
  Tracked-lint baselines may be raised only from a successful authoritative Linux
  measurement; the PR must record the reason and run link.
- When enabling this guard on an existing CI path, a reviewed rollout rebaseline may
  record pre-existing deny hits measured on Linux with the current base merged.
  The PR must list every changed count and measurement SHA/run, and link the
  follow-up fixes that lower the deny counts. This exception does not change the
  normal comparison or the lowering-only `--update-baseline` command.

Why not `[workspace.lints.clippy] unwrap_used = "deny"` (the first plan):
Cargo applies the workspace table to every target of every member that
inherits it, with no per-target override (a crate can only drop the
inheritance and copy the whole table). A workspace deny fails 56 crates at once,
and also fails helper functions in `tests/`, benches and build scripts unless
hundreds of test roots carry an allow (clippy's `allow-unwrap-in-tests` covers
only `#[test]` and `#[cfg(test)]` items). Linting only the `--lib --bins`
targets keeps all test code free by construction, needs no Cargo.toml or
Cargo.lock change, and the per-crate counts are the shrinking allow list.
`crash_ratchet.py` (regex, also in safe-push) still guards unwrap/expect on
the laptop before a push.

## 4. Arithmetic and casts (decided: tracked, not deny)

- `arithmetic_side_effects` has 4456 hits, mostly counters, geometry and
  offsets. Release builds do not check overflow (the default
  `overflow-checks = false`), so `+ - *` wrap there and never panic; debug
  dogfood builds (`profile.dev`) do check. Division and remainder by zero
  panic in both. Making every `+` `checked_add` would hide the few real
  parser bugs among thousands of harmless lines. Instead: the parsers that
  see outside bytes get fuzz targets built with overflow checks and debug
  assertions on (section 7), where an overflow is a crash the fuzzer finds;
  the count is tracked and only warns when it grows; parser modules that
  reach 0 deny hits move to `checked_*`/`saturating_*` in the same pass.
- `cast_possible_truncation` (557) never panics. It matters on parsers, where
  a length cast wraps: the same fuzz targets cover them, and the protocol
  crates convert lengths with `try_from`.

## 5. Containment: panic = "unwind" stays, with supervisors

Decision: `[profile.release]` keeps the default `panic = "unwind"`.

- `catch_unwind` and tokio's `JoinError::is_panic` need unwinding. With
  `abort`, any panic left (third-party code, a missed path) would end the
  whole owner: every terminal and every connection, instead of one task.
- A panic inside an `extern "C"` function aborts anyway (Rust 1.81+), so the
  FFI edges cannot unwind into C; they wrap calls in `catch_unwind` already.
- The cost of unwinding is a poisoned lock. The target is that every
  `lock()` recovers from poison (rule 1; most of the 1434 cmux-tui-core
  unwraps today are `lock().unwrap()`), so one panicked request cannot turn every later request
  into a panic: that cascade is how a crash becomes a hang (the process is
  alive and answers nothing).

Supervisor (`cmux_panic_log::supervise`, std only; the panic hook in
`cmux-panic-log` already records each panic with its backtrace):

- every long-lived worker thread runs its body under `catch_unwind`; after a
  panic the supervisor restarts the worker with backoff, or, for a worker
  whose state cannot be rebuilt, ends the process cleanly so the process
  supervisor restarts it (never a live process that does nothing);
- every connection and request handler runs under a catch boundary: a panic
  ends that connection or answers that request with an internal error; the
  daemon keeps serving the others;
- tokio tasks: the spawner keeps the `JoinHandle` and handles
  `JoinError::is_panic` the same way.

## 6. Fatal paths (crash-only)

Abort, stack overflow (Rust aborts with SIGABRT after the guard page), out of
memory (`handle_alloc_error` aborts) and signals end the process at once; no
hook runs. The process supervisor (the app for the owner and acpmux; the
owner for its terminal hosts) restarts it, and the state is rebuilt from the
journal and the output store. A terminal host that dies affects only its
terminal; the owner shows the terminal as ended with its saved output. Each
fatal path gets a behavior test at the process boundary: start the daemon,
end it with that fatal path through a debug trigger, check that it is
restarted and that a client sees the same workspaces, tabs and terminal
output as before.

## 7. Fuzzing

`cmux-tui/fuzz` is its own Cargo workspace (its own Cargo.lock, so it never
needs the Cargo.lock slot), built with the pinned stable toolchain and
libFuzzer through `libfuzzer-sys` with sanitizer coverage flags, overflow
checks and debug assertions on. One target per parser of outside bytes:
terminal output (ghostty-vt), terminal input, socket and host frames, pane
and remote protocol frames, relay and STUN packets, ACP and stream-json
lines, config files (JSONC), journal and output-store records. CI runs each
target for a bounded time on a pull request that touches its crate and longer
nightly; a crash input becomes a corpus file and a fix.

## 8. Migration order and status

Highest risk first: socket- and terminal-output-reachable code of the
daemons, then disk records, then client and CLI code. Small file-disjoint
landings per crate or module, each lowering the baseline in the same commit.

| Lane | Scope |
| --- | --- |
| core-socket | cmux-tui-core `server/`, `terminal_host*`, `terminal_host_runtime/`, `terminal_backend/`, `journal_*`, `output_store*`, `event_bus`, `pty_*` |
| core-mux | cmux-tui-core `mux/`, `surface/`, `state/`, `workspace_registry/` |
| tui-daemon | cmux-tui `session/`, `pty_input`, `browser_input`, `link/`, `remote_cli`, owner and host code |
| acpmux | acpmux `server/`, `claude_stdio/`, `hub/`, `store`, `peer`, `agent_host/` and the other daemon modules |
| protocol crates | cmux-pane-protocol, cmux-remote-protocol, cmux-transport, cmux-rd-proto, cmux-pty, cmux-terminal-client and the other small crates, to deny |
| fuzz | section 7 |
| supervisor | section 5 and 6 |

Status per crate: section 9 (updated with each landing).

## 9. Status

Landing 1 (this page, the ratchet and its CI step): every crate at its section 2 count; 12 crates at deny.

Re-baseline 2026-10-29 (the ratchet step was red Oct 23-29, so lanes landed
~700 new deny hits unchecked). Every new slice, array, string-slice and
expect hit was removed (about 290; cmux-holder, cmux-flow-trace, cmux-process
and cmux-git now at deny). The one deliberate raise: `indexing_slicing` in
acpmux, cmux-tui, cmux-tui-core, cmux-server, cmux-server-core,
cmux-browser-host, cmux-host and cmux-tui-cloud-conversations, for
string-key indexing of `serde_json::Value` (`v["key"]`). A read returns
`Null` and never panics. A write panics only if the value is neither an object
nor null; most of the ~217 new writes are on values built by `json!({..})`,
but they were sampled, not all reviewed. Clippy cannot tell these from slice indexing, so they are counted.
Next step for them: a non-panicking `set` helper, then lower the counts.
22 crates at deny.

JSON writes 2026-10-29: the leaf crate `cmux-json` adds `JsonSet::set` and
`set_path` (null becomes an object; any other non-object is left unchanged and
`set` returns `false`). acpmux's `no_panic::JsonExt` is now that trait. About
1,010 production `v["key"] = x` writes in 17 crates moved to it, and
`v["key"].as_array_mut()`/`take()` sites use `get_mut`. `indexing_slicing`
went down by 972: acpmux 1021 to 697, cmux-tui 1141 to 833, cmux-tui-core
1058 to 853, cmux-browser-host 211 to 140, cmux-tui-cloud-conversations 55 to
25, cmux-tui-cdp 14 to 5, cmux-server 65 to 58, cmux-server-core 30 to 25,
cmux-host 1 to 0, and 1 to 3 each in 8 small crates. Use `v.set("key", x)`
for new writes; the rest of these counts are reads (`v["key"]`, which
return `Null`) and slice indexing.
