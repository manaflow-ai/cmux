# nightly.yml: job `build-nightly-ghostty-cli-helper`, step "Strip the Ghostty CLI helper"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The strip-release-bundle.sh pass that prepare-nightly-variant ran on
the injected helper (helpers keep their global symbols). That job is on
Linux now, where only Apple's strip gives these bytes; a fast build's
prepare never stripped it.
