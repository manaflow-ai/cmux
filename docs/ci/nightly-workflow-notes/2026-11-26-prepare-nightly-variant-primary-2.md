# 2026-11-26-prepare-nightly-variant-primary-2

Above `if: ${{ (env.PREPARE_FALLBACK != 'true' || steps.reuse.outputs.exists != 'true') && (matrix.variant != 'universal') }}` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

The fast build is already compiled arm64, but the downloaded cmux-tui
client can still be universal. Thin every non-universal artifact before
signing so the architecture gate remains meaningful. The Chromium
engine artifact is arm64 only: an x86_64 variant drops it first and
reports the browser unavailable.
