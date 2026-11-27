# 2026-11-27-refresh-test-compilation-cache-2

Above `- name: Bound DerivedData seed size` (job `refresh-test-compilation-cache`) in `.github/workflows/nightly.yml`.

R2 only: a multi-gigabyte entry in the GitHub store evicts the seeds
above (#13160). A failure here never fails the seed.
