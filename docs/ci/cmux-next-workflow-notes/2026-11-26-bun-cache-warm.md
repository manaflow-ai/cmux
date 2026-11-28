# Bun cache: skip the archive on a warm runner

Above the `bun-warm` step in `.github/workflows/cmux-next-fast-gates.yml` (fast gates) and
`.github/workflows/cmux-next.yml` (web bundles, source-keyed cache).

A runner whose own Bun package cache already holds files (a persistent pool runner keeps
`BUN_INSTALL_CACHE_DIR` in its home across jobs) skips unpacking the cache archive over it; `bun install`
fetches only what that cache lacks. A runner with an empty cache restores as before. Measured 2026-11-23
07-09Z: of 14 fast-gates and web-bundles jobs cancelled at their 25- and 15-minute limits on the Linux pool
and Freestyle runners, 12 spent 400-1,096 s in the Bun cache step. Job 137529287983 downloaded its 677 MB
archive in 3 s and then spent 612 s in `tar -xf` before its gates ran. The repository variable
`CI_BUN_CACHE_RESTORE_WARM=1` restores on every runner again.

2026-11-27: every pool-runner job that restores the Bun cache now runs the same check (24 restores in 13
workflows, cmux#61740 and the PR after it). `tests/test_ci_bun_cache_warm.py` is the detector: it fails on a
pool-runner job (`cmux-linux`, the react shard runner) whose restore-only Bun cache step has no earlier `bun-warm`
step or no `steps.bun-warm.outputs.warm != 'true'` guard.
