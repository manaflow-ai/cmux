---
name: cmux-testing
description: "cmux testing rules for Swift Testing, test target compilation, and package/refactor validation. Use when adding or changing tests, touching package/refactor code, or deciding whether reload.sh is enough validation."
---

# cmux Testing

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI that the test genuinely fails without the fix.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Test framework

Swift Testing is the current Apple-supported primitive for tests on this codebase (shipped with Swift 6 / Xcode 16, supported on the macOS versions we target). Use it for everything that is not a UI test.

- **Default to Swift Testing for all unit and integration tests.** `import Testing`, annotate tests with `@Test`, group with `@Suite`, assert with `#expect(...)` and `try #require(...)`. Do not write new tests with `import XCTest` unless they are UI tests.
- **UI tests stay on XCTest / XCUITest.** Swift Testing does not support UI testing (no `XCUIApplication` integration). Files under `cmuxUITests/` continue to use `XCTestCase` + `XCUIApplication`. Do not migrate them and do not try to bridge Swift Testing into UI tests.
- **New test targets start on Swift Testing.** Every new Swift package's `Tests/<Name>Tests/` directory (e.g. `Packages/CmuxSettings/Tests/CmuxSettingsTests/`) should ship with Swift Testing from the first commit. Xcode 16 auto-detects the framework based on the `import Testing` statement; no extra `Package.swift` configuration is required.
- **Migration guide when touching an existing XCTest test.** Convert in place: `XCTestCase` subclass becomes a `@Suite struct` (or `final class` if you need a reference type); each `func testFoo()` becomes `@Test func foo()`; `XCTAssertEqual(a, b)` becomes `#expect(a == b)`; `XCTAssertTrue(cond)` becomes `#expect(cond)`; `XCTUnwrap(x)` becomes `try #require(x)`; `XCTFail("msg")` becomes `Issue.record("msg")`. `setUp()` becomes `init()` on the suite; `tearDown()` becomes `deinit`. Async setup is `async init()`. Do not bulk-rewrite untouched tests; migrate incrementally as a side effect of editing the file.
- **Parameterized tests** use `@Test(arguments: [...])`. Prefer this over duplicate test methods.
- **Parallelization and shared state.** Swift Testing runs tests in parallel by default, including across suites. If a suite genuinely needs ordering or guards shared mutable state, annotate it with `.serialized` instead of adding locks or sleeps.
- **Tags** with `@Test(.tags(.something))` (or on a `@Suite`) let CI and local runs filter selectively.

## Test target validation

`reload.sh` does not compile the test target. It builds only the `cmux` scheme, so a green `reload.sh` says nothing about whether `cmuxTests`/`cmuxUITests` still compile. A symbol that is moved or renamed can keep the `cmux` app building while breaking the test target (real case: a `write(to:atomically:)` typo and a removed `TabManager.CommandResult` only surfaced in the `tests` job). Before pushing package/refactor changes, build the `cmux-unit` scheme (with `-derivedDataPath /tmp/cmux-<tag>` and, for `cmuxApp`/`AppDelegate` churn, the GlobalISel workaround flag) or let the `tests` CI job gate it — never treat `reload.sh` alone as proof the tests build.

## Detailed references

- Read [references/swift-testing-migration.md](references/swift-testing-migration.md) when converting XCTest unit tests to Swift Testing or adding new package tests.
- Read [references/regression-and-quality.md](references/regression-and-quality.md) when adding a regression test, deciding whether a test is behavioral enough, or checking Xcode project test wiring.
- Read [references/local-vs-ci-validation.md](references/local-vs-ci-validation.md) when choosing between `reload.sh`, `cmux-unit`, GitHub Actions, E2E/UI tests, and Python socket tests.
