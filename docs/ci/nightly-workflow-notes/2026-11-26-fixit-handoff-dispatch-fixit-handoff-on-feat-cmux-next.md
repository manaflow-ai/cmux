# nightly.yml: job `fixit-handoff`, step "Dispatch fixit-handoff on feat-cmux-next"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Off the publish path: a rate-limited dispatch fails now instead of waiting, and never reds the nightly
(tests/test_gh_budget_wait.py DISPATCH_NEVER_WAITS).
