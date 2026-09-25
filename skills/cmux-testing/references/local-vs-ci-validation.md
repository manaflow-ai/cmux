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

Native work follows the [current build/test capacity owner](../../../AGENTS.md).
The dev-build fleet does not imply XCTest, simulator or GUI support. Use an
available supported recipe or the existing CI lane; report missing support
instead of bypassing scheduling with an old SSH/VM command.

## Native app versus test compilation

A tagged `reload.sh` build proves the app target built. It says nothing about
whether `cmuxTests`, `cmuxUITests`, package tests or test-only imports compile.
For authorized local native test compilation, the existing wrapper is:

```sh
./scripts/test-unit.sh -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>-tests" build-for-testing
```

Use `build-for-testing`, not `build`: the latter skips the test target. Like
CI, the wrapper builds `cmuxTests` without a Swift module, so a one-test-file
edit skips a serial ~26 s emit-module step; set `CMUX_TEST_EMIT_MODULE=1` to
keep the module, for example to inspect test frames in lldb. This
still does not execute tests. Execute the focused selection through the supported
test lane and record how many ran; a zero-test invocation is not verification.
Keep test DerivedData separate from the app tag's directory: a failed test build
can leave an unsigned test bundle that breaks the next app CodeSign step.
For `cmuxApp`/`AppDelegate` changes, retain the current GlobalISel workaround
when required by project instructions.

## UI and socket checks

## E2E and UI tests

Run through GitHub Actions or the VM. Never launch an untagged app locally to satisfy socket or UI tests.

Dispatch through the wrapper. It pins the exact pushed commit, carries a `dispatch_id` so the run is resolvable, and returns the run URL:

```bash
./scripts/run-e2e.sh cmuxTests/YourTestClass --ref <pushed-commit-sha> --wait
```

`gh workflow run test-e2e.yml` on its own is always rejected: `test_filter` is a required input, and without `--ref` the dispatch lands on whatever ref happens to be current rather than the commit you meant to test.

**Compile the test target locally before dispatching.** One focused run costs 10-20 macOS runner-minutes, and it compiles the whole tree before it runs anything, so the most common red result on a feature branch is a Swift compile error rather than a test failure. The `cmux-unit` command above catches those in a fraction of the time and without a runner.

**The wrapper picks the runner; leave `--runner` off.** Commits whose SHA ends in an odd hex digit compile on `blacksmith-12vcpu-macos-26`, the rest on `blacksmith-6vcpu-macos-26`, so the two sizes are compared on real traffic. Every dispatch at one commit lands on the same pool, which is what lets the wrapper reuse a run already in flight there. Over 60 consecutive dispatches (2026-09-22/23) the macOS 15 pool queued for a median 2.4 min but a p90 of 83 min and a worst case of 178 min, while macOS 26 queued 0.3 min median / 1.0 min p90. Pass `--runner blacksmith-6vcpu-macos-15` only when the question is specifically about macOS 15 behavior, and expect to wait for it.

**Do not dispatch `test-macos-suite.yml` for one test.** It runs a whole test target, compiles cold every time, and has none of the wrapper's reuse or refusal. A single-test dispatch there costs about 20 macOS runner-minutes for an answer the wrapper would share.

**Do not re-dispatch the same selector at the same commit.** A focused run's result is a property of the commit; repeating it reprints the same failure at full cost. The wrapper now refuses a selector that already failed at that commit and points at the earlier run; read that run, fix the branch, push, and dispatch the new commit. `--force` exists for the rare case where you know the failure was infrastructure.

If a run fails with `selected test filter matched zero tests`, the selector is wrong or the test file is not wired into `project.pbxproj` (see the test wiring section of SKILL.md). Fix the selector; retrying an unmatched filter costs another full build and matches nothing again.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.

For CLI dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`, not the global
`/tmp/cmux-cli` symlink. Confirm the tested artifact is the one you launched.
