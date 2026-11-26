# refresh-compilation-cache: GHOSTTYKIT_R2_ACCESS_KEY_ID: ${{ secrets.CI_CACHE_R2_ACCESS_KEY_ID }}

Where: the `refresh-compilation-cache` job in `.github/workflows/nightly.yml`, above `GHOSTTYKIT_R2_ACCESS_KEY_ID: ${{ secrets.CI_CACHE_R2_ACCESS_KEY_ID }}`.

A GitHub download stores the pinned archive in the CI cache bucket, which
download-prebuilt-ghosttykit.sh reads when GitHub refuses (2026-11-26 403s).
