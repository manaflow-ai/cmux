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

## Automatic catch-up

Open pull requests are caught up without anyone asking. Each time a push to
main passes CI fast guards, `.github/workflows/pr-catch-up.yml` runs
`scripts/ci/auto_catch_up_select.py`, which picks pull requests against main
whose head is an unprotected branch of this repository (no branch protection
rule or ruleset), that are not drafts, have no `no-auto-catch-up` label, and
have a check suite and have not been pushed for 30 minutes (an agent still
pushing is left alone; heads older than 14 days are skipped too), and that
either conflict with main or are red only because of main: their CI fast
guards comment from `guard_attribution.py`, about the current head, marks a
step "red on main too, not this PR", and the head does not contain the green
commit yet. It takes at most `CMUX_AUTO_CATCH_UP_MAX` (a repository variable,
default 15) per run, most recently pushed first, since every catch-up push
re-runs the pull request's CI. Each selected pull request gets the same merge,
verification and compare-and-swap push as `/catch-up`, pinned to the head the
selection judged.

It comments when it pushed, and when a person has to act on that head (a
conflict outside the generated files, a merge that brings in workflow changes,
a refused push). That comment has no mentions and carries
`<!-- cmux-auto-catch-up head=<sha> -->`, and the selector never tries that
head again, so a stuck conflict is reported once per head. Everything else (a
branch already up to date, a merge error or a lost runner, a head that moved,
a merge the push job refused) stays silent. The selector counts its picks per
head in the `pr-catch-up-auto-ledger` artifact and leaves a head alone after
two, so a silent outcome that repeats does not take a slot on every green main.
Without the route App key it selects nothing, since an Actions-token push
starts no CI.

If your push is rejected because the branch moved, run `git pull --no-rebase`
and push again. Never force-push over a catch-up merge. `merge-main.sh` stays
the way to catch up locally, for example before main's newest commit is green.

The `/catch-up` workflow (`.github/workflows/pr-catch-up.yml`) uses the same
selection for a pull request based on main, in its own step so the token that
reads the runs never shares an environment with pull request bytes: it merges
the newest green base commit and falls back to the tip when there is no verdict or no green commit
among the newest 40.

Caveats: a commit from before #14757 has no fast guard run and is never
picked. An inherited failure on a commit whose CI fast guards passed usually
means this machine differs from the Linux runner, and the output says so.
