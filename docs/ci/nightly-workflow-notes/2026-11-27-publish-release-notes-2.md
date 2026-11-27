# 2026-11-27-publish-release-notes-2

Above `- *checkout-the-gh-token-wrapper` (job `publish-release-notes`) in `.github/workflows/nightly.yml`.

The wrapper comes from the workflow commit: the build checkout may predate it.
The publication-tooling shape test_nightly_cmux_tui_resolve.py exempts: scripts only.
