# 2026-11-24-fast-tier-cargo-8

Above the step `Record this runner's warm cargo target` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

After every cargo step and the R2 save (which reads cmux-tui/target), pass or fail, never on
cancel: the source manifest the next job restores mtimes from. On the pool it then renames
cmux-tui/target into this VM's slot, so a miss's R2-seeded tree is kept for a rename, not measured
(du of the 13 GB tree took 19 s). A job that ends before it leaves none (restore consumed it).
