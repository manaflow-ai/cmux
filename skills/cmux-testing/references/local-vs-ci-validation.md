# Local vs CI Validation

## `reload.sh`

Proves the app target built. Proves nothing about `cmuxTests`, `cmuxUITests`, package test targets, or test-only imports. For package/refactor work, treat it as insufficient on its own.

## Unit test target

`cmux-unit` is safe locally because it does not launch the app. Use it when package/refactor changes can break tests while the app target still builds; prefer CI when practical.

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build-for-testing
```

Use `build-for-testing`, not `build`: the scheme builds `cmuxTests` only for testing, so `build` compiles the app, skips every test file, and still reports success. Keep this in its own derived data path rather than the tag's (`~/Library/Developer/Xcode/DerivedData/cmux-<tag>`): a test build that fails leaves an unsigned `cmuxTests.xctest` inside the app bundle, and the next `reload.sh` for that tag then fails at CodeSign until the bundle is removed.

For `cmuxApp` or `AppDelegate` churn, add the repo's GlobalISel workaround flag if current project instructions require it.

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
