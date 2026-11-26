# build-sign-notarize-nightly: CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.C

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PA…`.

Tools few people use download on first use too (bin/cmux-mobile-host, the iPhone
host): its pack goes in the language packs' tools/ and is published with them. On
with language packs; the repository variable CMUX_NEXT_TOOL_PACKS=0 turns it off.
