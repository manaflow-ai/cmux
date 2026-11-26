# 2026-11-26-build-sign-notarize-nightly-4

Above `CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PACKS != '0' && vars.CMUX_NEXT_TOOL_PACKS != '0' && '1' || '' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Tools few people use download on first use too (bin/cmux-mobile-host, the iPhone
host): its pack goes in the language packs' tools/ and is published with them. On
with language packs; the repository variable CMUX_NEXT_TOOL_PACKS=0 turns it off.
