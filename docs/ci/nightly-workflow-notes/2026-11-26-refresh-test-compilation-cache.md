# nightly.yml `refresh-test-compilation-cache`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Record DerivedData seed inputs`

ci-macos.yml compile admission adopts this build's DerivedData for pull
requests. The recorded content and times are how it tells which inputs
a later revision changed. See scripts/ci/seed_derived_data.py.

## 2

Above: `- name: Bound DerivedData seed size`

R2 only: a multi-gigabyte entry in the GitHub store evicts the seeds
above (#13160). A failure here never fails the seed.

## 3

Above: `- name: Scope DerivedData seed key`

Seeds serve only the Swift job width they were built at; see
scripts/ci/seed_derived_data.py.
