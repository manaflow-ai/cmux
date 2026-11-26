# nightly.yml `promote-nightly-next`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `promote-nightly-next:`

Moves the protected branch `nightly-next` to a feat-cmux-next commit whose cmux-next.yml
push run passed its Release compile. Runs only on main, in `release`, with the release App
(the ruleset's only bypass actor). Guard: scripts/ci/promote-nightly-next.mjs, from this
main checkout. One concurrency group keeps a single writer; decideNewest() also decides the
newest request GitHub evicted (checks: read) whose commit contains this one's.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`

Ends on the nightly slot's label as a literal, never vars.CI_NIGHTLY_NEXT_BUILD_RUNNER: main's
repository-variable check (scripts/ci/signing_runner_variables.py) holds a variable a signing job
reads to blacksmith-*/ubuntu-*, and that variable names an owned Mac (#26450).
