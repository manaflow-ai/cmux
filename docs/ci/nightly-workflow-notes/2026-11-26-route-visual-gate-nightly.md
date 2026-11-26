# nightly.yml `route-visual-gate-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `route-visual-gate-nightly:`

this run's commit on an idle owned Mac, checked beside the signed build. Skipped (`unavailable`)
with no idle runner; only `enforce` with a failing verdict holds this run's build.

## 2

Above: `- name: Mint the owned-pool routing token`

Idle runners are read live, as side_lane_placement.py does. Any
failure leaves the token empty, and the gate is skipped.
