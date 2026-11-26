# build-sign-notarize-nightly: environment: ${{ needs.decide.outputs.environment }}

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `environment: ${{ needs.decide.outputs.environment }}`.

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.
