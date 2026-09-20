# Contributor verification ladder

Choose the cheapest check that can disprove your change, then add the integration
checks its boundary requires. A documentation edit and a focus-routing change do
not need the same first step. Run commands from the repository root.

| Change | First useful proof | Follow-up before claiming the behavior works |
| --- | --- | --- |
| Docs or workflow/script policy | Links, syntax and the relevant script tests | Exercise the changed command or workflow when its behavior changes |
| Pure package logic | Focused package test, including the failing case | Package suite; app/test compilation if a public interface or integration changed |
| App ownership extraction | Parse changed files; focused behavior tests | App **and test** compilation; relevant runtime check |
| Shortcut, focus, window, socket or persistence behavior | Focused regression at the owning layer | Tagged runtime reproduction through each affected entrypoint |
| Rendering, accessibility, multi-display, macOS-version or iPhone behavior | Focused model tests where available | UI verification and physical dogfood on the affected environment |

## 1. Start with bounded source checks

```bash
git diff --check
./scripts/check-pbxproj.sh
./scripts/lint-pbxproj-test-wiring.sh
```

The project checks matter when adding or moving app/test files. An unwired test can
silently execute zero tests. For changed Swift files, `swiftc -D DEBUG -parse` followed
by their paths is an early syntax check only: it does not type-check imports, compile
the test target, or run assertions. Use the owning script/package's tests for logic
changes instead of tests that merely search source text for the new implementation.

For a bug fix, add a behavior regression that fails without the fix, then make it
pass. Keep the failing regression and repair in separate commits so reviewers can
reproduce both states. Do not describe an infrastructure failure as the expected
regression failure.

## 2. Test the owning package

For example, when changing the control socket package on macOS:

```bash
swift test --package-path Packages/macOS/CmuxControlSocket --filter ControlClientLineReaderTests
swift test --package-path Packages/macOS/CmuxControlSocket
```

Replace the package and filter with the actual owner. Check the reported test names
and count; a green command with no selected tests is not proof. Tests that require
AppKit, a simulator, a bundled executable, or a running app must use their supported
host. `scripts/ci/run-swift-testing-suites.sh <package-path>` is the existing bounded
suite runner for packages whose CI uses it; it preserves per-suite failures and
reports timeout retries. Do not treat its aggregate result as a latency sample
without including the retry.

Package tests establish package behavior, not app wiring. After changing a public
interface, compile the consumers and app-host test target below.

## 3. Compile the app and tests without launching them

Complete the [setup prerequisites](../CONTRIBUTING.md#getting-started) once. Use a
stable checkout and keep its native incremental state between edits. Choose one
owner for each DerivedData directory; never run concurrent builds against it.
Runtime tag isolation and build-cache ownership are separate concerns.

For an ordinary local contributor, build the tagged app without shared backend
credentials:

```bash
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag contributor-check --no-global-cli-links
```

This selects the local backend origin; it does not start a backend or make Cloud
features available. The script builds and prepares an isolated app, and without
`--launch` it does not open it. It can stop an existing app with the **same tag**:
use your own tag rather than borrowing another developer's session.

An app build does not compile all tests. In a separate, stable verification directory,
compile the app-host unit test product:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/.build/contributor-tests" build-for-testing
```

This is compilation only. Do not open its untagged product. Use `cmux` in place of
`cmux-unit` when compiling UI tests; use the appropriate dedicated scheme for tests
such as numeric-locale coverage. Confirm the command finished successfully and
preserve the build log. `build-for-testing` proves that the selected app and test
product compile, **not** that any test ran. It does not replace the tagged runtime
step below or required CI checks.

## 4. Exercise an isolated runtime

For local socket checks, launch the tag you built and explicitly route the test to
that tag's socket:

```bash
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag contributor-check --no-global-cli-links --launch
CMUX_SOCKET_PATH=/tmp/cmux-debug-contributor-check.sock python3 tests_v2/test_ctrl_socket.py
```

The socket script is an example, not a mandatory full suite. Pick the reproduction
for your change, read its prerequisites, and run it only against your disposable
session. These tests can create, focus, or close workspaces. Do not fall back to a
last-used/global socket if the tagged socket is unavailable. `reload.sh` checks
socket startup; a failed launch is a failure to investigate, not a reason to point
the test at the regular app.

For app-host or UI tests that launch an application, use the repository's isolated
CI harness or a dedicated disposable macOS GUI session. A compilation-only product
is not automatically a safely isolated test runtime. A plain `xcodebuild test` on
your everyday desktop can launch/focus the app under test. UI tests also need a
logged-in GUI session and any permissions or display setup their fixture requires.
If that environment is unavailable, report the missing runtime check and ask a
maintainer to run the exact selected test on your pushed revision.

### Maintainer option: dispatch a selected test

Contributors do not need GitHub Actions dispatch permission or a private Mac fleet.
A maintainer with access can use the existing exact-revision dispatcher:

```bash
python3 scripts/ci/dispatch-focused-test.py cmuxTests/SessionPersistenceTests --ref <pushed-commit-sha> --wait
```

Replace the selector with the regression; UI selectors use
`cmuxUITests/ClassName[/methodName]`. The dispatcher validates the revision/selector
and prints the run URL. This path needs authenticated `gh` access to the upstream
workflow and its runner capacity. It does not grant access to contributors or
replace the PR's required checks. Preserve the selected-test count, run URL,
revision, failures, cancellations and retries in the verification record.

## 5. Finish with the physical behavior the change affects

For native interaction changes, use the tagged app on the affected macOS version
and hardware. Verify the concrete before/after reproduction and every changed
entrypoint (for example, shortcut, palette and context menu). Accessibility output
or a screenshot alone may not establish keyboard focus, input delivery, persistence
across restart, or real display behavior. State exactly what you exercised.

For iPhone changes, a simulator pass does not establish physical input, networking,
or reconnection behavior. Use `ios/scripts/reload.sh --help` and the project's
[development workflow](../skills/cmux-dev-workflow/SKILL.md) to build the same-tag
Mac companion and install on an authorized physical device. Team sign-in/pairing
uses personal credentials outside the repository; it is not a prerequisite for
unrelated local contributions. Do not claim phone dogfood for a signed-out build
or an unreachable device. Record the missing check and the owner who will run it.

## Report evidence and stop at the right boundary

In the PR, record the exact commit, commands, environment, selected tests/counts,
and results. Separate source checks, compilation, executed tests and observed
runtime behavior. Include failed/cancelled attempts and unmet prerequisites; a
skipped check is not a pass. Link CI runs and attach relevant logs or result bundles
without secrets. State which integration/physical checks remain for a maintainer.

Keep reusable native caches and package state. Clean up only the disposable app,
workspaces and outputs owned by your test; do not kill other tags, wipe shared
DerivedData, or recreate the repository for each small edit.
