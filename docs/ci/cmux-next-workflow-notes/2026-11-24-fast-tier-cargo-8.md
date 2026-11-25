# 2026-11-24-fast-tier-cargo-8

Above the step `Record this runner's warm cargo target` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

After every cargo step, pass or fail, never on cancel: the source manifest the next job on this
runner restores mtimes from. A job that ends before it leaves none (restore consumed it).
