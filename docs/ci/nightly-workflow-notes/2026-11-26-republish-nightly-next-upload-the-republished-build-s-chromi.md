# nightly.yml: job `republish-nightly-next`, step "Upload the republished build's Chromium runtime pack"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

publish-nightly reads the pack by this run's name when the source build has one (its cef
output), whatever CMUX_NEXT_CEF_ON_DEMAND says now: the app's pin names that pack.
