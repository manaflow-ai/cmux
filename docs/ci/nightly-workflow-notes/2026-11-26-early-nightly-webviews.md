# nightly.yml `early-nightly-webviews`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `red_sha: ${{ vars.NIGHTLY_COMPONENT_GATES == 'block' && steps.checks.outcome == 'failure' && needs.decide.outputs.head_s`

The commit whose webview checks failed, only while vars.NIGHTLY_COMPONENT_GATES is 'block': then
nightly-next-one and retry-nightly-next skip it. Default: a red check is a stale-part report, not a hold.
