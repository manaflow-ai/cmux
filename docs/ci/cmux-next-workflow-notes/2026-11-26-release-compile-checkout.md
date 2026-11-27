# cmux-next.yml: job `release-compile`, step "Checkout"

Moved out of `.github/workflows/cmux-next.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A fetch that breaks off is tried again by the action from nothing; bounded so a stalled transfer
moves on to the retry below instead of holding the Mac to the job's 60 min.
