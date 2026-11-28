# 2026-11-26-retry-nightly-next-1

Above `fixit-handoff:` (job `retry-nightly-next`) in `.github/workflows/nightly.yml`.

The nightly's webview type check red with no machine fix (fixit-compile): fixit-handoff.yml, dispatched on
feat-cmux-next, names the culprit and pushes its revert when clear, else opens the revert's pull request. Leo,
2026-11-22: "if the fix is clear i think you guys should be able to unilaterally push commits directly." A job of
its own that only dispatches; check-nightly-webviews stays read-only.
