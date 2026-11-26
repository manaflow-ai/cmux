# 2026-11-26-build-sign-notarize-nightly-2

Above `- &x55` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

macOS /bin/bash 3.2 exits 0 on a parse error in a script with an EXIT
trap (runs 39014131817, 39014922771). Parse every script this job can
run before any signing or notarization. An unsigned resume builds an
older tree: the checker and the workflow come from the signing control
(this run's commit), the scripts from the build tree.
