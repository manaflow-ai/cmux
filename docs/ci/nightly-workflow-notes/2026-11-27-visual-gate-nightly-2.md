# 2026-11-27-visual-gate-nightly-2

Above `run: GHOSTTY_SHA="$(git rev-parse "HEAD:ghostty")" ./scripts/download-prebuilt-ghosttykit.sh` (job `visual-gate-nightly`) in `.github/workflows/nightly.yml`.

No R2 write credentials: this job enters no ci-cache-writer environment and runs on an owned session
runner. A GitHub refusal still falls back to the bucket's public read; the cache-writer jobs store it.
