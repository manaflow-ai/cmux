# Swift sanitizer sweep

`scripts/cmux-next/sanitizer-sweep.sh` runs the test targets of CmuxNext and of every
package it reaches through `.package(path:)` (the mac closure) under ThreadSanitizer,
AddressSanitizer, UndefinedBehaviorSanitizer and the strict cooperative pool. It counts
only real sanitizer findings. It is the Q15 `sanitizer-findings` queue of
[stability-DESIGN.md](../../plans/cmux-next/stability-DESIGN.md) (p10-stability-013).

## Run it

It runs only as a fleet step or on a GitHub runner. On any other host it stops with exit 2
and does not build:

```sh
cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- --sanitize thread
cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- \
  --sanitize thread,address,undefined,coop-strict --ref SHA --out .build/sanitizer-sweep/findings.jsonl
```

Use `--artifact .build/sanitizer-sweep` to get the logs, reports and `summary.json`.

| Option | Meaning |
| --- | --- |
| `--sanitize LIST` | comma list of `thread`, `address`, `undefined`, `coop-strict` (default: all four) |
| `--ref SHA` | refuse unless the checkout's HEAD is this commit |
| `--out FILE` | findings JSONL (default `.build/sanitizer-sweep/findings.jsonl`) |
| `--out-dir DIR` | logs, reports, `base-red.json`, `summary.json` (default `.build/sanitizer-sweep`) |
| `--package DIR`, `--target NAME` | sweep only these (repeatable), for a repro |
| `--include-base-red` | also run base-red targets under the modes; their signatures are recorded, not counted |
| `--list` | print the packages and test targets, run nothing |

A full sweep builds every closure package once per mode and runs each test target alone;
give the step a long `--timeout`. A sanitizer run is 2 to 15 times slower than a plain
one, so the sweep raises the lane's stall limit to 900 s and its suite limit to 3600 s
unless the caller sets `CMUX_SWIFT_TEST_STALL_SECONDS` or
`CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS`.

## What it does

1. **Enumerate.** `swift package dump-package` from `Packages/macOS/CmuxNext`, following
   path dependencies inside `Packages/`. Remote packages (Sentry, Sparkle, swift-atomics)
   have no tests here.
2. **Base pass.** Every target runs once with no sanitizer
   (`scripts/ci/package-test-lane.sh suite PACKAGE T1,T2,...`). A target that is red here is
   base-red: it is printed under "Base-red suites", written to `base-red.json`, and is not
   swept or counted. It belongs in its own fix queue (CmuxNextAppTests' signal 11, for
   example). This is the "without patch" retry of Chromium's test recipes
   (`recipes/recipe_modules/chromium_tests/api.py`): a test red without the change does not
   blame the change.
3. **Modes.** For each mode, the same lane runs the base-green targets per package:
   - `thread`, `address`, `undefined`: `CMUX_SWIFT_SANITIZE`, which builds into
     `.build-sanitize-<mode>` with `--sanitize=<mode>`.
   - `coop-strict`: no sanitizer, `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a cooperative
     pool one thread wide, so code that blocks a pool thread on other pool work hangs).
   Under `thread` the sweep sets `TSAN_OPTIONS` to Chromium's defaults
   (`build/sanitizers/sanitizer_options.cc`): `halt_on_error=0`, `second_deadlock_stack=1`,
   `history_size=7`, `print_suppressions=1`, and the suppressions file below.
4. **Count.** Each sanitizer report in a suite's output (`WARNING: ThreadSanitizer:`,
   `ERROR: AddressSanitizer:`, `ERROR: LeakSanitizer:`, `: runtime error:` through its
   `SUMMARY:` line) is written to `reports/<mode>/<package>/<suite>-N.txt` and given to
   `scripts/cmux-next/crash_signature.py REPORT` (p10-stability-002), which prints the
   signature record `{kind, process, exception, frames, hash12}` as JSON or JSON lines.
   - A record of the mode's kind (`tsan`, `asan`, `ubsan`) counts, once per `(mode, hash12)`
     with a hit count.
   - Under `coop-strict`, a base-green target that stalls or times out after a test started
     counts as `coop-strict-hang` (its hash is the mode, package and suite). A stall before
     any test started is `swift test` itself (SwiftPM also runs under the variable) and has
     no verdict.
   - A report of another kind (a LeakSanitizer report under `address`) is written to the
     findings file with `counted: false`.
   - A suite that goes red with no sanitizer report (a test too slow under the sanitizer,
     for example) is listed as "red, no report" and not counted.

## Output and exit status

`findings.jsonl` has one row per `(mode, hash12)`: `mode`, `kind`, `hash12`, `process`,
`exception`, `frames` (top 3), `package`, `suites`, `count`, `reports` (up to 5 paths) and
`counted`. Each counted row is one Q15 task. `summary.json` has the packages, the base-red
list, the per-mode counts, the unclassified reports and the exit status.

| Exit | Meaning |
| --- | --- |
| 0 | no counted signature |
| 1 | at least one counted signature |
| 2 | refused: not a fleet host, bad suppressions, HEAD is not `--ref`, no `crash_signature.py`, usage |
| 3 | no verdict: a package did not build under a mode, or `crash_signature.py` did not classify a report |

## Suppressions

`scripts/cmux-next/tsan-suppressions.txt` is the TSan suppressions file. The sweep checks it
before every run and refuses a file that breaks these rules:

- Third-party code only (Sentry, Sparkle, libghostty, CEF, the SDK). A pattern that names
  cmux or MessagesLab is refused: a race in cmux code is fixed, never suppressed.
- At most 10 entries, each `TYPE:PATTERN` (`race`, `race_top`, `thread`, `mutex`, `signal`,
  `deadlock`, `called_from_lib`), each right after its own `# reason` line. TSan reads a
  trailing comment as part of the pattern, so the reason goes on the line before.
- Add an entry only with a report from a sweep run, and link the upstream issue. Remove it
  when the upstream fix lands.

Tests: `python3 -I scripts/cmux-next/tests/test_sanitizer_sweep.py` (no build; the lane and
`crash_signature.py` are faked).
