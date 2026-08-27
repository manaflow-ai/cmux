# Submodule Safety

The parent repository records only a commit SHA, not the branch that makes the SHA reachable, so submodule commits are easy to lose.

## Safe sequence

1. Enter the submodule.
2. Create or select the intended branch (never a detached HEAD).
3. Commit the submodule changes.
4. Push to the remote that hosts the fork. `.gitmodules` points every submodule at `manaflow-ai/*`, so that is normally `origin`; run `git remote -v` to confirm before pushing.
5. Verify the pushed branch contains the commit, checking the branch you actually pushed rather than always `main`: `git merge-base --is-ancestor HEAD <remote>/<branch>`.
6. Return to the parent repository and commit the updated pointer.

Skipping step 4 or 5 produces a parent commit pointing at an orphaned SHA that a future checkout or CI job cannot fetch.

## Fork documentation

Keep `docs/ghostty-fork.md` updated when fork changes or conflict notes matter for a future upstream merge. Record why the fork diverged, not just that it did.
