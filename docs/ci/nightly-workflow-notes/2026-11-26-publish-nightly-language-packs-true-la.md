# publish-nightly: language_packs=true language_packs_run=

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `language_packs=true language_packs_run=`.

Language packs (CMUX-570) are on unless CMUX_NEXT_LANGUAGE_PACKS is 0; a recovered build's
packs stay in its own run (language_packs_run), a republished one's come from its receipt.
