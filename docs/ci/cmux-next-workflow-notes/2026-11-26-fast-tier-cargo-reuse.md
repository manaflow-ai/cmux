# 2026-11-26-fast-tier-cargo-reuse

Above `CMUX_GHOSTTY_VT_ZIG_CPU` in the env of job `fast-tier-cargo`, the step `Restore source mtimes for the R2
cargo build`, and the `record` line of the step `Strip the workspace's own output before the R2 save`, in
`.github/workflows/cmux-next.yml`.

The R2 cargo build restored in 29 s and the job still timed out at 30 minutes (PR run 45740955339): 142 crates
recompiled, and the ghostty-vt-sys build script's zig build of libghostty-vt alone ran 24 minutes. Three causes:

- The strip matched test target names on every entry: cmux-tailnet-local's `tests/http.rs` and
  acpmux-team-space's `tests/digest.rs` deleted the third-party `http` and `digest`, so 26 dependencies (hyper,
  reqwest, axum, sha2, ...) rebuilt. Test, bench, bin and example names now drop only their own executables
  (`--workspace-binaries`).
- The strip dropped ghostty-vt-sys, and a fresh checkout's mtimes would have rerun its build script anyway. It now
  stays (`--keep ghostty-vt-sys`); the seed records source mtimes into the target dir
  (`scripts/blacksmith-testbox-source-mtimes.py`, as `scripts/ci/pool-warm-target.sh` does on the pool), and a
  restore backdates every byte-identical source, so cargo reuses it on an unchanged ghostty-next.
- libghostty-vt is built for zig's native CPU, and the mtime restore drops native output from another CPU
  (SIGILL otherwise). `CMUX_GHOSTTY_VT_ZIG_CPU=baseline` makes it portable across runner hosts.

The key moved to `v2` so the next feat-cmux-next push seeds the fixed tree: a key that already exists is never
saved again.
