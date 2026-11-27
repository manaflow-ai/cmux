# 2026-11-27-refresh-compilation-cache-2

Above `GHOSTTYKIT_R2_ACCESS_KEY_ID: ${{ secrets.CI_CACHE_R2_ACCESS_KEY_ID }}` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

A GitHub download stores the pinned archive in the CI cache bucket, which
download-prebuilt-ghosttykit.sh reads when GitHub refuses (2026-11-26 403s).
