# Pool cargo legs: the per-commit R2 workspace delta

Above `build: Restore the workspace delta from R2` and `Pack the workspace delta` in `.github/workflows/cmux-tui-build-package.yml`.

note-210c's R2 entry holds dependencies only, and a cmux-runner-pool runner has no sticky disk, so every pool leg still compiled
the whole workspace. On aarch64-apple-darwin built on Linux (job 139565194555, 2026-11-25) cargo group 1 took 1462 s: acpmux
778 s, cmux-tui-core 637 s, ghostty-vt-sys's zig build 205 s, then the 448 s fat-LTO link. That leg is the nightly tree's
critical path (cmuxterm-hq goals/nightly-30min.md). A kept per-runner target (scripts/ci/pool-warm-target.sh) does not fit: the
fat darwin target is about 39 GB, a pool VM runs 4 runners on 200 GB, and a leg lands on a random runner.

Now each such leg also restores the newest workspace delta for its leg, workspace path and inputs (`cmux-tui-cargo-ws-v1-...`)
and applies it on top of the dependency entry (scripts/ci/cargo-target-delta.sh): the files a build added, plus the source
mtimes of the commit it built. Sources whose bytes are unchanged get those mtimes back, so Cargo rebuilds only what the commit
changed and its dependents; a changed file keeps a fresh mtime, so correctness never rests on the delta. After the uploads the
leg packs what it wrote plus what it applied (hard links, before note-210c's strip), prints the size in every run, and
feat-cmux-next pushes save it under a per-commit key. The delta is always against the dependency entry, never a delta of a delta.
The CPU fingerprint is pinned to the target triple, as machine-channel-warm-target.sh pins it. R2's 30-day prune bounds the
per-commit entries. Test: scripts/ci/tests/cargo-target-delta.test.sh (a real three-crate workspace, a new runner per leg).
