# Choose verification for the change

Run repository commands only from a [trusted checkout](../../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

Start with the smallest check that can expose the failure you are fixing. Use
`python3 scripts/verify-local.py --list` to see the fast static checks; run the
full command before a native build or push when those checks apply. A passing
preflight establishes only its named scope. See the [command guide](../../../docs/verification-receipts.md)
for focused reruns and evidence receipts.

For edited Swift, use `python3 scripts/verify-local.py --swift-changed` before
the native build; add a base ref to include committed branch changes. While
repairing syntax, rerun with `--only swift-syntax --swift-changed`. Use
`--swift-stdin0` for piped selections and `--receipt -` for JSON stdout. This
parses only the selected files with the installed compiler;
it does not typecheck imports or execute tests. Contributor-wide setup and
verification guidance belongs in [CONTRIBUTING.md](../../../CONTRIBUTING.md);
the notes here cover the native evidence distinctions needed by this skill.

For docs or portable tooling, validate links/commands and run the affected portable
tests. An app build is needed when native build or runtime behavior changes, not
for every instruction edit. Web changes need their package's checks and live preview.

Native work uses a [tagged build](../../cmux-dev-workflow/references/tagged-builds.md)
or the existing CI lane. Team members: shared build fleet rules are in cmuxterm-hq.

## Native app versus test compilation

A tagged `reload.sh` build proves the `cmux` scheme (the `cmux-next` target) built.
It says nothing about whether package tests or test-only imports compile.
Compile and run the app package tests with SwiftPM:

```sh
cd Packages/macOS/CmuxNext
swift build --build-tests
swift test --filter <Module>Tests
```

`swift test` does not launch `cmux DEV`. Record how many tests ran; a zero-test
invocation is not verification. CLI tests are cmux-tui Rust tests;
run them on a Testbox or in CI. Never run `xcodebuild test` locally.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.

For CLI dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`, not the global
`/tmp/cmux-cli` symlink. Confirm the tested artifact is the one you launched.

## Repeat admission without rebuilding between runs

Use one managed step for repeated independent suite processes:

```sh
cmux-ci run --class light --script scripts/ci/run-swift-testing-suites.sh \
  --ref FULL_SHA --arg Packages/macOS/CmuxNext --arg=--repeat --arg 20 \
  --env CMUX_SWIFT_TEST_SUITES=HandlerCoverageTests \
  --env CMUX_SWIFT_TEST_DIRECT=0 --env CMUX_SWIFT_TEST_SUITE_JOBS=1 \
  --env CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS=60 \
  --key handler-admission-FULL_SHA --timeout 7200
```

`--repeat N` (1–9999) builds/lists once with the normal binary-header guard
then starts a fresh process for each repetition of each selected suite. Each
process must finish within its deadline and report nonzero test execution.
Admission disables timeout and database-lock retries and stops a suite at its
first failure. Other selected suites still report their results. Omit the flag
for the ordinary suite runner's existing retry policy.

Keep the exact source SHA, worker, toolchain, CPU budget, debug-info options,
`ci-phase build-and-list` duration, and every `ci-repeat` row. The summary must
say all requested repetitions passed; a timed-out build means zero completed
repetitions. Compare build minutes separately from warm execution seconds.
A compiled target alone is not a linked/discovered test bundle. A binary-header
ABI change legitimately invalidates build products; preserve that guard and
do not claim a scheduler cache defect without evidence of a compatible slot.
