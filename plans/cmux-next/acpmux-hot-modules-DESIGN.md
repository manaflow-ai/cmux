# acpmux hot modules: swapping one piece of a live daemon (prototype)

Status: prototype, dev-only (`acpmux` feature `hot-modules`, debug builds only). Leo, 2026-11-05: "do
we hot reload the back? ... what are ways that we can accelerate more, have even more things running in
parallel", then "I think we should do every single idea. And especially because, like, I think the rest
of the team will really, really appreciate this kind of thing."

Today the fastest way to try a daemon change is the restart swap (`scripts/cmux-next/daemon-swap-check.py`,
1 to 1.3 s, every session adopted by the new daemon). This prototype goes one step further for code that
holds no state: the daemon keeps running, and one function is replaced between two calls. Nothing moves,
because the replaced code owns nothing.

## What it is

`cmux-tui/crates/acpmux-hot` hosts acpmux pieces as WebAssembly components (wasmtime 48, the component
model, one WIT world, `wit/hot.wit`). `crates/acpmux-hot/guest` compiles acpmux's own source files to
`wasm32-wasip2`: it includes `agent_login/parse.rs` and `write_journal/classify.rs` by path, so the
module and the native build are the same code and there is nothing to keep in sync.

The dev loop: start a debug daemon with `ACPMUX_HOT_MODULE=<checkout>/cmux-tui/crates/acpmux-hot/guest/target/…/acpmux_hot_guest.wasm`,
edit `parse.rs`, run `cargo build --release --target wasm32-wasip2` in `guest/`. The daemon's next sign-in
reads its output with the new code.

- **Load** runs on a watcher thread (polls size, mtime and inode every 100 ms). It checks where the
  file comes from (below), compiles it, links every import as a trap, instantiates it once and asks its
  `abi-version`. Only a module that passes all of that goes live, by one pointer store (`ArcSwapOption`).
  No caller ever waits for a compile.
- **Calls** are lock-free. Each thread keeps its own instance of the live module and makes a new one on
  its first call after a swap. A call in flight finishes on the instance it started with, so a swap
  never stops or waits for one: the new module takes over between two calls.
- **A trap** (a panic, `unreachable`, fuel or memory past its limit) makes that call answer `None`, and
  the caller runs its native code for it. The trapped instance is dropped, the slot rolls back to the
  module before it (or to none, which means native), and those bytes are not loaded again until the file
  holds different bytes.
- **Wired in the daemon:** `agent_login::hot::offer` (the sign-in output parser) asks the module first
  and falls back to `parse::offer`. `is_pure_read` is hosted and measured, but the write journal has no
  production caller yet, so nothing calls it in the daemon.

## Numbers (fleet)

Two `cmux-ci test` runs agreed within a few percent; the first run's numbers (Linux x86_64 fleet runner, release build, 3000 interleaved calls per case;
`bench.sh`, report `hot-bench.json`). The guest is 69 KB.

