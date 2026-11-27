# 2026-11-27-build-sign-notarize-nightly-4

Above `strategy:` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

One universal Xcode build feeds every variant: the thin variants are cut
from it with lipo, so each user downloads only their architecture.
