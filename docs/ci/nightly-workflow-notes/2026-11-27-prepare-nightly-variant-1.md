# 2026-11-27-prepare-nightly-variant-1

Above `if: always() && (needs.prepare-nightly-variant-primary.result == 'failure' || needs.prepare-nightly-variant-primary.result == 'success') && needs.decide.outputs.should_build == 'true' && (github.event_name != 'schedule' || github.event.schedule == '47 8 * * *') && needs.decide.outputs.build_only != 'true' && needs.resolve-nightly-cmux-tui-client.outputs.already_published != 'true' && needs.resolve-nightly-cmux-tui-client.outputs.superseded != 'true' && needs.decide.outputs.continue_only != 'true'` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

Never skipped: a skipped fallback skips signing and publishing (runs 40154003204,
40155340212). After a primary success it finds that result and does nothing.
