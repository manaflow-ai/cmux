---
name: cmux-ghostty
description: "Ghostty submodule and GhosttyKit workflow rules for cmux. Use when modifying the ghostty submodule, rebuilding GhosttyKit.xcframework, updating the parent submodule pointer, or documenting fork conflict notes."
---

# cmux Ghostty

The repository has two Ghostty submodules:

| Submodule | Fork | Used by |
| --- | --- | --- |
| `ghostty` | `manaflow-ai/ghostty` | the Mac app's `GhosttyKit.xcframework` |
| `ghostty-next` | `manaflow-ai/ghostty-next` | cmux-tui's libghostty-vt (`cmux-tui/crates/ghostty-vt-sys/build.rs`) |

The workflow below is written for `ghostty`; the same push-before-pointer rule
applies to `ghostty-next`.

## GhosttyKit builds

Let `scripts/ensure-ghosttykit.sh` build the xcframework: it uses the Release
flags the app expects (`-Doptimize=ReleaseFast`, universal xcframework, no
macOS app, no i18n, no Sentry) and stamps the cache key. Building by hand with
fewer flags gives a different artifact.

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

## ghostty-next upstream syncs: to a libghostty-vt release tag

`ghostty-next` is upstream `ghostty-org/ghostty` main plus a short patch stack
([plans/cmux-next/ghostty-next.md](../../plans/cmux-next/ghostty-next.md) section 1). Upstream tags
libghostty-vt releases on main (`vt-1.0.0` on 2026-11-06, `vt-1.0.1` on 2026-11-11), and each tag carries
a semver-stable C ABI. Sync to the newest `vt-*` tag, not to main's tip. Take a later main commit only
when a named fix needs it, and say which fix in the PR. Then every upstream fix we want arrives as a tag
bump, not a cherry-pick.

```bash
cd ghostty-next
git remote add upstream https://github.com/ghostty-org/ghostty.git   # once
git fetch upstream main --tags
git describe --tags --match 'vt-*' --abbrev=0 HEAD   # newest release the current pin holds (an error: none)
tag=$(git tag -l 'vt-*' --sort=-v:refname | head -1)
git checkout -B "lane/upstream-$tag" HEAD          # start from the pin: it can hold fixes fork main lacks
git merge --no-ff "$tag" -m "Merge upstream libghostty-vt $tag"
git merge-base --is-ancestor "$tag" HEAD && echo "on $tag"
```

Push the branch, then move the parent pointer (Submodule safety below). The cmux PR's title names the
tag ("ghostty-next: sync to upstream vt-1.0.1"), and cmux-tui's tests pass on the fleet
(`cmux-ci test --setup rust`).

## Submodule safety

For any submodule (`ghostty`, `ghostty-next`, `homebrew-cmux`), push the submodule commit to its remote branch **before** committing the updated pointer in the parent repo. Never commit on a detached HEAD or a temporary branch: the parent then points at a SHA unreachable from any remote branch, and a future checkout or CI job fails to fetch it.

Verify the commit is reachable from the branch the pointer should track, using the remote you just pushed to:

```bash
cd ghostty && git fetch origin main && git merge-base --is-ancestor HEAD origin/main
```

## Detailed reference

- [references/submodule-safety.md](references/submodule-safety.md): the ordered safe sequence and fork documentation expectations.
