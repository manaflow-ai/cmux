# nightly.yml: job `verify-recovered-nightly-next`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The same checkout the continuation used: its bundle notice check ran
from this workflow commit too.
