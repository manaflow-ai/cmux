# publish-nightly: CEF_ON_DEMAND: ${{ vars.CMUX_NEXT_CEF_ON_DEMAND }}

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `CEF_ON_DEMAND: ${{ vars.CMUX_NEXT_CEF_ON_DEMAND }}`.

Chromium on demand and the source offer: the switches as they are now, except that a
republished build publishes the pack its source signed with (the app's pin names it), and
no source archive when its source made none.
