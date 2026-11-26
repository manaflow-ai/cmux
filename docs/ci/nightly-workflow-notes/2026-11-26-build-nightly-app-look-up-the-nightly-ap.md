# build-nightly-app: Look up the nightly app compiled on the same inputs

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- name: Look up the nightly app compiled on the same inputs`.

Reuse the unsigned app of an earlier nightly-next build on the same inputs
(scripts/ci/nightly_release_product_reuse.py has the key and trust rules). A hit skips the
steps that only feed xcodebuild; stamping, signing and notarization always run.
vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE=0 switches the lookup and the record off.
