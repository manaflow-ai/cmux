---
name: cmux-testing
description: "Choose scoped cmux verification, add behavioral tests, and validate Swift test targets and wiring. Use when adding tests or deciding what local/CI evidence a change needs."
---

# cmux Testing

## Choose the first check

Run repository commands only from a [trusted checkout](../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

| Task | Command |
| --- | --- |
| Choose checks and parse changed Swift | `python3 scripts/verify-local.py` |
| Run the full CI static recipe | `python3 scripts/verify-local.py --all` |
| Parse current Swift edits | `python3 scripts/verify-local.py --only swift-syntax --swift-changed` |
| Check new Swift test-file wiring | `python3 scripts/verify-local.py --only test-wiring` |

Add a base ref after `--swift-changed` to include committed changes. Use `--list`
to find other checks and `--help` for options. Parsing checks syntax; it doesn't
typecheck or run tests.

Read the [command guide](../../docs/verification-receipts.md) for piped paths or
JSON receipts. Use the [validation guide](references/local-vs-ci-validation.md)
to choose package, native, web or runtime checks. Docs and portable tooling use
their scoped checks.

## Reproduce and repair

Keep a focused command that fails on the reported symptom, then rerun it after
the repair. Setup failures and zero executed tests don't demonstrate the bug.
Exercise one behavior at a time so a failure identifies what needs fixing.

Keep the failing test and repair in separate commits. Record both SHAs and the
red/green command; push both together when reproduced locally. Follow the root
[regression policy](../../CLAUDE.md#regression-test-commits) for CI-only failures
and final-head checks.

## Test wiring

New `cmuxTests/*.swift` files need both PBXFileReference and Sources build-phase
membership in `cmux.xcodeproj/project.pbxproj`. Add through Xcode or follow a wired
sibling, then run the wiring check above: an unwired file can otherwise produce
a misleading zero-test pass.

After creating, renaming, or deleting a direct `cmuxTests/*.swift` file, run `./scripts/sync-test-wiring`. It deterministically reconciles the `PBXFileReference`, `PBXBuildFile`, `cmuxTests` group child, and `cmuxTests` Sources membership; `--check` performs the same validation without writing. Foreign target membership is rejected with an explicit diagnostic. The `workflow-guard-tests` CI job still runs `./scripts/lint-pbxproj-test-wiring.sh` as a defensive Sources-phase guard.

## Test quality

- Exercise observable behavior through unit, integration, CLI or end-to-end paths.
- Do not assert source snippets, signatures, AST shape or metadata keys solely
  to mirror implementation. For metadata behavior, inspect the produced artifact
  or execute the code that consumes it.
- Add a small runtime harness when needed; skip a fake regression test if there
  is no meaningful behavioral oracle and explain the limit. See
  [regression and quality](references/regression-and-quality.md) for the judgment call.

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

For remote tmux sizing changes, use the [E2E recipe](references/remote-tmux-sizing-e2e.md).
