# nightly.yml: job `verify-final-dmg-nightly`, step "Launch smoke from a fresh home"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Leo, 2026-10-29: "Just don't have that be the downloading thing." The app launched from a fresh
home must stay up with Home rendered: a crash fails this job, so publish-nightly puts none of
this build on the feed (scripts/ci/nightly-steps/launch-smoke-gate.sh; cannot-run never holds it).
