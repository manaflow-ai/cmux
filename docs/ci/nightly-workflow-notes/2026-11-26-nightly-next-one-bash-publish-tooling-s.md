# nightly-next-one: bash .publish-tooling/scripts/ci/nightly-steps/republish-deltas-upload-next-appc

Where: the `nightly-next-one` job in `.github/workflows/nightly.yml`, above `bash .publish-tooling/scripts/ci/nightly-steps/republish-deltas-upload-next-appcasts.sh`.

The tail's own revise (R2 upload, merge into the live item, prune, guard, then write-feed
--same-build: only while the live feed still serves this build).
