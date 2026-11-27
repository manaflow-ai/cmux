# 2026-11-27-early-nightly-webviews-1

Above `red_sha: ${{ vars.NIGHTLY_COMPONENT_GATES == 'block' && steps.checks.outcome == 'failure' && needs.decide.outputs.head_sha || '' }}` (job `early-nightly-webviews`) in `.github/workflows/nightly.yml`.

The commit whose webview checks failed, only while vars.NIGHTLY_COMPONENT_GATES is 'block': then
nightly-next-one and retry-nightly-next skip it. Default: a red check is a stale-part report, not a hold.
