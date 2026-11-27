# nightly.yml: job `refresh-compilation-cache`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The schedule skips this cloud warmer while owned pools serve pull
requests (CI_PR_POOL_OWNED is 1). build-nightly-app saves the same key on
every published main push, so the remaining cloud readers (main's
full-suite dispatch, nightly's hosted fallback) restore at worst an
older entry by prefix. It runs on Blacksmith macOS, never a hosted Mac
(tests/test_ci_nightly_no_hosted_mac.py). A seed_only dispatch still warms it on demand.
