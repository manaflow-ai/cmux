# nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

rc/** branches share one release. Serialize its mutable aliases and feeds
by channel, even when workflow-level groups have different branch names.
nightly-next takes a group of its own run and the R2 lease below instead:
a shared group cancelled run 41436891188's pending publish for a newer one.
