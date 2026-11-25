# cmux-next.yml daemon-test: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `daemon-test` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"`

An inherited socket would still name another home's daemon; empty is unset.

## 2

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 3

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 4

Stood above: `if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] && [[ "$(python3 -I -c 'import json, os; print(str((json.load(open(os.environ["GITHUB_EVENT_PATH"])).get("inputs") or {}).get("base_tier", "")).lower())')" != true ]]; then`

A dispatch packs only as the base tier run (its base_tier input, read from the event so this
step needs no input the workflow may not declare).

## 5

Stood above: `out="$RUNNER_TEMP/generated/files"`

The regenerated files themselves, at their repository paths, so
they copy onto the PR head. A diff would be against the merge
commit, whose context the head may not have.

## 6

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-263`

Also after a failure or a cancel: end the daemon of this job's home and

## 7

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-556`

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." While cmux-next generated files
is red on feat-cmux-next's base tier run (cmux-next-base-tier-kick.yml; pushes skip the job), a pull request's
Mac run of it is red too and gh-merge-green excuses that red as the base's, so it is skipped
(scripts/ci/base_red_skip.py: fails open, 10% of skips still run as the audit, label full-ci runs it,
vars.CI_SKIP_WHILE_BASE_RED == '0' turns it off). 2026-11-24: 0 of 37 PR runs green in 2 h, about 10k min a day.

## 8

Stood above: `CMUX_SWIFT_TEST_PRODUCTS: ${{ vars.CI_FAST_TIER_PRODUCTS_FLEET == '1' && env.CMUX_NEXT_FOLD_GENERATED != 'true' && 'fleet' || 'build' }}`

Fleet-built test bundles for this commit (scripts/ci/fleet-test-products.py), off unless
vars.CI_FAST_TIER_PRODUCTS_FLEET is 1. The generated-files checks need the whole build, so a job
that folds them builds here as before; so does any job the fleet has no products for.
