# nightly.yml: job `build-nightly-ghostty-cli-helper`, step "Upload cmux-next license trees"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Signing only embeds the license trees. Keep that handoff separate from
the optional source offer so each signing leg does not download the
complete source archive just to copy a few notices into the app.
