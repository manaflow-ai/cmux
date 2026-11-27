# nightly.yml: job `republish-nightly-next`, step "Upload the republished build's language packs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The same for the source build's language packs (its language_packs output), whatever
CMUX_NEXT_LANGUAGE_PACKS says now: the app's pin names them.
