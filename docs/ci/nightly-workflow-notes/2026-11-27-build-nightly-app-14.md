# 2026-11-27-build-nightly-app-14

Above `- name: Download the web bundles built beside the app (cmux-next)` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

A pattern, not a name: an artifact that is not there yet downloads
nothing instead of failing.
