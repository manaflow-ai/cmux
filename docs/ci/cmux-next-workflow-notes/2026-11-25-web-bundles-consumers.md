# web-bundles: a pull request builds the bundles only for a job that restores them

Job `web-bundles`, its `if`. Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."

Only `swift-test`, `daemon-test` and `generated-files` restore the bundles, and each has a stricter gate than
"swift, daemon or generated routed": `swift-test` is off on a feat-cmux-next pull request without `full-ci`,
`daemon-test` needs `tree_state == 'ready'`, and `generated-files` runs only on `generated_host == 'generated-files'`.
In the 24 h to 2026-11-25, 7.0k of this job's 7.8k runner minutes ran in runs where none of the three ran. A pull
request now takes the same three gates. Pushes and dispatches still always run it (the feat-cmux-next push
publishes the bundles to R2). The consumers accept a skipped `web-bundles` and fall back to R2, then the actions
cache, then their own build. `tests/test_cmux_next_checks_workflow.py` checks the producer against the consumers' `if`s.
