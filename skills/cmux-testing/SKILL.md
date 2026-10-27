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
| Decide whether a red web test is the PR's fault or a flake | `python3 scripts/ci/web_test_verdict.py --pr <N>` ([guide](references/web-test-flakes.md); `--coverage` runs the PR's code) |
| Get before and after perf numbers for a change | perf-lead.md fleet benches; `python3 -I scripts/perf-lab/lab.py try --base <sha> --head <sha> --wait` when it is on your base ([perf try receipts](#perf-try-receipts)) |

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

## Perf try receipts

This section is the one source for the try command, the receipt format and the
verdict rules. AGENT-BRIEF.md and REVIEW.md link here.

A perf claim ("faster", "no regression", before and after numbers) needs fleet
numbers. Two kinds of evidence apply:

- **Budgets.** The light and STRESS session benches in
  [perf-lead.md](../../plans/cmux-next/perf-lead.md#1-targets) (`bench-typing.py`,
  `perf-stress-session.py`, the `perf-budgets` rows) show that an action meets
  its budget. They are the evidence now, and a try receipt does not replace them.
- **Before and after.** `lab.py try` gives a same-host A/B verdict for one
  change. It is available only when `scripts/perf-lab/lab.py` and its `try`
  subcommand are on your base (p12 tasks 005 and 018). Until then, give the
  perf-lead.md bench numbers for the base and the head. When it is available,
  paste its receipt in addition to any budget numbers.

Push both commits, then run:

```bash
python3 -I scripts/perf-lab/lab.py try --base <base sha> --head <head sha> --stories <a,b> --wait
```

- Give full 40-character shas. The base is the change's merge base or parent.
- The lab builds both shas and runs 20 ABBA attempts per arm on one host
  (`--attempts N` changes the count). The try queue (task 235,
  `scripts/perf-lab/try_admission.py`) puts the job on a free fleet Mac with the
  `measure` label, never on a perf-lab host. A session can have 3 unfinished try
  jobs; the queue refuses a 4th and names the 3.
- To measure a default-off feature, give the same sha as base and head and add
  `--feature <name>=on` (or `=off`). The flag changes the head arm only. The
  receipt line does not show the flag, so write the `--feature` argument next
  to the pasted lines.
- The submit output names the job: `Perf try job <id>: ...`. A wait timeout
  leaves the job running. To wait again, run the same command again: the queue
  joins the unfinished job with the same base, head, stories and features
  (task 235 dedupe), and adds no work. `--attempts` is not part of that key, so a
  changed `--attempts` joins the running job at its old count. Do not change the
  base, head, stories or features to wait: that starts a second job.

The command prints one receipt line per metric, as task 018 specifies it:

```text
Perf try <story>.<metric> @<host-class>: base p50/p95/p99 -> head p50/p95/p99 (delta %), MWU p, KS p, strict DIFFERENT|SAME|UNKNOWN (floored X), job <id>
```

p = min(MWU p, KS p), two-sided. The sign of `delta %` gives the direction:
for time and memory metrics, a negative delta is better. `strict` is
Pinpoint's original rule (DIFFERENT only at p <= 0.01). `floored X` is the
bisect rule (DIFFERENT at p <= 0.05) and never supports a claim alone. Each
claim needs this verdict:

| Claim | Receipt must show |
|---|---|
| "faster" (or "smaller") | strict DIFFERENT, with `delta %` in the better direction, on each metric you name |
| "no regression" | strict SAME on every metric of the stories you ran |
| none ("not proven") | strict UNKNOWN, or floored DIFFERENT in the worse direction. Run a new try with more attempts (`--attempts 40`) after the first job ends. Do not report it as "no regression". |
| a regression | strict DIFFERENT in the worse direction. Fix it, or name it in the PR. |

Paste the lines without changes in the commit message or PR body. The lab
rules are in
[p12-perf-process.md](../../plans/cmux-next/chrome-parity/p12-perf-process.md#36-pinpoint)
(section 3.6 and rule R5).

## Test wiring

App tests live in `Packages/macOS/CmuxNext/Tests/<Module>Tests`; SwiftPM discovers
them, so no project wiring is needed. The `cmux` CLI is the cmux-tui Rust
binary (plans/cmux-next/cli.md); its tests live in `cmux-tui/` and run with
cargo on a Blacksmith Testbox or in CI. Maintainers never run cargo on the
local Mac; outside contributors, who cannot dispatch hosted verification, run
focused tests locally as described in `cmux-tui/AGENTS.md`.

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
