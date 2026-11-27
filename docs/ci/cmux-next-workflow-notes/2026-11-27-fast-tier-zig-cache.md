# Fast-tier Zig cache

Above `fast-tier-cargo: Keep the libghostty-vt zig build in Zig's global cache` in `.github/workflows/cmux-next.yml`.

`ghostty-vt-sys`'s build script runs `zig build -Doptimize=ReleaseFast` of libghostty-vt from the ghostty-next
submodule. Zig's local cache defaults to `ghostty-next/.zig-cache`, new on every checkout, so every fast-tier-cargo
job rebuilt it from nothing on the critical path: 4m43s on an ephemeral runner (job 139501000931), 6m12s on a pool
runner (job 139516054400), of a 977 s median job. Pool warm targets rarely help: 35 of 539 pool jobs (w76 to w83)
landed on a runner name that had run the job before.

`ZIG_LOCAL_CACHE_DIR` now points at Zig's global cache, and `./.github/actions/zig-global-cache` restores that
cache (feat-cmux-next pushes save it, weekly key). Zig rehashes file contents when mtimes differ, so a fresh
checkout still hits. A failed lookup or restore only costs the cold build it replaces (both steps continue on error).
