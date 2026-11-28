# 2026-11-28-read-the-feed-back-before-saying-published

Where: `.github/workflows/nightly.yml`, Read the feed back before saying published.

A run that says published reads the live feeds first: an unmoved feed fails here, red, and a refused build (nightly-next-one reds a real refusal) asks for no post-publication run (2026-11-25, run 45607031207).
