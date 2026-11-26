# nightly.yml `visual-gate-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Claim a tour slot on this Mac`

The media tour's slots (scripts/ci/media_tag_lock.py): the gate builds
into a warm slot's head DerivedData and holds the slot's lock until
this job's Runner.Worker exits, so it never builds beside a tour.

## 2

Above: `run: GHOSTTY_SHA="$(git rev-parse "HEAD:ghostty")" ./scripts/download-prebuilt-ghosttykit.sh`

No R2 write credentials: this job enters no ci-cache-writer environment and runs on an owned session
runner. A GitHub refusal still falls back to the bucket's public read; the cache-writer jobs store it.
