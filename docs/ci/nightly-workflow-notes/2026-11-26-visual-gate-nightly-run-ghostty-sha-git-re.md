# visual-gate-nightly: run: GHOSTTY_SHA="$(git rev-parse "HEAD:ghostty")" ./scripts/download-prebuilt-g

Where: the `visual-gate-nightly` job in `.github/workflows/nightly.yml`, above `run: GHOSTTY_SHA="$(git rev-parse "HEAD:ghostty")" ./scripts/download-prebuilt-ghosttykit.sh`.

No R2 write credentials: this job enters no ci-cache-writer environment and runs on an owned session
runner. A GitHub refusal still falls back to the bucket's public read; the cache-writer jobs store it.
