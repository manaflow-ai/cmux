# nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

nightly-next: pick-nightly-build-runner's dedicated builder, else an idle owned
label, else the moving Blacksmith label; never one label with no fallback. Main's
ci-cache-writer environment never follows NEXT onto that worker.
