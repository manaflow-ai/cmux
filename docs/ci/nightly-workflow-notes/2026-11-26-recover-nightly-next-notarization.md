# nightly.yml: job `recover-nightly-next-notarization`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

An accepted continuation builds, signs and notarizes the DMG around the
stapled app (notarize-nightly-dmg.sh, CMUX_STAPLE_APP_IN_DMG): a 20m wait
and packaging per candidate; a failed one moves on to the next of 3.
