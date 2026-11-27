# 2026-11-27-build-sign-notarize-nightly-1

Above `environment: ${{ needs.decide.outputs.environment }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.
