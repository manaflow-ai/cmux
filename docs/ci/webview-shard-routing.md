# Webview shard routing and cached verdicts

`ci-web.yml` plans pull-request test files before installing Bun or browsers. It reuses the existing
`webviews_affected.py` import graph, conservative dynamic-test rules, and duration-based shard assignment.
Pushes, `full-ci`, build inputs, and unreadable selection inputs run the complete suite.

The base-history artifact is fetched once and handed to every shard with the same duration manifest.
Only a recorded push at the exact merge-parent SHA permits reuse. Uncovered files and files red on
that push stay in the selected set. Missing or unreadable history falls back to the full suite.
This deliberately sacrifices savings when there is no trustworthy base receipt.

Shard 1 always runs shared checks even if its test assignment is empty. The final gate follows
`setup`, while the test step follows `run`. Empty result artifacts require a successful focused
plan; they contain no synthetic passing test results. Shard 1 supplies actual runner scripts so
joining an empty first shard cannot break base replay. `full-ci` never recomputes a narrowed list.

Detector: `tests/test_ci_webviews_shard_scope.py` executes the workflow's test/empty-artifact shell
blocks and joins their artifacts. It checks exact-base history, missing/red file verdicts, full
fallback, disjoint assignment, and shared setup. Run through `cmux-ci test` after changing the
planner or workflow. Planner changes are routed through the web subarea and global input lists.

Performance evidence must compare job minutes from the same timing feed and windows, including
fallback/full runs. The small regression fixture proves coverage, not production savings. Browser,
process-spawning and dynamic-import tests remain conservatively selected, so a small source diff
can still occupy every shard. Do not infer a one-shard saving from the fixture.
