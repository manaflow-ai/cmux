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
| Compile app package tests | `swift build --build-tests` in `Packages/macOS/CmuxNext` |
| Run one app module's tests | `swift test --filter <Module>Tests` in `Packages/macOS/CmuxNext` |
| Merge-gate source rules for the app | `scripts/cmux-next/check-no-godfiles.sh`, `scripts/cmux-next/check-concurrency.sh` |

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

Keep two commits: first the failing behavioral regression, then the fix. Run
the same focused command on both and record the commit SHAs, the expected
failure and the passing result. A setup failure or zero executed tests is not
regression proof. When the proof is available locally, push both commits
together after the fix passes; a separate hosted CI run on the deliberately
broken intermediate commit is unnecessary. If the failure only reproduces in CI,
use that lane and keep its receipts. Required CI and review still apply to the
final pushed head.

## Test wiring

App tests live in `Packages/macOS/CmuxNext/Tests/<Module>Tests`; SwiftPM discovers
them, so no project wiring is needed. CLI tests live in `cmuxCLITests/` (scheme
`cmux-cli-tests`, no app host). A new `cmuxCLITests/*.swift` file needs
PBXFileReference, group and Sources build-phase entries in
`cmux.xcodeproj/project.pbxproj`; follow a wired sibling. An unwired file can
produce a misleading zero-test pass.

`swift test` never launches `cmux DEV`. Daemon-backed suites start `cmux-tui`
hosts: check that no `__terminal-host` processes leak after a run.

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
frameworks.

New Swift package test targets start on Swift Testing. Prefer parameterized tests
for repeated cases and tags for selection. Use `.serialized` for suites that
require ordering, not locks or sleeps. Migrate an existing XCTest file only when
an edit already crosses it; see [the migration mapping](references/swift-testing-migration.md).

## Native test evidence

An app build does not compile test targets. Package/refactor and public API changes
need the relevant test target compiled, then the selected tests actually executed.
Follow [build-for-testing and execution guidance](references/local-vs-ci-validation.md);
report skipped/unsupported checks explicitly.

## PR CI labels

`full-ci` is not a review or merge requirement; see
[PR CI coverage](references/pr-ci-coverage.md) before adding either.
