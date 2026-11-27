# nightly.yml: job `verify-final-dmg-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The final-DMG half of verify-signed-nightly, on its own runner so the two
halves run at the same time (each statically verifies an artifact with the same bundle
id, so they cannot share one runner). No environment and no secrets:
this job statically verifies the final DMG (#21024). publish-nightly
publishes this run's build only when both jobs passed, and only the DMG
bytes this job verified.
