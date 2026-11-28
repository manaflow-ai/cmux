# 2026-11-26-build-sign-notarize-nightly-4

Above `CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PACKS != '0' && vars.CMUX_NEXT_TOOL_PACKS != '0' && '1' || '' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Tools few people use download on first use too (bin/cmux-mobile-host, the iPhone
host): its pack goes in the language packs' tools/ and is published with them. On
with language packs; the repository variable CMUX_NEXT_TOOL_PACKS=0 turns it off.

## nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

nightly-next is arm64 only, so its one matrix leg sets this; publish
waits for a later run when Apple had not accepted the build in time.
