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
| `--base <branch>` | Merge that branch instead of main: `--base feat-cmux-next` for a pull request into feat-cmux-next. Only main has CI fast guards verdicts, so any other base merges its tip. |

If your push is rejected because the branch moved, run `git pull --no-rebase`
and push again. Never force-push over a merge-main commit. The local command
is the only supported branch catch-up path.

## When git is older than 2.46

The resolver needs git 2.46 or newer. It stops with "git 2.46 or newer is
required for attr.tree". It sets `attr.tree` to the base, so your branch's
`.gitattributes` cannot choose the merge drivers. The Linux agent VMs have
git 2.43. If you cannot upgrade git, do a plain merge with these steps:

1. Pick the commit. For feat-cmux-next, use its tip: the script merges the
   tip there too. For main, run `scripts/merge-main.sh --dry-run`. It works
   on an old git and prints the last green commit. Merge that commit, not
   main's tip.
2. Make sure that this clone has the trusted merge drivers:
   `git config --get merge.xcstrings-v2.driver` and
   `git config --get merge.pbxproj-v1.driver` must print a command. If they
   do not, run `scripts/install-git-hooks.sh` from a trusted checkout at
   origin/feat-cmux-next. With the drivers, git merges
   `.xcstrings` key by key and `project.pbxproj` as a union of the added
   entries, as the resolver does. Never take one side of these files. That
   loses the other side's strings or project entries.
3. Merge with a merge commit: `git fetch origin <base branch>`, then
   `git merge --no-edit <commit>`. With no conflict, git makes the merge
   commit at once; steps 4 and 6 then add a separate commit. Do not rebase,
   squash or force-push.
   Do this only on your own branch, or on a branch whose `.gitattributes`
   you trust. In a plain merge, your branch's `.gitattributes` chooses the
   drivers. A path that it maps to `cmux-generated-v1` keeps your side
   with no conflict.
4. Repair the generated files. With the drivers installed, git keeps your
   side of each `merge=cmux-generated-v1` path in `.gitattributes`
   (settings schema, `docs/mdm/*`, action exports, web bundles, SDK
   bindings, strings tables, `ci-target-graph.json`) and shows no conflict.
   Do not edit them by hand. Let the PR autofix regenerate them. The action
   and settings exports need a Mac `swift test`, so never run their
   `scripts/cmux-next/regenerate-*.sh` on a person's Mac: run them on the
   fleet (`cmux-ci run`) if the autofix cannot.
5. When you merge main into a feat-cmux-next branch, keep main's former web
   bundles out of the index, as step 3 above says:
   `git rm -r --cached Resources/markdown-viewer/webviews-app` for the
   conflicted and added files, or
   `scripts/cmux-next/regenerate-web-bundles.sh`.
6. On main, if both sides changed `web/data/cmux.schema.json`, run
   `scripts/generate-cmux-config-schema.py`. A conflict inside that file
   needs a person.
7. Resolve any other conflict. Then run the area's checks
   (`python3 scripts/cmux-next/prepush-gate.py` for feat-cmux-next) and
   push.
8. next-autoland and `risk evidence` read a review receipt at the exact
   head. next-autoland carries one only across its own update-branch
   merges (signed `web-flow` commits), not across your merge. Ask for a
   new receipt at the merge head that confirms the pull request's own
   files did not change. Then remove `ready-to-land` and add it again.
