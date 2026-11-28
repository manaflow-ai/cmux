# nightly.yml: job `build-sign-notarize-nightly`, step "Install the current signing keychain controls"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

macOS /bin/bash 3.2 exits 0 on a parse error in a script with an EXIT
trap (runs 39014131817, 39014922771). Parse every script this job can
run before any signing or notarization. An unsigned resume builds an
older tree: the checker and the workflow come from the signing control
(this run's commit), the scripts from the build tree.
