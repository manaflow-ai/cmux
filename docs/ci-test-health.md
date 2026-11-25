# Measured base-test flakes

The base-health reconciler publishes `tap-tests/v1` to `ci-test-health:tap-tests.json`.
`scripts/ci/test_reds.py` is the shared parser for both its observations and PR
failure attribution. Each observation names a test, an explicit `pass` or `fail`,
and the diagnostic when available. A skipped, absent or unreported test is never
a pass. Crashed, truncated and runner-loss logs contribute no observations.

The state contains `generated_at` and a `tests` list. Each row contains `workflow`,
`job`, `test`, `last_observed_at`, `observations`, `passes`, `failures`, `flips`, `flip_rate`,
`failure_signatures`, and optionally `quarantine: {issue, until, signatures}`. Jobs use their
canonical name without a matrix shard suffix. Workflow names remain distinct.
The reconciler stores the durable history and opens the public quarantine issue.

The CLI reads the public snapshot once, with a five-second deadline. Set
`TAP_TESTS_STATE` to a local JSON path for a pinned replay, or to `off` to disable
the supplement. `--flake-state` selects an explicit snapshot. Library callers
pass `flake_state` and `workflow` to `classify` / `classify_any`; observation and
classification calls never perform network reads themselves.

A quarantine contributes base evidence only with a snapshot and latest observation at most 48 hours old,
at least eight observations including a pass and two failures, at least two
flips, and a flip rate of at least 0.2. The consumer recomputes the rate as
`flips / (observations - 1)`. The issue must be a public cmux issue and its expiry
must still be in the future and no more than seven days away. The head's nonempty diagnostic must exactly match one
of the quarantine's producer-bound `signatures` (at most 32 nonempty strings, each at most 4 KiB). The aggregate
historical `failure_signatures` list is retained for history and never authorizes a waiver by itself. Missing or malformed state retains the
existing deterministic comparison.

An active matching quarantine can bridge a green base verdict in
`base_red_excuse.py` only when the entire red is explained by named test failures
in test steps, with evidence attributed to every failed step. Timestamped Actions
job logs use the step start/end times; lines in a shared boundary second are
ambiguous and supply no step evidence. Missing timing keeps the normal base
comparison. Additional failed steps or unrelated errors remain blocking.
Crashes, incomplete runs, infrastructure losses and new diagnostics always keep
their existing treatment. The quarantine issue and expiry appear in the audit
output so every waiver has a repair destination.

The web runner exports completed named outcomes after retries with
`webviews_test_results.py --tap-markers SUMMARY`. Its `tap-test/v1` JSON records
appear in the `TAP final named results` log group, including green tests without
their raw logs. The shared reader prefers the last whole group and discards
conflicting duplicate test ids. The exporter streams one file at a time and
discards unreadable diagnostic floods using the existing log-line safety bound.
`TAP_CI_ENABLED=0` disables this export.

The required webview verdict also invokes `test_reds.py tap-flaky --workflow
'cmux-next web' --job react-apps-check --log-dir RAW_ARTIFACT_DIRECTORY`. It reads
the retained head summary and logs at their downloaded locations, selects exact
matching active quarantines, and merges those names into the existing
`guards_new_reds.py --flaky` input. Existing base comparisons and head retries
keep their behavior. Missing raw evidence contributes no waiver.
