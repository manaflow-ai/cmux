# nightly.yml: job `build-nightly-app`, step "Look up the nightly app compiled on the same inputs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Reuse the unsigned app of an earlier nightly-next build on the same inputs
(scripts/ci/nightly_release_product_reuse.py has the key and trust rules). A hit skips the
steps that only feed xcodebuild; stamping, signing and notarization always run.
vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE=0 switches the lookup and the record off.
