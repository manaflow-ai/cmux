# nightly.yml: job `published-in`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Each write is paced at 7.5 s under GitHub's hourly content limit.
A shared edit plus a legacy deletion for all 1,000 allowed PRs takes
250 min; leave room for reads. This runs after publication.
