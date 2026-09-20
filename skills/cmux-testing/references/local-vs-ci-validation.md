# Choose verification for the change

Start with the smallest check that can expose the failure you are fixing. Use
`python3 scripts/verify-local.py --list` to see the fast static checks; run the
full command before a native build or push when those checks apply. A passing
preflight establishes only its named scope. See the [command guide](../../../docs/verification-receipts.md)
for focused reruns and evidence receipts.

| Changed area | Required useful evidence |
| --- | --- |
| Docs or instructions only | Check links and command examples against their owning scripts. No unrelated app build. |
| Portable Python/shell contributor tooling | Run the affected portable tests and exercise the command. No app build unless the tooling changes native build or runtime behavior. |
| CI workflow or build tooling | Run affected guards; exercise the native build/package/signing lane when that behavior changes. Keep authoritative CI gates. |
| Localization, project wiring, generated policy, feature flags | Run relevant preflight checks, then compile or exercise the affected app behavior where applicable. |
| Swift app/CLI implementation | Tagged native build plus focused behavioral tests. |
| Swift tests, public APIs, package/refactor changes | Compile the relevant test target and execute selected tests; report the executed count. Building the app alone is insufficient. |
| Web code | Run the relevant web package's checks/tests and verify its live preview. The static preflight does not typecheck web code. |
| UI or socket behavior | Exercise the changed behavior against the correct tagged app, plus relevant UI/E2E tests. |

Native work follows the [current build/test capacity owner](../../../AGENTS.md).
The dev-build fleet does not imply XCTest, simulator or GUI support. Use an
available supported recipe or the existing CI lane; report missing support
instead of bypassing scheduling with an old SSH/VM command.

## Native app versus test compilation

A tagged `reload.sh` build proves the app target built. It says nothing about
whether `cmuxTests`, `cmuxUITests`, package tests or test-only imports compile.
For authorized local native test compilation, the existing wrapper is:

```sh
./scripts/test-unit.sh -derivedDataPath /tmp/cmux-<tag>-tests build-for-testing
```

Use `build-for-testing`, not `build`: the latter skips the test target. This
still does not execute tests. Execute the focused selection through the supported
test lane and record how many ran; a zero-test invocation is not verification.
Keep test DerivedData separate from the app tag's directory: a failed test build
can leave an unsigned test bundle that breaks the next app CodeSign step.
For `cmuxApp`/`AppDelegate` changes, retain the current GlobalISel workaround
when required by project instructions.

## UI and socket checks

Use the existing supported UI/E2E workflow or approved machine recipe. Do not
launch an untagged app or infer GUI support from an idle dev-build worker.
Python `tests_v2/` needs a running instance; locally set
`CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock` for the intended tagged build.
For CLI dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`, not the global
`/tmp/cmux-cli` symlink. Confirm the tested artifact is the one you launched.
