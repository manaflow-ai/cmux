# nightly.yml: job `publish-nightly-next-github`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

An upload holds the release App key but signs nothing: a fresh hosted VM per job, so no other job shares it and
the signer stays free for the next sign (one-mini mode too: on the mini it would need the whole-Mac claim).
