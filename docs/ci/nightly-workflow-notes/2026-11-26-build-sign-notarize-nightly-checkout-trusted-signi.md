# build-sign-notarize-nightly: Checkout trusted signing controls

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `- name: Checkout trusted signing controls`.

This run's own signing controls: the claim below and, for an unsigned resume, the keychain controls.
Only scripts/ and the workflow are read from it, so it is sparse: a fresh full clone into this path took
about 3 min of the one signer on every sign (run 41948676510, 04:42:55-04:46:05Z).
