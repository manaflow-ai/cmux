# Fast local verification

Run this before spending time on a native build or pushing a change to CI:

```sh
python3 scripts/verify-local.py
```

This is a **local pre-build/pre-CI static sanity check**. It selects from the existing
production checks in CI's `static-preflight` job and parses changed Swift files.
CI keeps the full static recipe; local `--all` runs that same recipe without
Swift parsing. No downloads, dependency installation, app launch or provider
credentials are needed. Swift parsing needs `swiftc` on PATH. Python 3, Bash, Git, and standard
Unix tools must be available. Run only in a trusted CMUX checkout: the command
executes that checkout's existing scripts.

It catches malformed localization catalogs, stale generated policy, project
configuration errors, Swift tests omitted from their Xcode target, package
layout mistakes and feature-flag policy violations. For example, adding
`cmuxTests/NewTests.swift` without target membership fails immediately with the
filename, before an expensive build or a misleading zero-test run.

## Automatic selection

The plain command compares against local `upstream/HEAD`, then `origin/HEAD`.
It includes committed branch changes, dirty edits and nonignored new files, and
prints the chosen base. It does not fetch: these refs may be stale. Use
`--affected BASE` and `--swift-changed BASE` when a stack or another comparison
needs an explicit base. Without a usable base, it runs all static checks and
parses local Swift edits against HEAD.

`--list` previews selection; `--all --list` lists every available check.
`--all` forces all static checks. Explicit `--only` or `--affected` selection
disables automatic defaults; Swift selection flags still compose with them.
Under `CI` or `GITHUB_ACTIONS`, the default remains the full static recipe
without automatic parsing. Receipts record automatic selection and its base.

## Select checks from changed inputs

```sh
python3 scripts/verify-local.py --affected
python3 scripts/verify-local.py --affected origin/main --list
python3 scripts/verify-local.py --affected origin/main --receipt -
```

`--affected` selects from local edits, including new and deleted files. Supply a
base ref to include committed branch changes since its merge-base with HEAD.
`--list` explains the static selection without running checks. Combine
`--affected` with `--swift-changed` to also parse changed Swift files, or use
`--only` instead when you want to choose checks yourself.

Selection covers the eight checks below. Each checker declares its file inputs
in `CHECK_INPUTS` in `scripts/verify-local.py`; update those declarations when a
checker gains dependencies. Unknown paths select all eight checks. Known prose
changes omit unrelated checks, while feature-flag expiry policy always runs
because its result depends on today's date. This does not select native tests
or the separate CI workflow guards.

The receipt records changed paths, selection reasons, and omitted checks as
`skipped`, with `executed: false`. An omitted check has no cached passing result.
Before/after hashes detect changes to the selected diff's file contents, including
untracked files; matching observations still do not establish an exact snapshot.

## Iterate on a smaller scope

```sh
python3 scripts/verify-local.py --all --list
python3 scripts/verify-local.py --only project --only test-wiring
python3 scripts/verify-local.py --only localization
python3 scripts/verify-local.py --receipt /tmp/cmux-preflight.json
```

For a Swift edit, let Git select the files to parse before a native build:

```sh
# Default static checks plus staged, unstaged and nonignored untracked Swift:
python3 scripts/verify-local.py --swift-changed
# Also include committed branch changes since the merge-base with a local ref:
python3 scripts/verify-local.py --swift-changed origin/main
# Just parsing during the edit loop:
python3 scripts/verify-local.py --only swift-syntax --swift-changed
```

The default base is HEAD, so supply a base ref when checking already-committed
work. Base refs must exist locally; the command does not fetch or guess a remote.
It parses the **current working-tree contents**, including dirty edits, rather
than extracting an immutable version from that ref. Deleted files are excluded;
renamed destinations are included. Git-ignored files and untracked files in the
managed `.glaeda/apple-build/` cache are excluded. `--swift FILE ...` still accepts an explicit
selection, and selectors can be combined (duplicate paths run once).

For shell composition, paths are checkout-relative and stdin is NUL-delimited,
so spaces, quotes and newlines in filenames survive. Non-Swift paths are ignored:

```sh
set -o pipefail
git diff --name-only -z --diff-filter=ACMR HEAD -- |
  python3 scripts/verify-local.py --only swift-syntax --swift-stdin0 --receipt - |
  jq '{outcome, selection: .evidence.swift_selection}'
```

Use your own producer for a different scope: the pipeline above selects tracked
changes only. `git ls-files --others --exclude-standard -z` selects untracked files;
`--swift-changed` includes both without constructing a pipeline. `--receipt -`
writes only JSON to stdout and sends diagnostics to stderr. Keep `pipefail` so a
producer or verification failure is not hidden by a successful final consumer.

This opt-in check needs `swiftc`
on PATH and runs `-frontend -parse -swift-version 5 -D DEBUG -enable-bare-slash-regex`.
It does not resolve imports, expand macros, typecheck, compile, execute tests, or
validate every conditional-compilation configuration. Use the intended toolchain;
parsing with a newer compiler does not prove compatibility with an older one.
The default Linux CI recipe remains the eight portable checks below.

Receipts record the parser version, exact argv, selected-file hashes before and
after, selection origin/resolved base, and a separate `parsing` result. Missing
`swiftc` with selected files is `unsupported`. An empty changed/stream selection
reports `skipped` with `reason: no_swift_inputs` and exits 0; it never claims parsing
passed. Other selected checks still run. Missing explicit files, malformed stdin,
or an unresolved base are errors. Selected-file content drift interrupts the result, including
untracked files whose Git status stays unchanged. These observations still do not
establish an isolated snapshot of the entire checkout.

