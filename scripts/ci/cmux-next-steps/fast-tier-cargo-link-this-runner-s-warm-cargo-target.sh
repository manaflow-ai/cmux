#!/usr/bin/env bash
# cmux-next.yml fast-tier-cargo: "Link this runner's warm cargo target".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
disk=()
if [[ "$DISK_MOUNTED" == true ]]; then
  d=/home/runner/cmux-next-fast-tier-cargo-warm
  if [[ "$WARM_WRITES" == true ]] || compgen -G "$d/fast-tier-cargo/*/rust-*/.cmux-testbox-source-mtimes.tsv" > /dev/null; then
    disk=("$d")
  else
    echo "pool warm target: miss (no feat-cmux-next tree on the sticky disk yet); rust-cache restore instead"
  fi
fi
bash scripts/ci/pool-warm-target.sh restore fast-tier-cargo "${disk[@]}"
