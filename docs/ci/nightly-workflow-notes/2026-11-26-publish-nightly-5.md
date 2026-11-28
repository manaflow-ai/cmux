# nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Visual coverage is advisory: route, capture, and verdict jobs still report findings, but
neither a display queue nor an enforce-mode verdict can hold publication.
