# 2026-11-26-republish-nightly-next-1

Above `route-visual-gate-nightly:` (job `republish-nightly-next`) in `.github/workflows/nightly.yml`.

The visual gate (docs/ci/nightly-next-visual-gate.md): light and dark stills of a DEV build of
this run's commit on an idle owned Mac, checked beside the signed build. Skipped (`unavailable`)
with no idle runner; only `enforce` with a failing verdict holds this run's build.
