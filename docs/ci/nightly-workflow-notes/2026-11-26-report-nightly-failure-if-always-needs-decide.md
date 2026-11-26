# report-nightly-failure: if: always() && (needs.decide.outputs.should_publish == 'true' || needs.publishe

Where: the `report-nightly-failure` job in `.github/workflows/nightly.yml`, above `if: always() && (needs.decide.outputs.should_publish == 'true' || needs.published-build.outputs.cros…`.

Twice on nightly-next: the loop run reports its build, feed and dispatch, the dispatched run (cross_run) the
rest. A dispatched run whose published-build fails has no record, so it reports under nightly-next's names.
