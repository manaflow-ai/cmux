---
name: cmux-testing
description: "cmux testing rules for Swift Testing, test target compilation, test wiring, and package/refactor validation. Use when adding or changing tests, touching package/refactor code, or deciding whether reload.sh is enough validation."
---

# cmux Testing

## Regression test commit policy

A regression test for a bug fix ships as two commits so CI proves the test catches the bug:

1. The failing test only, no fix. CI goes red.
2. The fix. CI goes green.

The GitHub PR Commits tab then shows the test genuinely fails without the fix.

## Test wiring

Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj` with a matching `PBXFileReference` and `PBXSourcesBuildPhase` entry. A `.swift` file added without them is silently ignored by Xcode: `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews both pass with "Executed 0 tests", so the missing wiring is indistinguishable from a clean red/green regression test until a real user hits the bug. Surfaced during https://github.com/manaflow-ai/cmux/issues/4529 against https://github.com/manaflow-ai/cmux/pull/4536.

The `workflow-guard-tests` CI job runs `./scripts/lint-pbxproj-test-wiring.sh`. Add the file through Xcode (drag into the cmuxTests target) or hand-edit the pbxproj entries using a wired sibling such as `cmuxTests/TabManagerUnitTests.swift` as the template.

## Test quality policy

- No tests that only verify source text, method signatures, AST fragments, or grep-style patterns.
- No tests that read checked-in metadata or project files (`Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, source files) just to assert a key, string, plist entry, or snippet exists.
- Tests verify observable runtime behavior through executable paths (unit, integration, e2e, CLI), not implementation shape.
- For metadata changes, verify the built app bundle or the runtime behavior that depends on the metadata.
- If a behavior cannot be exercised end to end yet, add a small runtime seam or harness first, then test through it.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and say so.

## Test framework

Swift Testing (Swift 6 / Xcode 16) is the default for every unit and integration test: `import Testing`, `@Test`, `@Suite`, `#expect(...)`, `try #require(...)`. Do not write new `import XCTest` tests except UI tests.

- **UI tests stay on XCTest/XCUITest.** Swift Testing has no `XCUIApplication` integration. Files under `cmuxUITests/` keep `XCTestCase`; do not migrate or bridge them.
- **New test targets start on Swift Testing.** Every new package's `Tests/<Name>Tests/` ships with it from the first commit; Xcode 16 auto-detects the framework from `import Testing` with no `Package.swift` configuration.
- **Parameterized tests** use `@Test(arguments: [...])` instead of duplicate methods.
- **Parallelization.** Swift Testing runs tests in parallel by default, including across suites. A suite that needs ordering or guards shared mutable state gets `.serialized`, not locks or sleeps.
- **Tags** via `@Test(.tags(.something))` let CI and local runs filter selectively.
- Migrate an existing XCTest file in place only when an edit already crosses it. Mapping in [references/swift-testing-migration.md](references/swift-testing-migration.md).

## Test target validation

`reload.sh` builds only the `cmux` scheme, so a green reload says nothing about whether `cmuxTests`/`cmuxUITests` still compile. A moved or renamed symbol can keep the app building while breaking the test target (real case: a `write(to:atomically:)` typo and a removed `TabManager.CommandResult` surfaced only in the `tests` job). Before pushing package/refactor changes, build the `cmux-unit` scheme with `-derivedDataPath /tmp/cmux-<tag>` (plus the GlobalISel workaround flag for `cmuxApp`/`AppDelegate` churn), or let the `tests` CI job gate it.

## Detailed references

- [references/swift-testing-migration.md](references/swift-testing-migration.md): XCTest to Swift Testing conversion mapping.
- [references/regression-and-quality.md](references/regression-and-quality.md): deciding whether a test is behavioral enough.
- [references/local-vs-ci-validation.md](references/local-vs-ci-validation.md): choosing between `reload.sh`, `cmux-unit`, GitHub Actions, E2E/UI tests, and Python socket tests.
- [references/remote-tmux-sizing-e2e.md](references/remote-tmux-sizing-e2e.md): the remote-tmux mirror sizing UI suite, its ssh shim, the `remote.tmux.pane_grids` / `remote.tmux.test_exec` debug verbs, and the live layout fuzz harness.
