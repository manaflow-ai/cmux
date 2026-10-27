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

1. **Toolchain.** The sweep uses the same Xcode and SDK as `package-test-lane.sh` (`select_xcode`,
   `pin_sdkroot`): `DEVELOPER_DIR` when it is set, else the pick of `scripts/select-ci-xcode.sh`
   (without `xcode-select`). `SDKROOT` is the macOS SDK of that Xcode; an `SDKROOT` from the
   environment is replaced, because a leaked CommandLineTools SDK makes every manifest invalid.
   The enumeration and every lane run get both values.
2. **Enumerate.** `xcrun --sdk macosx swift package dump-package` of `Packages/macOS/CmuxNext`, then
   of each package it reaches through `.package(path:)` inside `Packages/`. The test targets of each
   package are the suites. Remote packages (Sentry, Sparkle, swift-atomics) are not tested.
3. **Base pass.** Every package runs `scripts/ci/package-test-lane.sh suite PACKAGE TARGET,...` once
   with no sanitizer. A target that is red here is **base-red** (for example CmuxNextAppTests, signal
   11). The sweep prints the base-red list and writes it to `base-red.jsonl`. These are normal test
   failures for their owners, not sanitizer findings, and they are not counted. A package that does
   not build at the base has no verdict: it is not run again, and the sweep exits 3.
4. **One pass per mode.** `thread`, `address` and `undefined` set `CMUX_SWIFT_SANITIZE`; the lane
   builds into `.build-sanitize-<mode>`. `coop-strict` sets `CMUX_SWIFT_TEST_COOP_STRICT=1`: the lane
   gives `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a cooperative pool of width 1) to each
   `swift test` run under the hang watchdog, and not to the build, so code that blocks a Swift
   concurrency thread hangs. Under a sanitizer the stall and total limits of the lane are 3x (thread)
   or 2x (address, undefined), as Chromium scales test timeouts in `base/test/test_timeouts.cc`.
5. **Count.** `crash_signature.py` reads each target's output. Only the kind of the mode counts:

   | Mode | Counted kind |
   | --- | --- |
   | thread | tsan |
   | address | asan |
   | undefined | ubsan |
   | coop-strict | hang: `cooperative-pool stall`, the heaviest stack of the blocked pool thread |

   For `coop-strict` the signature comes from the watchdog's `sample` of a stalled test process
   (`xctest`, `swiftpm-testing-helper`): the thread on a `.cooperative` queue or with Swift
   concurrency runtime frames, not the main thread. A test runner parks its main thread in its run
   loop or `dispatch_main` whatever deadlocked, so the main thread would give every stall the same
   signature.

   One line in `findings.jsonl` per unique `(mode, hash12)`, with its frames and the targets that
   hit it. Each line is one fix task. Reports from base-red targets, reports of another kind (an
   LSan leak under `address`), targets that are red under a mode with no counted report (a
   sanitizer slowdown past the limit), and `coop-strict` stalls with no test-process pool thread in
   a sample go to `not-counted.jsonl`.

Outputs in the folder of `--out`: `findings.jsonl`, `base-red.jsonl`, `not-counted.jsonl`,
`summary.json` and `logs/<base|mode>/<package>.log`. The sweep writes all four files when it
starts and again after each lane run, so a step that times out keeps the base-red list and the
findings so far. `summary.json` has `"complete": false` until the sweep ends, and `runs` names each
`<base|mode> <package>` run that finished.

Exit status: 0 no finding; 1 findings; 2 bad arguments, a non-fleet host or a bad suppressions file;
3 no verdict (no Xcode or SDK, enumeration failed, a package did not build at the base, or a mode
did not build a package that built at the base).

## Suppressions

`tsan-suppressions.txt` goes to TSan as `TSAN_OPTIONS=suppressions=...`. TSan matches a pattern
anywhere in a function, file or module name. The sweep refuses the file unless:

- it has at most 10 suppressions;
- the line right above each suppression is `# third-party <component>: <reason>`;
- no pattern can match cmux code: a pattern may not start with `*`, needs a literal run of at least 4
  characters, may not contain `cmux`, may not name a type declared under `Packages/`, and may not be
  part of a tracked `Packages/` path or of a type or function name declared there (`git ls-files`
  and `git grep` of the checkout). Name the library: `race:Sparkle.framework`, not `race:Sparkle`
  (which also matches `UpdateSheetContent+Sparkle.swift`).

A race in cmux code is a finding to fix. Chromium keeps its list the same way, with a bug per entry,
in `build/sanitizers/tsan_suppressions.cc`.

## Limits

- Under `coop-strict` the `swift test` driver also runs on the strict pool: the test process gets
  the environment of `swift test`, and SwiftPM has no option to set a variable for the test process
  alone. The watchdog bounds the driver: a driver stall ends at the stall or total limit, and with
  no test-process pool thread in the sample it goes to `not-counted.jsonl`. The build never runs on
  the strict pool.
- `swift test --filter TARGET` matches by substring. Two targets of one package where one name
  contains the other run the shorter one's tests twice; the findings are still one line per
  signature.

## Test

`python3 -I scripts/cmux-next/tests/test_sanitizer_sweep.py` (stubbed lane, manifests and toolchain;
runs on Linux) and `python3 tests/test_ci_package_lane_suite.py` (the lane's
`CMUX_SWIFT_TEST_COOP_STRICT`).
