# 2026-11-27-republish-nightly-next-1

Above `- name: Upload the republished build's Chromium runtime pack` (job `republish-nightly-next`) in `.github/workflows/nightly.yml`.

publish-nightly reads the pack by this run's name when the source build has one (its cef
output), whatever CMUX_NEXT_CEF_ON_DEMAND says now: the app's pin names that pack.
