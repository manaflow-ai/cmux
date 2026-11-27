# nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The cloud cache is scoped per branch and also drops main's own
entry (runs 35179030871 and 35182663752 restored nothing and were
cancelled at 45 minutes mid-compile), so the budget must fit a cold
build, not only a warm one.
