# nightly.yml `resolve-nightly-cmux-tui-client`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `resolve-nightly-cmux-tui-client:`

Runs beside build-nightly-app. Deepening the shallow clone to find the
newest published cmux-tui commit took 1.5 to 11 minutes after the Xcode
compile (runs 36044415287, 36051668491); here it overlaps the compile.

## 2

Above: `continue-on-error: true`

A reused checkout whose store makes git's pack-objects BUG() out (signal 6) fails every retry in place;
the next two steps drop that store and check out fresh. Leo, 2026-11-25: "are we able to decouple".
