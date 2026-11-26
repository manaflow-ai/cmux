# publish-nightly: variant_pattern: ${{ steps.source.outputs.variant_pattern }}

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `variant_pattern: ${{ steps.source.outputs.variant_pattern }}`.

For publish-nightly-next-github: what to publish and the release body's parts.
feed_written is false when a newer build was already on the feed.
