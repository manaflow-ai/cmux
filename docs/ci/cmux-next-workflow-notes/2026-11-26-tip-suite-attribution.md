# 2026-11-26-tip-suite-attribution

Above `push-attribution: if` in `.github/workflows/cmux-next.yml` (beside note-341).

A red tip suite run is attributed too: the `tip_swift_suite` and `tip_daemon_suite` dispatches that main's
`cmux-next-tip-swift-suite-dispatch.yml` starts on the feat-cmux-next tip. Since 2026-11-26 a pull request into
feat-cmux-next runs neither swift test nor the Mac daemon tests (2026-11-26-mac-jobs-after-merge.md). These
dispatches are the jobs' first run, so without this a red one named nobody.
`cmux_next_push_attribution.py --events push,workflow_dispatch` compares the red job with the newest earlier run
where it passed. It comments on the pull requests merged in that range. When the history between them is
monotonic, it bisects to the first failing merge and notifies that PR's author to fix forward.
