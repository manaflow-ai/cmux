# Regression and Test Quality

## Regression commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. Add the failing test only.
2. Add the fix.

This makes it visible in GitHub that the test fails without the fix and passes with it.

## Behavioral tests

Tests should verify observable runtime behavior through executable paths:

- unit
- integration
- E2E
- CLI
- artifact-level behavior of a built product

Avoid tests that only verify:

- source code text
- method signatures
- AST fragments
- grep-style patterns
- checked-in plist/project/config snippets

For metadata changes, prefer testing the built app bundle or the runtime behavior that depends on the metadata. If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and say so.

## Test wiring

Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`.

A `.swift` file added to `cmuxTests/` without matching project entries can be silently ignored by Xcode. Both targeted `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews can pass with "Executed 0 tests".

The `workflow-guard-tests` job runs:

```bash
./scripts/lint-pbxproj-test-wiring.sh
```

When hand-editing wiring, use a wired sibling like `TabManagerUnitTests.swift` as the template.

## When tests missed a bug

When the user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.

Do not add a broad implementation-shape test that would have passed while the user-visible bug remained.
