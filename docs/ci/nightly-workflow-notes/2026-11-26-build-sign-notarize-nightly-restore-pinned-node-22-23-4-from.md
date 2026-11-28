# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Tools few people use download on first use too (bin/cmux-mobile-host, the iPhone
host): its pack goes in the language packs' tools/ and is published with them. On
with language packs; the repository variable CMUX_NEXT_TOOL_PACKS=0 turns it off.
