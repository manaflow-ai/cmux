#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "libghostty-vt Zig packages are covered by the notices". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# bin/cmux links libghostty-vt from the submodule ghostty-vt-sys's
# build.rs selects, at this commit's gitlink (no product override). Every
# Zig package it declares must be in a shipped license tree; a gap stops
# nightly-next. tests/test_nightly_next_source_archive.py holds this.
set -euo pipefail
out="$RUNNER_TEMP/source-archive"
source="$(python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py --print-source | sed -n 's/^libghostty-vt source: //p' | awk '{print $1}')"
manifests=(--license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json")
[[ "$source" == ghostty ]] || manifests+=(--license-manifest "$out/$source-licenses/SOURCE-MANIFEST.json")
python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py "${manifests[@]}" --link-graph scripts/cmux-next/notices/vt-link-graph.json
