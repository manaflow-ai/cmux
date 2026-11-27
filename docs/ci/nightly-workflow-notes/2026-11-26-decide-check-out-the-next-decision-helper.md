# nightly.yml: job `decide`, step "Check out the NEXT decision helper"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

NEXT's decision reads release metadata, not the app tree. Main's build-input
classifier still needs the full checkout above, including tracked referrers.
