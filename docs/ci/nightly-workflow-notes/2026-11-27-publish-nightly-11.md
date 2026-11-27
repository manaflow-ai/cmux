# 2026-11-27-publish-nightly-11

Above `already_published: ${{ steps.recheck.outputs.already_published == 'true' || steps.gate.outputs.refused == 'true' }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Another run already published the recovered build, or the final gate
refused (see refused): this run published nothing.
