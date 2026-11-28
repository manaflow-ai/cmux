# 2026-11-26-build-sign-notarize-nightly-3

Above `CMUX_NEXT_LANGUAGE_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PACKS != '0' && '1' || '' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Languages download on first use (CMUX-570): the non-English strings leave the app
for language packs, which publish-nightly uploads before the appcast. On for
nightly-next; the repository variable CMUX_NEXT_LANGUAGE_PACKS=0 turns it off.

## nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Sign and notarize on the same macOS 26 lane proven by stable releases.
actions:read lets the parallel artifact download resolve the blob URL.
