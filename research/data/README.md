# Measurement artifacts

`site-metrics.json` is the local result of the Playwright run described in [`../hero-page-study.md`](../hero-page-study.md). It is intentionally ignored because the report carries the stable measurements and the script can regenerate the live values. The script also emits `.trace.zip` files while investigating, but `.gitignore` keeps those transient traces out of commits. No third-party screenshots or video frames are stored here.
