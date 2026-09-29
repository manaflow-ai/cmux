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
invocation is not verification. CLI tests run in the `cmux-cli-tests` scheme
(host-free) on CI. Never run `xcodebuild test` locally.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.
`scripts/cmux-next/cli-compat-tests-v2.py` runs the suite against a tagged build; many files still call legacy `debug.*` methods, so compare with the baseline in `plans/cmux-next/cli-compat.md`.

For CLI dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`, not the global
`/tmp/cmux-cli` symlink. Confirm the tested artifact is the one you launched.
