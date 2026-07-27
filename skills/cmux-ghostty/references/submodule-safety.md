# Submodule Safety

The parent repository records only a commit SHA, not the branch that makes the SHA reachable, so submodule commits are easy to lose.

## Safe sequence

1. Enter the submodule.
2. Create or select the intended branch (never a detached HEAD).
3. Commit the submodule changes.
4. Push to the correct remote (`manaflow` for the Ghostty fork, `origin` elsewhere).
5. Verify the pushed branch contains the commit with `git merge-base --is-ancestor HEAD <remote>/main`.
6. Return to the parent repository and commit the updated pointer.

Skipping step 4 or 5 produces a parent commit pointing at an orphaned SHA that a future checkout or CI job cannot fetch.

## Fork documentation

Keep `docs/ghostty-fork.md` updated when fork changes or conflict notes matter for a future upstream merge. Record why the fork diverged, not just that it did.
