# Local vs CI Validation

## `reload.sh`

Proves the app target built. Proves nothing about `cmuxTests`, `cmuxUITests`, package test targets, or test-only imports. For package/refactor work, treat it as insufficient on its own.

## Unit test target

`cmux-unit` is safe locally because it does not launch the app. Use it when package/refactor changes can break tests while the app target still builds; prefer CI when practical.

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

For `cmuxApp` or `AppDelegate` churn, add the repo's GlobalISel workaround flag if current project instructions require it.

## E2E and UI tests

Run through GitHub Actions or the VM: `gh workflow run test-e2e.yml`. Never launch an untagged app locally to satisfy socket or UI tests.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.
