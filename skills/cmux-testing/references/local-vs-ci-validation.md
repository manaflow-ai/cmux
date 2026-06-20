# Local vs CI Validation

## `reload.sh`

`reload.sh` builds the Debug app for a tag. It does not compile the test target.

A successful reload proves the app target built. It does not prove:

- `cmuxTests` compile
- `cmuxUITests` compile
- package test targets compile
- test-only imports still resolve

For package/refactor work, treat reload as insufficient by itself.

## Unit test target

`xcodebuild -scheme cmux-unit` is safe because it does not launch the app. Prefer CI when practical, but use `cmux-unit` when package/refactor changes can break tests while the app target still builds.

Use a tagged derived data path:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

For `cmuxApp` or `AppDelegate` churn, include the repo's known GlobalISel workaround flag if required by current project instructions.

## E2E and UI tests

E2E and UI tests run via GitHub Actions or on the VM. Trigger E2E/UI through:

```bash
gh workflow run test-e2e.yml
```

Do not launch an untagged app locally to satisfy socket/UI tests.

## Python socket tests

Python socket tests under `tests_v2/` connect to a running cmux instance socket. If they must be run locally, use a tagged build socket:

```bash
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock
```

Never launch or target an untagged `cmux DEV.app` for these tests. It can conflict with the user's running debug instance.
