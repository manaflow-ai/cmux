#!/usr/bin/env bash
# cmux-next.yml daemon-test: "Replay the seed's input times".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
python3 scripts/ci/owned_spm_scratch.py drop-bundles "$ROOT/Packages/macOS/CmuxNext/.build"
python3 -I scripts/ci/e2e_warm_derived_data.py replay "$ROOT" "$ROOT/Packages/macOS/CmuxNext/.build/cmux-fast-tier-input-mtimes.json"
if [[ "$SEED_ROOT" == 1 ]]; then python3 scripts/ci/owned_spm_scratch.py seeded; fi
