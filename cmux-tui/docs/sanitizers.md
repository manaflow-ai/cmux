# Rust sanitizers and Miri

`cmux-tui/scripts/sanitize.sh` runs the tests of the daemon's unsafe-heavy
crates under AddressSanitizer, ThreadSanitizer and LeakSanitizer, and the pure
protocol crates under Miri. Each bug becomes a line in `findings.jsonl` with a
stable signature, so the same bug from two runs is one task (queue Q15 of
`plans/cmux-next/chrome-parity/p10-stability.md`).

## Run it

```sh
cmux-tui/scripts/sanitize.sh --install --list          # install the pinned nightly once
cmux-tui/scripts/sanitize.sh --sanitizer address --crate cmux-holder
cmux-tui/scripts/sanitize.sh                           # every mode, every default crate
cmux-tui/scripts/sanitize.sh --dry-run                 # print the cargo commands only
```

Run it on a Testbox, a Linux builder or a fleet Mac, never on a person's Mac.
Arguments after `--` go to nextest, for example `-- -E 'test(ring)'`.

| Mode | Crates on Linux | Crates on macOS |
| --- | --- | --- |
| `address`, `thread`, `leak` | cmux-tui-core, acpmux, cmux-holder, cmux-pty, ghostty-vt | cmux-pty, cmux-holder |
| `miri` | cmux-pane-protocol, cmux-remote-protocol, cmux-rd-proto, cmux-layout-reducer | the same |

Linux runs miss `cfg(target_os = "macos")` code, so cmux-pty and cmux-holder
also run on macOS. `--crate` replaces the default list of every selected mode.

## Toolchain

`-Zsanitizer`, `-Zbuild-std` and Miri exist only on nightly. The lane's nightly
is pinned in `cmux-tui/sanitize/rust-toolchain.toml` and used through
`rustup run`; the workspace's `cmux-tui/rust-toolchain.toml` stays the single
toolchain for builds, tests and releases. The script passes `--locked` and
checks after the run that `Cargo.lock` and `rust-toolchain.toml` did not
change: `-Zbuild-std` resolves std from rust-src's own lockfile.

Move the nightly date in its own commit, after one green run on the new date.

## How a run works

- Sanitizers: `cargo nextest run -p CRATE -Zbuild-std --target HOST` with
  `-Zsanitizer=MODE -Cforce-frame-pointers=yes`. `-Zbuild-std` instruments std
  too; `--target` keeps build scripts and proc macros uninstrumented. rust-src
  is remapped to `/rustc/<commit>`, so std's frames have a prebuilt std's
  files and the signature's `file:^/rustc/` rule drops them. Each mode has its
  own target directory under the work directory. The target runner
  `cmux-tui/sanitize/test-runner.sh` writes each test process's pid and test
  name to `tests.tsv`, so `report.<pid>` names its test.
- Runtime options follow Chromium (`build/sanitizers/sanitizer_options.cc`):
  each process writes `report.<pid>` through `log_path`; TSan reports every
  race (`halt_on_error=0`), skips thread leaks and keeps two deadlock stacks.
  Linux ASan also checks leaks in the same process, as Chromium's ASan bots do;
  the same leak gets the same signature from `address` and `leak`. All three
  print frames as `#N PC in FUNCTION FILE:LINE:COL`, or `(MODULE+0xOFFSET)`
  for a frame with no source; the signature drops the BuildId, which changes
  per build. Inlined frames stay, one line each, as ClusterFuzz keeps them:
  std's inlined helpers are dropped by their `/rustc/` file and libtest's
  harness (`test::`) by name, so the top frames are the code under test.
  `llvm-symbolizer` is used when found (`LLVM_SYMBOLIZER`, `PATH`,
  `/usr/lib/llvm-*`), else addr2line on Linux and atos on macOS. The work
  directory and symbolizer paths are quoted in the runtime options; a path
  with a `'` is refused.
- Miri: `cargo miri nextest run -p CRATE`, one process per test, so one test's
  Undefined Behavior does not hide the next test's. The `miri` profile skips
  three cmux-layout-reducer tests that take 3 to more than 30 minutes under
  Miri (`exhaustive_small_layouts_keep_invariants`,
  `random_op_sequences_keep_invariants`, `sidebar_layout::tests::random_ops_keep_invariants`);
  the crate has no unsafe code and its other tests run. `-- --ignore-default-filter`
  runs them.
- nextest profiles `sanitize` and `miri` come from `cmux-tui/sanitize/nextest.toml`
  (`--tool-config-file`): no retries, no fail-fast, longer hang limits for
  instrumented code.

## Output

The work directory defaults to `cmux-tui/target/sanitize` (`--work-dir`,
`CMUX_SANITIZE_WORK_DIR`). Per crate and mode, `logs/MODE/CRATE/` holds the
report files, nextest's libtest-json-plus events and its log.

`findings.jsonl` (`--out`): one line per unique signature of one crate run,
from `scripts/cmux-next/crash_signature.py`: `kind` (`asan`, `tsan`, `lsan`,
`miri`), `exception`, top 3 `frames`, `hash12`, with `tool`, `crate`, `os`,
`target`, `toolchain`, `commit`, `count`, sample `reports`, the first `test`
that hit it and up to five `tests`. File one task per unique `hash12`.

`runs.jsonl` (`--runs`): one line per crate run with `result`:

| result | meaning |
| --- | --- |
| `pass` | every test passed, no report |
| `findings` | at least one finding, or a report no signature could be read from (`unparsed_reports`) |
| `failed` | tests failed with no report: red at the base, or a sanitizer slowdown |
| `unsupported` | only tests Miri cannot run (FFI, sockets, file system, processes) failed; green, listed in `unsupported_tests` |
| `build-failed` | the crate did not build or list its tests under the sanitizer |
| `no-tests` | the crate has no tests to run |

The script exits 0 only when every run is `pass` or `unsupported`. With the
default crates, cmux-pane-protocol and cmux-rd-proto end `unsupported`: their
socket, file and proptest tests need operations Miri isolation blocks.

## Known limits

- A test that touches the file system or a socket, spawns a process or calls C
  fails under Miri's isolation. It is listed in `unsupported_tests` and is not
  a finding; it still runs in the stable `cargo nextest` run.
- LeakSanitizer scans memory conservatively: a stale pointer left on a stack
  can hide a leak. ASan's leak check on Linux finds more.
- C and Zig code linked into a crate (ghostty-vt-sys) is not instrumented.
