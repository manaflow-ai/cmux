# nightly.yml `publish-nightly-reel`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `publish-nightly-reel:`

The nightly reel (scripts/cmux-next/media/reel.py): each pull request in this
build's signed notes with its tour's "after" clip and a title card, joined
into one video, and a page listing them, on the pr-media branch at
nightly-next/<build>/. Evidence only: no job needs this one, and it never
reports the nightly as failed.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}`

A one-job JIT VM on purpose, in the tail only (after publish-release-notes): an ffmpeg render of up to 90 min
would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).

## 3

Above: `environment: pr-media`

The private-terms secret lives only in this environment, which admits only
the protected branches (main, feat-cmux-next, nightly-next).

## 4

Above: `permissions:`

contents: write reaches the pr-media branch only through
.github/actions/pr-media-publish: its privacy check (pr_media_privacy.py,
with tesseract OCR for the reel's frames) refuses any private name in this
bot's folder before the first upload.
