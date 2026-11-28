# nightly.yml: job `resolve-nightly-cmux-tui-client`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Runs beside build-nightly-app. Deepening the shallow clone to find the
newest published cmux-tui commit took 1.5 to 11 minutes after the Xcode
compile (runs 36044415287, 36051668491); here it overlaps the compile.
