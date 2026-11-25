# cmux-next.yml path_route: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `path_route` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `base_red_jobs: ${{ steps.base-red.outputs.red_jobs || '[]' }}`

The breaker-wired jobs red on feat-cmux-next now (JSON list, `[]` off a pull request): RFD 0148 row 12.

## 2

Stood above: `CI_GREEN_BASE_MERGE_SKIP: ${{ vars.CI_GREEN_BASE_MERGE_SKIP || '1' }}`

A head that only merges the base onto a green previous head starts nothing (head_tier.py); 0 turns that off.

## 3

Stood above: `- name: Jobs red on the base right now`

RFD 0148 row 12 (Leo, 2026-11-24: "ci! i hope we're continuing to cut and optimize"): a job red on
feat-cmux-next right now is red on the pull request too, and gh-merge-green excuses that red as the base's, so
it is not started (scripts/ci/base_red_skip.py: fails open, 10% of skips still run as the audit, label full-ci
runs it, vars.CI_SKIP_WHILE_BASE_RED == '0' turns it off). 2026-11-23: 6.8k PR minutes of fast tier (cargo) ran
while red on the base (fast tier itself is push-only since note-556) (build-fleet/data fleet-data-raw gh-jobs).
