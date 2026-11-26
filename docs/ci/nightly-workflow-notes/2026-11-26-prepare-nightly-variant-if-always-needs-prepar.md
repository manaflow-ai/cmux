# prepare-nightly-variant: if: always() && (needs.prepare-nightly-variant-primary.result == 'failure' || ne

Where: the `prepare-nightly-variant` job in `.github/workflows/nightly.yml`, above `if: always() && (needs.prepare-nightly-variant-primary.result == 'failure' || needs.prepare-nightly-…`.

Never skipped: a skipped fallback skips signing and publishing (runs 40154003204,
40155340212). After a primary success it finds that result and does nothing.
