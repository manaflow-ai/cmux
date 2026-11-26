# refresh-test-compilation-cache: Record DerivedData seed inputs

Where: the `refresh-test-compilation-cache` job in `.github/workflows/nightly.yml`, above `- name: Record DerivedData seed inputs`.

ci-macos.yml compile admission adopts this build's DerivedData for pull
requests. The recorded content and times are how it tells which inputs
a later revision changed. See scripts/ci/seed_derived_data.py.
