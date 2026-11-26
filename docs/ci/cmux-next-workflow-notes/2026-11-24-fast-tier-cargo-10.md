# 2026-11-24-fast-tier-cargo-10

Above `rm -rf "$REGISTRY/src"` in the step `Strip the workspace's own output before the R2 save`'s script (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

Extracted sources come back from the .crate files in registry/cache.
