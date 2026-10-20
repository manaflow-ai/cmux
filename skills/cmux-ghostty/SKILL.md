---
name: cmux-ghostty
description: "Ghostty submodule and GhosttyKit workflow rules for cmux. Use when modifying the ghostty submodule, rebuilding GhosttyKit.xcframework, updating the parent submodule pointer, or documenting fork conflict notes."
---

# cmux Ghostty

## GhosttyKit builds

Always rebuild the xcframework with Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## Submodule workflow

Ghostty changes are committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork. Keep `docs/ghostty-fork.md` current with fork changes and conflict notes.

Always run `git remote -v` first and push to whichever remote is `manaflow-ai/ghostty`. `.gitmodules` sets the submodule URL to that fork, so in a normal checkout it is `origin`; older setups tracked upstream as `origin` and added the fork as `manaflow`. Substitute the right name below.

```bash
cd ghostty
git remote -v                  # find the manaflow-ai/ghostty remote (usually origin)
git checkout -b <branch>
git add <files>
git commit -m "..."
git push origin <branch>
```

To pull in changes from upstream `ghostty-org/ghostty`, add it as an explicit remote first, since no checkout has it by default:

```bash
cd ghostty
git remote add upstream https://github.com/ghostty-org/ghostty.git   # once
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

Then record the new SHA in the parent repo:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Submodule safety

For any submodule (ghostty, `vendor/bonsplit`, `homebrew-cmux`), push the submodule commit to its remote branch **before** committing the updated pointer in the parent repo. Never commit on a detached HEAD or a temporary branch: the parent then points at a SHA unreachable from any remote branch, and a future checkout or CI job fails to fetch it.

Verify the commit is reachable from the branch the pointer should track, using the remote you just pushed to:

```bash
cd ghostty && git fetch origin main && git merge-base --is-ancestor HEAD origin/main
```

## Detailed reference

- [references/submodule-safety.md](references/submodule-safety.md): the ordered safe sequence and fork documentation expectations.
