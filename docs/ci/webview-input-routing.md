# Every webview input has a route

A benchmark shell script used to make every React shard run the full suite because
`webviews_affected.py` had no rule for its file type. Runtime assets, documentation,
benchmark drivers, imported modules, and global build inputs now have explicit rules.
Benchmark drivers select their importers and named readers, including the existing
conservative dynamic-reader set. Runtime assets without known readers still run the
full suite; this change does not assume that an unimported stylesheet is unused.

The existing web scope job runs `webviews_affected.py --check-routes` before planning
shards. It audits the tracked file list and fails on a new input type without a rule.
A failed Git read cannot count as complete coverage. Keep the rule and its regression
in `tests/test_ci_webviews_affected.py` together. Run that file through `cmux-ci test`.

The detector covers routing omissions, not dependency completeness. The separate
dependency selector decides which tests consume each input. Push runs retain the full
suite. Production savings require completed job records from the same timing feed;
fewer selected files alone do not establish saved minutes.
