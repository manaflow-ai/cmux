# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Languages download on first use (CMUX-570): the non-English strings leave the app
for language packs, which publish-nightly uploads before the appcast. On for
nightly-next; the repository variable CMUX_NEXT_LANGUAGE_PACKS=0 turns it off.
