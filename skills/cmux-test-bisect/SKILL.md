---
name: cmux-test-bisect
description: "Find when and why tests broke on main: bisect a Swift package suite on CI across old commits, read the failure matrix, and decide per test whether the test went stale or the code regressed. Use when a suite is red on main, when PR CI only ran filtered tests and the full suite has drifted, or when asked which PR broke a test."
---

# cmux test bisect

PR CI runs selected tests, so a package suite can stay red on main for weeks
with nobody noticing. This skill finds the commit behind each failure on CI,
never on the Mac (no full cmux builds on laptops).

App-host (`cmuxTests`) failures on main have their own automatic bisect
(#14510). Use this skill for the SwiftPM package suites under `Packages/iOS` and `Packages/Shared` that `test-ios.yml` can run
(`CMUXMobileCore`, `CmuxSyncStore`, `CmuxMobilePairedMac`, `CmuxMobileChanges`,
`CmuxMobileShell`, `CmuxMobileShellModel`).

## Before you start

1. Get today's failing set from the red run:
   `gh run view <run> --repo manaflow-ai/cmux --log-failed`, then grep `✘ Test .* failed after`.
   Run the full suite twice if you have not already. A test that appears in
   only one run is a flake candidate, not a regression.
2. Search for an existing fix: `gh search prs --repo manaflow-ai/cmux --state open '<test name>'`.
3. Work in your own worktree from `upstream/main`. If `git log` stops at a
   recent commit, the checkout is shallow: `git fetch --shallow-since=<date> upstream main`.

## Run the bisect

```bash
T=scripts/ci/package_bisect.py
python3 $T --package CmuxMobileShell start --points 6 <old-sha>..upstream/main
python3 $T --package CmuxMobileShell status --wait     # up to 45 min
python3 $T --package CmuxMobileShell next --dispatch   # split each break window
python3 $T --package CmuxMobileShell cleanup           # delete probe branches
```

- Each probe pushes `bisect/<name>/<sha10>` (the name defaults to the package): the old commit with today's iOS
  CI files laid over it and the package-lint gate dropped. Old commits carry
  old CI scripts, which is why a plain `-f ref=<sha>` dispatch fails early.
- Probes leave the runner on `auto` (idle owned mini first, Blacksmith
  overflow). Do not pin a runner.
- `adopt <sha> <run-id>` counts a run that already exists, for example the red
  main run, without dispatching again.
- `--filter <regex>` narrows the suite once you are chasing a few tests;
  `--paths` changes which commits count as midpoint candidates (default: the
  iOS and Shared packages).
- `--patch <sha>` (repeatable) applies a fix commit to every probe. Use it
  when older commits hang or fail to build for a reason you already know:
  bisect the question you have, not the known break.
- `--bisect <name>` keeps a second experiment (for example the same commits
  with a `--patch`) beside the first.
- State is shared by every worktree of the checkout, in
  `<git-common-dir>/package-bisect/<name>.json`. Finished job logs are cached
  beside it per run attempt, so `status --refetch` costs one run lookup per
  probe and downloads only logs it has not seen.

## Read the matrix

`status` prints one row per test and one column per probe, oldest first:
`X` failed, `.` passed, `-` never ran at that probe, `?` pending, `E` no test
ran at all (compile or runner failure; check the log, rerun the run, then
`status --refetch`; a rerun is a new attempt, so its log is read fresh).

Check the probe list first. A probe marked `INCOMPLETE` never printed its
"Test run with" summary: the hung-test watchdog killed it or the job timed
out, so every test after that point shows `-`. A `-` is never a pass: a suite
that hangs early makes a whole cluster look like it "broke" at the commit that
fixed the hang. Probe those commits again in a second bisect with the hang fix
applied: `start --bisect <pkg>-patched --patch <hang fix> <shas>`.

| Verdict | Meaning | Next |
| --- | --- | --- |
| `broken by <sha>` | Passed at the probe before, failed from here on | Read that PR's diff against the test |
| `broken in a..b (n watched commits)` | Window not yet one commit wide | `next --dispatch` |
| `failing at the oldest probe` | Older than the bisect | Start again further back, or trace with `git log -S '<symbol>'` |
| `fixed by` / `fixed in` | Failed, then something fixed it | Usually ignore; `next --fixed` splits these too |
| `flaky` | Passes between failures | Treat as a flake; confirm with a focused rerun before fixing |

Tests that break in the same window usually share one cause. Fix the cluster
together.

## Stale test or regression

Read the culprit PR, then decide per test:

- **Stale test**: the PR changed behavior on purpose and says so (PR body,
  code comments, or other tests it updated in the same direction). Fix the
  test to express its original intent under the new behavior. Do not delete
  the assertion. If the old fixture now models the other case, keep a test
  for each.
- **Regression**: the test's intent still holds and nothing in the PR argues
  it away. Fix the code, and keep the test as it was.
- When unsure, prefer the reading that keeps the test's name true, and say
  which reading you chose in the PR.

## Land it

- One small PR per culprit or cluster, pushed to the org remote
  (`git push mf <branch>`, `gh pr create --head <branch>`).
- Credit the PR that changed the behavior (link it, and mention its author).
- Prove it with the focused suites: `gh workflow run test-ios.yml --repo
  manaflow-ai/cmux --ref <branch> -f swift_package=<pkg> -f test_filter='<SuiteA|SuiteB>'`.
  Finish with one full-suite run on the last PR.
- Run `cleanup` so no `bisect/` branches stay on the org remote.
