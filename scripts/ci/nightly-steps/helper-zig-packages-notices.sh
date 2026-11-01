#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "libghostty-vt Zig packages are covered by the notices". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
out="$RUNNER_TEMP/source-archive"
source="$(python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py --print-source | sed -n 's/^libghostty-vt source: //p' | awk '{print $1}')"
manifests=(--license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json")
[[ "$source" == ghostty ]] || manifests+=(--license-manifest "$out/$source-licenses/SOURCE-MANIFEST.json")
python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py "${manifests[@]}" --link-graph scripts/cmux-next/notices/vt-link-graph.json
