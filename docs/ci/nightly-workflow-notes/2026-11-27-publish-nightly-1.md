# 2026-11-27-publish-nightly-1

Above `environment: ${{ needs.decide.outputs.environment }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.
