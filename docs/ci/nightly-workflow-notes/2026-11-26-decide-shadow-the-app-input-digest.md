# nightly.yml: job `decide`, step "Shadow the app-input digest"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Shadow only (clean-sheet CI RFD hq#26225): would a build add nothing because no app input changed since the last
published commit? Reports app_input_digest and would_reuse; decides nothing, cannot fail the job.
