# build-sign-notarize-nightly: CMUX_NEXT_LANGUAGE_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && va

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `CMUX_NEXT_LANGUAGE_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAG…`.

Languages download on first use (CMUX-570): the non-English strings leave the app
for language packs, which publish-nightly uploads before the appcast. On for
nightly-next; the repository variable CMUX_NEXT_LANGUAGE_PACKS=0 turns it off.
