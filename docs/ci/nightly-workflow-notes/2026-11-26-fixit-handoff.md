# nightly.yml `fixit-handoff`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `fixit-handoff:`

The nightly's webview type check red with no machine fix (fixit-compile): fixit-handoff.yml, dispatched on
feat-cmux-next, names the culprit and pushes its revert when clear, else opens the revert's pull request. Leo,
2026-11-22: "if the fix is clear i think you guys should be able to unilaterally push commits directly." A job of
its own that only dispatches; check-nightly-webviews stays read-only.

## 2

Above: `- name: Dispatch fixit-handoff on feat-cmux-next`

Off the publish path: a rate-limited dispatch fails now instead of waiting, and never reds the nightly
(tests/test_gh_budget_wait.py DISPATCH_NEVER_WAITS).
