# 2026-11-27-refresh-test-compilation-cache-1

Above `- name: Record DerivedData seed inputs` (job `refresh-test-compilation-cache`) in `.github/workflows/nightly.yml`.

ci-macos.yml compile admission adopts this build's DerivedData for pull
requests. The recorded content and times are how it tells which inputs
a later revision changed. See scripts/ci/seed_derived_data.py.
