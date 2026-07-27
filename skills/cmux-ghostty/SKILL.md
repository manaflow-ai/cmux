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

Ghostty changes are committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork. In that submodule `origin` is upstream and `manaflow` is the fork, so check `git remote -v` before pushing. Keep `docs/ghostty-fork.md` current with fork changes and conflict notes.

```bash
cd ghostty
git remote -v
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

Keep the fork current with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then record the new SHA in the parent repo:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Submodule safety

For any submodule (ghostty, `vendor/bonsplit`, `homebrew-cmux`), push the submodule commit to its remote branch **before** committing the updated pointer in the parent repo. Never commit on a detached HEAD or a temporary branch: the parent then points at a SHA unreachable from any remote branch, and a future checkout or CI job fails to fetch it.

Verify the commit is reachable from the branch the pointer should track:

```bash
cd ghostty && git fetch manaflow main && git merge-base --is-ancestor HEAD manaflow/main
```

For submodules whose fork is `origin`, use `git merge-base --is-ancestor HEAD origin/main`.

## Detailed reference

- [references/submodule-safety.md](references/submodule-safety.md): the ordered safe sequence and fork documentation expectations.