Per call, p50 (p99), native against the module with fuel metering on (the daemon's setting) and off:

| Case | Native | Wasm, fuel on | Wasm, fuel off |
|---|---|---|---|
| `is_pure_read`, short read (`git status --short`) | 0.49 µs (0.51) | 1.47 µs (1.61) | 1.07 µs (1.11) |
| `is_pure_read`, short exec (`cargo build -p acpmux`) | 0.19 µs (0.20) | 0.85 µs (0.89) | 0.65 µs (0.69) |
| `is_pure_read`, 4 KB command | 95 µs (100) | 217 µs (244) | 144 µs (152) |
| `login_offer`, Claude OSC-8 link | 0.49 µs (0.53) | 1.20 µs (1.24) | 1.00 µs (1.04) |
| `login_offer`, Codex link and code | 0.57 µs (0.80) | 1.53 µs (2.27) | 1.17 µs (1.20) |
| `login_offer`, 64 KB of Codex output | 128 µs (238) | 338 µs (575) | 235 µs (301) |

So a call costs about 0.5 to 1 µs more than native before any work: the string copy into the guest,
the call, and the result copied back. The work itself runs 1.5x (no fuel) to 2.3x (fuel) slower than
native. Fuel is the price of rolling back a module that loops; it costs more than the call itself.

Swap and rollback, with a second thread calling the module in a loop the whole time (295,703 calls):

| Step | Time |
|---|---|
| Compile on load (the watcher thread, never a caller) | 40 to 86 ms |
| Probe (instantiate once and ask `abi-version`) | 0.07 to 0.13 ms |
| Publish (the pointer store, under a lock no caller takes) | 0.23 to 0.35 µs |
| A thread's first call on a new module (its own instance) | 18 to 144 µs |
| File written to the first call the new module answers | 62 ms (5 ms poll in the bench, 100 ms in the daemon) |
| Worst call during that swap | 55 µs; 0 calls fell back to native |
| A module that panics: file written to rolled back | 53 ms, 1 call answered by native code |
| A module that loops: file written to rolled back | 56 ms; the looping call ran out of fuel in 3.2 ms |
| Guest rebuild after editing `parse.rs` (warm) | 0.63 s |

Against the restart swap (1 to 1.3 s, every session re-adopted), editing a hosted piece reaches the
running daemon in under 0.7 s of rebuild plus about 0.1 s of load, and no session notices. The compile
is most of the load; precompiling (Next, item 3) would leave the poll and the pointer store.

## Which pieces fit

A piece fits when it is a pure function of a few strings or numbers, is called less than about once per
frame, and changes more often than its neighbours. In acpmux today:

| Piece | Fits? | Why |
|---|---|---|
| `agent_login::parse` (sign-in link and code from agent output) | yes, hosted | pure, string in and out, called per output chunk of a sign-in |
| `write_journal::classify` (is a shell command a pure read) | yes, hosted | pure, one string in, a bool out; per tool call once wired |
| `host_load::classify_command` and `shell_words` (heavy build or test detection) | yes, next | pure over the command text; today it sits in a module that also reads `/proc` and calls the daemon, so the pure half needs its own file first |
| `hub/titles.rs` `clean`, `prompt_gist`, `is_thin_prompt` | yes | pure text rules that get tuned often |
| `server/redact.rs` (what a remote peer may see) | possible | pure over a JSON value, but the value crosses as text both ways; redaction is a security boundary, so a dev module there must never load outside a dev build (it doesn't) |
| `cmux-agent-pane-policy` `allowlist_decision` (page frame policy) | possible, host side | pure and table driven, but it runs in the app hosts, not the daemon |

## What stays native

- **Per-frame and per-byte paths:** relaying ACP frames, the chat log and journal writes, frame
  compression, the terminal VT parser and PTY pumps. A call into wasm costs about a microsecond more
  than native before the work itself (above), and every string is copied into guest memory and back.
  At thousands of frames per second that is a budget we do not have (P9 in PATTERNS.md: no I/O and no
  extra copies on a request path).
- **Anything with state, I/O or async:** sessions, sockets, tokio tasks, locks, the journal, the
  supervisor. A component owns its own memory; giving it handles to the daemon's state is where "no
  state moves" stops being true. The prototype's world imports nothing for that reason.
- **Serde-shaped work** (JSON in, JSON out): the copy and reparse cost both sides; worth it only when the
  function is slow anyway.

So the shape is: native code calls a hot piece the way it calls a helper, with plain values, and keeps
its own native copy as the fallback.

## Security: where a module may come from

A module runs inside the daemon that holds every session and credential path, so it gets the rule Live
Code keeps (docs/cmux-next/live-code.md): only Debug builds load code at run time, until a patch's
signer is checked (cmux#13742).

- **Dev builds only.** `acpmux_hot::daemon()` returns nothing in a release build whatever the
  environment says, and the code is not even compiled without the `hot-modules` feature, which no
  shipped build turns on.
- **Local checkout only.** The file (after following symlinks) must sit inside a git checkout, and the
  file and every folder up to that checkout must belong to the daemon's user and be writable by nobody
  else, so another account on the machine cannot put code into the daemon (`src/trust.rs`, checked
  again at every reload).
- **No capability.** The guest's world imports nothing. Whatever WASI imports the Rust toolchain adds
  are linked as traps, so a module cannot open a file, read the environment, see the clock or reach the
  network. Fuel (200 M units per call) and a 64 MiB memory limit bound a runaway module, which then
  rolls back.
- **Not yet: signed modules.** Loading a module into an installed nightly needs the signer check
  cmux#13742 decides, the same one Live Code waits for. The recommendation for that thread: accept a
  module only when it is signed by the same Developer ID team that signed the running app (or the
  fleet's CI key for a CI-built module), its sha256 is listed in a manifest signed the same way, and the
  manifest names the daemon build it was compiled against. Until that is decided, installed builds never
  load modules.

## What this costs nobody

The `acpmux-hot` crate builds as plain types without its `wasm` feature, and `acpmux` depends on it only
under `hot-modules`, so default builds, CI and shipped apps compile no wasmtime. No CI job, gate or test
was added; `bench.sh` is run by hand on the fleet.

## Run it

```bash
cmux-ci test --setup rust --artifact /tmp/hot -- bash cmux-tui/crates/acpmux-hot/bench.sh
```

It builds the guest's four variants (good, `v2`, `trap`, `spin`), runs the trust tests, the per-call
bench against native, the swap and rollback runs under a calling thread, and `cargo check -p acpmux
--features hot-modules`; the report is `hot-bench.json` in the artifact.

## Next

1. Split `host_load`'s pure command reading into its own file and host it (it runs per tool call).
2. A `cmux dev hot` verb that builds the guest and points a running debug daemon at it, so nobody sets
   an environment variable by hand.
3. Precompile on the build fleet (`Component::serialize`), so a swap skips the compile and is the
   pointer store alone.
