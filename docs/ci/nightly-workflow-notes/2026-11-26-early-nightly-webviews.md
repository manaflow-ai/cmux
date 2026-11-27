# nightly.yml: job `early-nightly-webviews`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The commit whose webview checks failed, only while vars.NIGHTLY_COMPONENT_GATES is 'block': then
nightly-next-one and retry-nightly-next skip it. Default: a red check is a stale-part report, not a hold.
