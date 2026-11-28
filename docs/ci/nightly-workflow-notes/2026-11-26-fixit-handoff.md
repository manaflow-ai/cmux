# nightly.yml: job `fixit-handoff`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The nightly's webview type check red with no machine fix (fixit-compile): fixit-handoff.yml, dispatched on
feat-cmux-next, names the culprit and pushes its revert when clear, else opens the revert's pull request. Leo,
2026-11-22: "if the fix is clear i think you guys should be able to unilaterally push commits directly." A job of
its own that only dispatches; check-nightly-webviews stays read-only.
