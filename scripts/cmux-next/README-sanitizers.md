# Swift sanitizer sweep

`scripts/cmux-next/sanitizer-sweep.sh` runs the Swift package tests of the CmuxNext closure under
ThreadSanitizer, AddressSanitizer, UndefinedBehaviorSanitizer and the strict cooperative pool. It is
the Swift half of queue Q15 and done check 13 in
[stability-DESIGN.md](../../plans/cmux-next/stability-DESIGN.md). The Rust half is
`cmux-tui/scripts/sanitize.sh`.

## Run it

It runs only as a fleet step. On a developer Mac or on Linux it refuses (exit 2).

```bash
cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh \
  --artifact .build/sanitizer-sweep -- --sanitize thread
cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh \
  --artifact .build/sanitizer-sweep -- \
  --sanitize thread,address,undefined,coop-strict --ref SHA --out .build/sanitizer-sweep/findings.jsonl
```

Options:

- `--sanitize MODES`: a comma list of `thread`, `address`, `undefined`, `coop-strict`.
- `--ref SHA`: refuse unless the checkout is that commit.
- `--out FILE`: the findings file (default `.build/sanitizer-sweep/findings.jsonl`).
- `--package NAME`: only that closure package, by name (`CmuxTheme`) or path; repeatable.

## What it does

1. **Enumerate.** `swift package dump-package` of `Packages/macOS/CmuxNext`, then of each package it
   reaches through `.package(path:)` inside `Packages/`. The test targets of each package are the
   suites. Remote packages (Sentry, Sparkle, swift-atomics) are not tested.
2. **Base pass.** Every package runs `scripts/ci/package-test-lane.sh suite PACKAGE TARGET,...` once
   with no sanitizer. A target that is red here is **base-red** (for example CmuxNextAppTests, signal
   11). The sweep prints the base-red list and writes it to `base-red.jsonl`. These are normal test
   failures for their owners, not sanitizer findings, and they are not counted.
3. **One pass per mode.** `thread`, `address` and `undefined` set `CMUX_SWIFT_SANITIZE`; the lane
   builds into `.build-sanitize-<mode>`. `coop-strict` sets `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
   (a cooperative pool of width 1) on the base build, so code that blocks a Swift concurrency thread
   hangs. Under a sanitizer the stall and total limits of the lane are 3x (thread) or 2x (address,
   undefined), as Chromium scales test timeouts in `base/test/test_timeouts.cc`. A package that does
   not build at the base is not run again.
4. **Count.** `crash_signature.py` reads each target's output. Only the kind of the mode counts:

   | Mode | Counted kind |
   | --- | --- |
   | thread | tsan |
   | address | asan |
   | undefined | ubsan |
   | coop-strict | hang (the watchdog's stack sample of a stalled target) |

   One line in `findings.jsonl` per unique `(mode, hash12)`, with its frames and the targets that
   hit it. Each line is one fix task. Reports from base-red targets, reports of another kind (an
   LSan leak under `address`), and targets that are red under a mode with no counted report (a
   sanitizer slowdown past the limit) go to `not-counted.jsonl`.

Outputs in the folder of `--out`: `findings.jsonl`, `base-red.jsonl`, `not-counted.jsonl`,
`summary.json` and `logs/<base|mode>/<package>.log`.

Exit status: 0 no finding; 1 findings; 2 bad arguments, a non-fleet host or a bad suppressions file;
3 no verdict (enumeration failed, or a mode did not build a package that built at the base).

## Suppressions

`tsan-suppressions.txt` goes to TSan as `TSAN_OPTIONS=suppressions=...`. The sweep refuses the file
unless:

- it has at most 10 suppressions;
- each suppression is for third-party code: no pattern names cmux code;
- the line right above each suppression is `# third-party <component>: <reason>`.

A race in cmux code is a finding to fix. Chromium keeps its list the same way, with a bug per entry,
in `build/sanitizers/tsan_suppressions.cc`.

## Limits

- `coop-strict` sets the variable for the whole lane, so `swift test` itself also runs on a pool of
  width 1. If SwiftPM stalls before a test process starts, the watchdog samples no test process, and
  the stall goes to `not-counted.jsonl` instead of `findings.jsonl`.
- `swift test --filter TARGET` matches by substring. Two targets of one package where one name
  contains the other run the shorter one's tests twice; the findings are still one line per
  signature.

## Test

`python3 -I scripts/cmux-next/tests/test_sanitizer_sweep.py` (stubbed lane and manifests; runs on
Linux).
