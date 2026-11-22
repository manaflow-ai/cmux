# Merging main into a branch

`scripts/merge-main.sh` is how an agent or a person brings a branch up to date
with main; use it instead of a raw `git merge origin/main`. Run it when you
depend on something that just landed or need to resolve a stale branch.
It exists because of 2026-09-25: #14724 broke
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
3. Merges through the trusted local resolver: `project.pbxproj`, the embedded
   config schema and `.xcstrings` conflicts resolve with their generators; any
   other conflict aborts the merge and names the paths. On a branch whose tree
   builds the cmux-next web bundles instead of committing them (feat-cmux-next
   since cx-vn5: `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/GENERATED.md`
   is committed), the bundles that main still commits stay out of the index:
   a modify/delete conflict on `Resources/markdown-viewer/webviews-app` (or
   another former bundle path) resolves to the deletion, and files main added
   there are removed from the merge (`git rm --cached`). The app build
   regenerates them from the merged sources. A raw `git merge origin/main`
   resolves the same way: `git rm -r --cached Resources/markdown-viewer/webviews-app`
   for the conflicted and added files, or `scripts/cmux-next/regenerate-web-bundles.sh`.
4. With `--guards` (off by default; pushing runs them in CI), runs
   `scripts/ci/guards-local.sh` (the `ci` group, or every group with
   `--all-guards`) on the merge and labels each failed step. A local pass
   stamp for the merged main commit means every failure is the branch's.
   Otherwise the failed steps rerun, with `run_ci_guards.py --root --step`, in
   a temporary worktree of that main commit: failing there too is "inherited
   from main", passing there (or not existing there) is "introduced by this
   branch". A step main's rerun never reached, or reached only after an
   earlier step of its group failed, is "origin unknown". The stamp counts only
   when it was written on this platform and did not skip the failed step.

Guard failures never fail the command; the merge stands and the labels say
what to fix. Fix the failures this branch introduced; the inherited ones are
main's. `--strict` exits 3 when the branch introduced one, and 2 when a
failure's origin is unknown or the guard run ended without step results.

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the pick and the skipped commits; change nothing. |
| `--tip` | Merge main's tip even when it is red or still running. |
| `--guards` | Run the `ci` guards locally after the merge. Off by default: pushing runs them in CI, and a laptop running them for many agents at once stalls. |
| `--all-guards` | Run every guard group after the merge (implies `--guards`). |
| `--no-guards` | Merge only; the default, kept for older callers. |
| `--strict` | Run the guards; exit 3 when the branch introduced a failure, 2 when it cannot tell. |

If your push is rejected because the branch moved, run `git pull --no-rebase`
and push again. Never force-push over a merge-main commit. The local command
is the only supported branch catch-up path.
