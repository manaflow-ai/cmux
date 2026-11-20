# Webview shard routing and cached verdicts

`ci-web.yml` plans pull-request test files before installing Bun or browsers. It reuses the existing
`webviews_affected.py` import graph, conservative dynamic-test rules, and duration-based shard assignment.
Pushes, `full-ci`, and build inputs run the complete suite. Unreadable selection inputs fail the
planner: one shard must never silently choose a different partition from its siblings.

The base-history artifact is fetched once and handed to every shard with the same duration manifest.
Only a recorded push at the exact merge-parent SHA permits skipping setup. Every file omitted by
the existing affected-test selector must have a cached green verdict. Missing, red, or incomplete
history preserves the existing selection and runs setup on every shard; it never expands a focused
PR into the full suite merely because history is unavailable.

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
