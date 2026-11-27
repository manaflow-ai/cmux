# 2026-11-26-build-nightly-app-3

Above `- name: Look up the nightly app compiled on the same inputs` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Reuse the unsigned app of an earlier nightly-next build on the same inputs
(scripts/ci/nightly_release_product_reuse.py has the key and trust rules). A hit skips the
steps that only feed xcodebuild; stamping, signing and notarization always run.
vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE=0 switches the lookup and the record off.

## nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

One build slot per run: a newer push builds beside an older one and never
replaces it (a shared slot evicted waiting builds, 2026-10-19). publish-nightly's
recheck refuses a build no newer than both feeds.
