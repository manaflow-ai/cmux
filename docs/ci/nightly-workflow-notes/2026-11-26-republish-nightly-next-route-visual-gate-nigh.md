# republish-nightly-next: route-visual-gate-nightly:

Where: the `republish-nightly-next` job in `.github/workflows/nightly.yml`, above `route-visual-gate-nightly:`.

The visual gate (docs/ci/nightly-next-visual-gate.md): light and dark stills of a DEV build of
this run's commit on an idle owned Mac, checked beside the signed build. Skipped (`unavailable`)
with no idle runner; only `enforce` with a failing verdict holds this run's build.
