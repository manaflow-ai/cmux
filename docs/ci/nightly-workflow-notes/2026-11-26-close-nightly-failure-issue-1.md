# 2026-11-26-close-nightly-failure-issue-1

Above `if: always() && needs.published-build.result == 'success' && needs.published-build.outputs.run_tail == 'true' && needs.published-build.outputs.should_publish == 'true' && needs.published-build.outputs.push_clean == 'true' && !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') && needs.published-build.outputs.publish_result == 'success' && needs.published-build.outputs.publish_refused != 'true' && needs.published-build.outputs.publish_tag_status == 'updated' && (needs.generate-nightly-deltas.result == 'success' || needs.generate-nightly-deltas.result == 'skipped') && (needs.republish-nightly-deltas.result == 'success' || needs.republish-nightly-deltas.result == 'skipped') && (needs.published-build.outputs.track != 'nightly-next' || needs.published-build.outputs.publish_source == 'recovered' || (needs.sign-release-notes.result == 'success' && needs.publish-release-notes.result == 'success'))` (job `close-nightly-failure-issue`) in `.github/workflows/nightly.yml`.

always(): a skipped notes job must not skip this job silently; the
conditions below decide. nightly-next closes only with its notes published,
unless it published a recovered build, which has none (cx-urd.69). A
recovered build can follow this run's own failed build, which reports.
It closes in the run that ran the notes and deltas (run_tail): on nightly-next, the dispatched one. There
it cannot see the run that published, so push_clean says none of that run's jobs failed.
