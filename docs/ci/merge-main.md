# Merging main into a branch

`scripts/merge-main.sh` is how an agent or a person brings a branch up to date
with main. It exists because of 2026-09-25: #14724 broke
`tests/test_runner_label_policy.py` on main, a branch merged main in the hour
before #14742 fixed it, its guards failed on push, the macOS admission gate
declined compile admission, and nobody knew the failure was main's until the
logs were read.

What it does, in order:

1. Fetches `main` from whichever remote points at `manaflow-ai/cmux`.
2. Picks the newest first-parent main commit the branch lacks whose
   **CI fast guards** run passed (`scripts/ci/last_green_base.py`). That
   workflow runs ci-guards.yml's `ci` group on every push to main, so its
   verdict is about main's whole tree. `guards / Guard status` is not used: it
   only runs the groups a commit's own diff routes. Verdicts come from one REST
   request for the workflow's last 100 push runs on main (pull request runs,
   including a fork's from its own `main`, are excluded), cached by `gh` for a
   minute, so at most 100 candidates are considered. Newer commits it passes over are listed with their verdict
   (`failure`, `pending`, `missing`).
3. Merges that commit through `scripts/ci/catch_up_pr.py`, the same merge the
   `/catch-up` workflow runs: `project.pbxproj`, the embedded config schema and
   `.xcstrings` conflicts resolve with their generators; any other conflict
   aborts the merge and names the paths.
4. Runs `scripts/ci/guards-local.sh` (the `ci` group, or every group with
   `--all-guards`) on the merge and labels each failed step. A local pass
   stamp for the merged main commit means every failure is the branch's.
   Otherwise the failed steps rerun, with `run_ci_guards.py --root --step`, in
   a temporary worktree of that main commit: failing there too is "inherited
   from main", passing there (or not existing there) is "introduced by this
   branch". A step main's rerun never reached, or reached only after an
   earlier step of its group failed, is "origin unknown". The stamp counts only
   when it was written on this platform and did not skip the failed step.

Guard failures never fail the command; the merge stands and the labels say
what to fix. `--strict` exits 3 when the branch introduced one, and 2 when a
failure's origin is unknown or the guard run ended without step results.

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the pick and the skipped commits; change nothing. |
| `--tip` | Merge main's tip even when it is red or still running. |
| `--all-guards` | Run every guard group after the merge, not only `ci`. |
| `--no-guards` | Merge only. |
| `--strict` | Exit 3 when the branch introduced a guard failure; 2 when it cannot tell. |

The `/catch-up` workflow (`.github/workflows/pr-catch-up.yml`) uses the same
selection for a pull request based on main, in its own step so the token that
reads the runs never shares an environment with pull request bytes: it merges
the newest green base commit and falls back to the tip when there is no verdict or no green commit
among the newest 40.

Caveats: a commit from before #14757 has no fast guard run and is never
picked. An inherited failure on a commit whose CI fast guards passed usually
means this machine differs from the Linux runner, and the output says so.
