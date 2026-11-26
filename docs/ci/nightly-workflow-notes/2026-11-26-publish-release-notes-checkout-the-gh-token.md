# publish-release-notes: *checkout-the-gh-token-wrapper

Where: the `publish-release-notes` job in `.github/workflows/nightly.yml`, above `- *checkout-the-gh-token-wrapper`.

The wrapper comes from the workflow commit: the build checkout may predate it.
The publication-tooling shape test_nightly_cmux_tui_resolve.py exempts: scripts only.
