# 2026-11-27-refresh-test-compilation-cache-3

Above `- name: Scope DerivedData seed key` (job `refresh-test-compilation-cache`) in `.github/workflows/nightly.yml`.

Seeds serve only the Swift job width they were built at; see
scripts/ci/seed_derived_data.py.
