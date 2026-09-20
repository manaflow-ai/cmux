---
name: cmux-testing
description: "Choose scoped cmux verification, add behavioral tests, and validate Swift test targets and wiring. Use when adding tests or deciding what local/CI evidence a change needs."
---

# cmux Testing

## Choose scope first

Use [the validation guide](references/local-vs-ci-validation.md) to choose portable,
native, web or UI verification. `python3 scripts/verify-local.py` runs the shared
fast CI static checks; `--list` and `--only <check>` support focused iteration.
Static success is not compilation, test execution or UI verification. Docs and
portable-tooling changes do not automatically need a native build.

## Regression commits

Keep the failing behavioral test and repair in separate commits. Record both
SHAs and the same focused command failing before and passing after; push both
together when reproduced locally. Follow the root [regression policy](../../CLAUDE.md#regression-test-commits)
for CI-only failures and final-head checks. Setup failures and zero tests do not
prove the regression.

## Test wiring

New `cmuxTests/*.swift` files need both PBXFileReference and Sources build-phase
membership in `cmux.xcodeproj/project.pbxproj`. Add through Xcode or follow a wired
sibling. Run `python3 scripts/verify-local.py --only test-wiring` before an expensive
test build: an unwired file can otherwise produce a misleading zero-test pass.

## Test quality

- Exercise observable behavior through unit, integration, CLI or end-to-end paths.
- Do not assert source snippets, signatures, AST shape or metadata keys solely
  to mirror implementation. For metadata behavior, inspect the produced artifact
  or execute the code that consumes it.
- Add a small runtime harness when needed; skip a fake regression test if there
  is no meaningful behavioral oracle and explain the limit.

## Swift tests

Swift unit/integration targets use Swift Testing (`import Testing`, `@Test`,
`@Suite`, `#expect`, `#require`). Portable Python/shell guards retain their existing
frameworks. UI tests remain XCTest/XCUITest; do not migrate XCUIApplication tests.

New Swift package test targets start on Swift Testing. Prefer parameterized tests
for repeated cases and tags for selection. Use `.serialized` for suites that
require ordering, not locks or sleeps. Migrate an existing XCTest file only when
an edit already crosses it; see [the migration mapping](references/swift-testing-migration.md).

## Native test evidence

An app build does not compile test targets. Package/refactor and public API changes
need the relevant test target compiled, then the selected tests actually executed.
Follow [build-for-testing and execution guidance](references/local-vs-ci-validation.md)
and the current native capacity owner; report skipped/unsupported checks explicitly.

## References

- [Regression and quality](references/regression-and-quality.md)
- [Remote tmux sizing E2E](references/remote-tmux-sizing-e2e.md)
