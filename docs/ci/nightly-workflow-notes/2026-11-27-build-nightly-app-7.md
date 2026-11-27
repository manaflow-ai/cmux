# 2026-11-27-build-nightly-app-7

Above `if: (inputs.nightly_next_unsigned_run == '' && (needs.decide.outputs.track != 'nightly-next' || steps.release-derived-data.outputs.mode == '') && (needs.decide.outputs.cold_cache != 'true')) && !env.LEFT_SLOT` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

A cold measurement run skips the restore; every gate below treats the
missing output like a cache miss, so the cold build still saves.
