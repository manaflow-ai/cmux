# 2026-11-26-build-sign-notarize-nightly-1

Above `- name: Checkout trusted signing controls` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

This run's own signing controls: the claim below and, for an unsigned resume, the keychain controls.
Only scripts/ and the workflow are read from it, so it is sparse: a fresh full clone into this path took
about 3 min of the one signer on every sign (run 41948676510, 04:42:55-04:46:05Z).
