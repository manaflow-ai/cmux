# nightly.yml `verify-recovered-nightly-next`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- *github-token-for-git`

The same checkout the continuation used: its bundle notice check ran
from this workflow commit too.
