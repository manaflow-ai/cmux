# 2026-11-27-publish-nightly-8

Above `NIGHTLY_COMPONENT_GATES: ${{ vars.NIGHTLY_COMPONENT_GATES }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

The webview and App Store shelf checks run beside the build and report after it (report-nightly-fix-forward,
report-nightly-shelf-red); the gate reads the webview job in this run, waiting only under block (Leo, 2026-11-25).
