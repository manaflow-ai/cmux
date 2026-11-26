# nightly.yml: job `build-nightly-app`, step "Upload unsigned nightly app (retry)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Every nightly-next build's dSYMs: sentry-dsyms-nightly uploads them, and keep-published-dsyms
keeps a published build's on R2 (Sentry reads 403'd, nightly 38005665577). 21 days: an
unsigned resume (7) plus notarization recovery (14). resume-unsigned-nightly.py reads
this artifact's name as the build's source commit.
