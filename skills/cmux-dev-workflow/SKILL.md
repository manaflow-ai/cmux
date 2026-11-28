---
name: cmux-dev-workflow
description: "Contributor workflow for native cmux setup, tagged dev builds and Xcode project normalization. Use for native build inputs, setup or tagged app verification."
---

# cmux Dev Workflow

## Scope and routing

Run repository commands only from a [trusted checkout](../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

[Choose verification for the change](../cmux-testing/references/local-vs-ci-validation.md)
before preparing a native build. Fast feedback starts with
`python3 scripts/verify-local.py`; portable-tooling and documentation changes use
their scoped checks without an unrelated app build.

For native app or build-input changes, build with a tag as below. Setup (`./scripts/setup.sh`) initializes
submodules, builds GhosttyKit and installs the project-normalization hook;
it is not a prerequisite for portable static checks.

## Worktrees

Make every worktree of a cmux clone with the clone tool, never a bare `git worktree add`:

```sh
python3 scripts/cmux_worktree.py add -b my-branch ~/cmux-worktrees/my-branch origin/feat-cmux-next
python3 scripts/cmux_worktree.py add --cargo cmux-tui -b my-branch PATH origin/feat-cmux-next  # Rust work
```

The same file is `git cow` wherever hq installs it on PATH (`git-cow`: every agent Mac and fleet
Mac): `git cow add -b BRANCH PATH [COMMIT]` takes `git worktree add`'s arguments and defaults
(COMMIT is HEAD), clones the files the same way, and runs plain `git worktree add` where it cannot.

- **What it does.** The files are APFS clones of a clean, locked seed checkout (in
  `~/Library/Caches/cmux-worktree-seed/`), and the tool writes the new index with the clones' stat
  data, so git never re-hashes them; `git read-tree -m -u` then writes only the files that differ
  from the seed's commit. On feat-cmux-next (54,000 files): 3.3-4.0 s and about 0.1 GiB, against
  17.3 s and 1.6 GiB for `git worktree add`. Off APFS it checks out as git does.
- **Rust.** `--cargo DIR` seeds `DIR/target` with clones of the newest sibling worktree's target
  built by the same toolchain, without its `incremental` folders, under that target's cargo lock
  (a sibling that is building is skipped). Registry crates are then fresh; only the workspace's own
  crates rebuild. Never share one `CARGO_TARGET_DIR` between worktrees: cargo holds one lock for a
  build, and the last build's binaries overwrite the others'.
- **JavaScript.** Run `bun install` in the package you work on. On APFS bun clones each package from
  its store (webviews: 4.8 s, about 13 MB of new disk). Never symlink node_modules: Vite, Metro and
  Node resolve a symlink to the other worktree's real path and load a second copy of React.
- **SwiftPM and Xcode.** Package checkouts are already shared in `~/Library/Caches/org.swift.swiftpm`,
  and `reload.sh` keeps DerivedData per tag outside the worktree; nothing to share.
- **Collecting.** `python3 scripts/cmux_worktree.py gc` lists every worktree: removable (clean,
  nothing untracked, HEAD on origin/feat-cmux-next or origin/main, idle 3 days) or kept, with the
  reason (unpushed commits, uncommitted files, pushed but not landed, locked, in use). `gc --apply`
  removes only the removable ones, with a plain `git worktree remove`. Never remove a worktree with
  unpushed commits or uncommitted files; report it. Removing one also deletes its ignored files
  (screenshots, receipts), so ask the user before you `--apply` on worktrees that are not yours.
- **Old worktrees.** `python3 scripts/cmux_worktree.py dedupe` lists how much of the idle (24 h)
  worktrees' unchanged tracked files could share the seed's blocks; `--apply` clones them in place,
  with the git index lock held, keeping each file's content and mtime. Changed files are never touched.

## Tagged local development

A web or daemon change needs no build: `cmux app try .` (a copy of the NIGHTLY, your code swapped in) first.
When local native execution is authorized:

```sh
./scripts/reload.sh --tag <short-tag>
CMUX_TAG=<short-tag> scripts/cmux-debug-cli.sh workspace list
```

Reload builds without launching; add `--launch` when live verification is needed.
Never use bare `xcodebuild` or open an untagged `cmux DEV.app`: tags isolate bundle
IDs, sockets and build output from other sessions. Do not use `/tmp/cmux-cli`,
which follows the most recently reloaded app. See [tagged builds](references/tagged-builds.md).
Never quit, kill, relaunch or `xctrace --launch` the user's running cmux
(`com.cmuxterm.app`); it holds their live agent sessions.

An app build does not establish test-target compilation or execution. Follow
[the test guide](../cmux-testing/references/local-vs-ci-validation.md) for those claims.

## Toolchain and project files

`.xcode-version` owns the Xcode major. `cmux.xcodeproj/project.pbxproj` uses
objectVersion 77 because it has synchronized folders; `scripts/check-pbxproj.sh`
pins 60 for Xcode 26 and accepts 77 only with a `PBXFileSystemSynchronizedRootGroup`.
The app package needs Swift tools 6.2; see
[toolchain and macOS 14 compatibility](../cmux-architecture/references/swift-6-0-compatibility.md).

The installed pre-commit hook normalizes staged project files and registers new
Python tests in `tests/test-execution.d/` (one file per area). Preserve it and
run `python3 scripts/verify-local.py --only project` after project edits. Toolchain
pin changes are deliberate team decisions; see [project normalization](references/xcode-project-normalization.md).

## Hooks and lints

Web lints, the cmux-next pre-push gate and the post-edit and pre-commit hooks:
[hooks and lints](references/hooks-and-lints.md).
