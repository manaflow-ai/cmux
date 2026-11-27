# nightly.yml: job `workflow_dispatch`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

SUPublicEDKey of the cmux-next track. The build refuses a
SPARKLE_NEXT_PRIVATE_KEY that does not derive this public key.