The `swift-failed.json` and `swift-repaired.json` examples replay the PR-head file
behind [a real CI syntax failure](https://github.com/manaflow-ai/cmux/actions/runs/35525568719/job/106117704441).
That CI compile step lasted 12m14s. The local parser rejected the original file in
0.132s and accepted the missing-backslash repair in 0.075s on the recorded compiler.
Those are single observations, not a build-speed benchmark or proof that the
repaired tests compile or pass. The example identifies the source file and SHA;
it does not assert that the entire CI checkout equals the PR head.

| Check ID | Existing validation |
| --- | --- |
| `xcstrings` | Localization catalog structure |
| `localization` | macOS localization parity |
| `project-tests` | Five project normalizer unit tests at the demonstrated revision; counts are read from each execution |
| `project` | Xcode project version pin and normalization |
| `launch-policy` | Generated Claude launch policy is current |
| `test-wiring` | Every Swift test file belongs to the Xcode test target |
| `package-groups` | Workspace Swift package grouping |
| `feature-flags` | Flag names, ownership, expiry, defaults, single evaluation and retired keys |

Each failure prints a bounded diagnostic tail and an exact `--only` rerun command.
The default runs all eight checks so one pass reveals independent failures.
`--only` runs the named subset and says which checks actually ran; it does not
infer affected tests from a diff. `--repo` targets another checkout. Each check
has a 60-second deadline, adjustable with `--timeout`; Ctrl-C stops the active
process group and marks the remaining checks skipped.

Exit 0 means the selected checks passed or only an empty Swift selection was
skipped; inspect the receipt's status to distinguish them. Failure, missing tools,
interruption, or observed source drift returns nonzero. Unchanged dirty-source
observations retain their qualification. A zero-test unittest success is a failed
test claim, including when assessing a previously supplied receipt.

**This does not compile or typecheck Swift, run native app tests, package an app,
or verify UI behavior.** For Swift/UI changes, continue with the normal tagged
native build/test workflow in CONTRIBUTING.md. A passing preflight is not merge
readiness. Existing CI policy and native execution owners remain authoritative.

## Evidence for handoff

`--receipt` writes `cmux-verification/v1` JSON. Keep the file outside the checkout.
It records each command's status, exit code, script/output hashes, duration,
source observations and available test counts. Raw logs, environment variables
and checkout paths are not copied into it. Human diagnostics remain local to
this invocation. The committed `tests/fixtures/verification_receipt/examples/preflight.json`
is a real full local run: eight passing checks and five executed normalizer tests,
with dirty-source qualification. It is one observation, not a performance benchmark.

| Field | Meaning |
| --- | --- |
| `recipe` | Named scope, recipe revision and invocation |
| `source` | Repository, PR/head/checkout/base/merge/tree identities when known, before/after observations, source semantics |
| `checks` | Separate static analysis, preparation, parsing, typechecking, tests, packaging and live status |
| `tests` | Selection expressions and selected/discovered/executed counts; null means unknown, not zero |
| `evidence` | Per-command executions locally; original run/job/step identities and conclusions for CI imports |
| `artifacts` | Separate produced/launched identities; null means not observed, not proof that no artifact exists |
| `review` | Reviewed/current head and availability; unsupported for these local checks |
| `assessment` | Source/review/artifact qualifications, not acceptance authority |

Statuses remain `passed`, `failed`, `skipped`, `unsupported`, `interrupted`, with
an independent `executed` boolean. `outcome` summarizes this preflight's selected
scope. Test counts come from a single terminal unittest summary: runner total
minus skipped tests. No independent selected/discovered inventory is invented.
A subset containing only lints has no test-execution claim.

Before/after observations are not an atomic snapshot or lock. Matching HEADs and
even clean observations cannot rule out transient edits, untracked content,
ignored files or external input changes. `exact_verification` stays false.
Observed source drift interrupts the overall preflight result and asks for a rerun.

## Existing CI result import

The original narrow docs-auth recipe adapter remains available for compatibility:

```sh
python3 scripts/verification_receipt.py local
python3 scripts/verification_receipt.py replay-ci tests/fixtures/verification_receipt/examples/ci-input.json
python3 scripts/verification_receipt.py ci --run /tmp/run.json --job /tmp/job.json --log /tmp/job.log
```

`local` on this lower-level adapter runs only `tests/test_docs_deploy_auth_guard.py`;
use `verify-local.py --all` for the full static recipe. The CI importer accepts GitHub's
existing run/job JSON and job log for that docs-auth step. Keep raw downloads
private. The committed example preserves three passing tests inside a failed
workflow, with checkout merge `25930fe8a91012ad178343016774d6850d5fd3db` different
from PR head `e0deb0e897e58de722015e714700b2ec6c220bc6`. Missing source/workflow
observations stay unknown. Caller-supplied logs are evidence, not authenticated
attestations; the example's log hash covers its minimised excerpt.

## Tests

```sh
python3 tests/test_verification_receipt.py
python3 tests/test_verify_local.py
```

Temporary-Git tests exercise real subprocesses, an actual unwired-test failure
and repair, zero-test success, source drift, missing executables, bounded failure
diagnostics and interruption. Stale review/wrong tagged artifact cases remain
synthetic fixtures. Neither adapter establishes a real native artifact handoff
or immutable exact-source execution.
