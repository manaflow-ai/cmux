# early-nightly-webviews: red_sha: ${{ vars.NIGHTLY_COMPONENT_GATES == 'block' && steps.checks.outcome == 

Where: the `early-nightly-webviews` job in `.github/workflows/nightly.yml`, above `red_sha: ${{ vars.NIGHTLY_COMPONENT_GATES == 'block' && steps.checks.outcome == 'failure' && needs.d…`.

The commit whose webview checks failed, only while vars.NIGHTLY_COMPONENT_GATES is 'block': then
nightly-next-one and retry-nightly-next skip it. Default: a red check is a stale-part report, not a hold.
