# fast-tier-cargo: the libghostty-vt zig cache in R2, cmux-tui-core at opt-level 0

Above `Key the cargo build in R2`, `Restore the libghostty-vt zig cache from R2`, `Save the libghostty-vt zig
cache to R2` in fast-tier-cargo
(`.github/workflows/cmux-next.yml`), and the `opt_level` of `matrix core` in scripts/cmux-next/fast-tier.json.

After [note-210b](../cmux-next-workflow-notes.md#note-210b) and #50826 (`--lib`) the R2 restore hits, yet the cmux-tui-core prebuild still took 8m11s
(job 137395218484, 2026-11-22): the strip drops the workspace's own crates, so every run recompiles them.
From the log's timestamps: ~95 workspace crates about 1 minute in parallel; ghostty-vt-sys's build script
(the ReleaseFast `zig build` of libghostty-vt) about 2.5 minutes; ghostty-vt 1m43s; the cmux-tui-core test
library 3m56s.

Zig's cache is content-addressed (a manifest of input hashes, rehashed when a file's stat differs), so a
restored cache can never hand back a stale object. The job points `ZIG_LOCAL_CACHE_DIR` at
`$RUNNER_TEMP/ghostty-vt-zig-cache` and keeps it in R2 under the workspace hash, zig version and the
ghostty-next gitlink. A pull request restores the exact key or the newest under the prefix; a feat-cmux-next
push restores only the exact key, so a gitlink bump builds once and saves that commit's objects alone.

cmux-tui-core's own crate builds at opt-level 0 here (`"opt_level": 0` on its entry in
scripts/cmux-next/fast-tier.json, a `--config profile.dev.package.cmux-tui-core.opt-level=0` on its build
and run). Its entry runs one 5 s test, so compiling the test library is the cost. Setting the whole
workspace to 0 (`CARGO_PROFILE_DEV_OPT_LEVEL=0`, the first head of #51206) cut the core build from 8m11s to
6m13s, but the sidebar layout reducer's test went from 17.2 s to past its 60 s cap. Dependencies and every
other crate keep their profiles, and the dev loop's opt-level 1 stays in Cargo.toml.
