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

The darwin leg saved no delta at first (job 140189679068, 2026-11-26). Its build step's warm-target restore moves the applied
target into the runner slot's pool tree and links cmux-tui/target to it; that is fine, pack reads through the link. But "Record
the warm target", on a host under the 40 GiB free floor, removed the pool tree right after recording it, so every later step
saw a dangling link: pack printed "no cmux-tui/target or no stamp ... nothing packed" and the dependency save printed
"cmux-tui/target does not exist". The toolchain-changed miss in that log only emptied the tree before the build and is not the
cause. Now record never removes the tree; "Release the pool warm target", the job's last step, does
(machine-channel-warm-target.sh release), and pack names a link whose tree is gone. The fat x86_64 leg's first delta save got
HTTP 000 on its 1483 MB upload (job 140187794318); r2-cache.sh now sends an archive again after a 000 or a 5xx, up to 3 times,
and reads back an upload the bucket kept before the drop. Tests: tests/test_ci_cmux_tui_fat_warm_target.py (release),
tests/test_ci_r2_cache.sh (dropped upload), scripts/ci/tests/cargo-target-delta.test.sh (a target linked to a pool tree).
