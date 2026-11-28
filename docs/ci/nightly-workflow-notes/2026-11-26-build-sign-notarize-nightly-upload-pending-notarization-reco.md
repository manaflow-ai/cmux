# nightly.yml: job `build-sign-notarize-nightly`, step "Upload pending notarization recovery artifact (retry)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

cmux-next items carry a release-ring sparkle:channel, which only
cmux-next builds allow; every other build ignores them. With
NIGHTLY_NEXT_DEV_RING=on a new build starts on Dev (cmux-next-dev)
and moves to Nightly (cmux-next) on a canary pass
(scripts/ci/nightly_next_ring.py, nightly-next-verdict.yml).
