# 2026-11-28-visual-gate-nightly-environment

Where: `.github/workflows/nightly.yml`, job `visual-gate-nightly`: above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || '' }}`.

A warm tour slot builds the DEV app in ~6-10 min; a cold one took 35 min. The GhosttyKit download reads the R2 cache credentials: ci-cache-writer on main, no environment elsewhere.
