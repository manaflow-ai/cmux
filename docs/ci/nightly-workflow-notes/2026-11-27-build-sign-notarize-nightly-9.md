# 2026-11-27-build-sign-notarize-nightly-9

Above `CMUX_NEXT_CEF_ON_DEMAND: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_CEF_ON_DEMAND == '1' && '1' || '' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md 6.6): off
until the repository variable CMUX_NEXT_CEF_ON_DEMAND is 1.
