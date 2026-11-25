#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "Build the cmux-next source archive". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# cmux-next release source archive: Ghostty at its submodule revision and
# every Zig package of the build, so the MPL-2.0 source offer for Ghostty's
# Zig packages names an archive this release publishes (and the public
# cmux-next-src-<commit> tag) instead of upstream URLs. Built and verified
# (twice, byte-identical) only while vars.CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE
# is 1, the same gate the publish job attaches it under; otherwise only
# the license trees (cmux-next-source-archive.yml dry-runs the tarball).
# Blocking: a Ghostty Zig package with no license text (or any other
# collect, verify or reproducibility failure) fails this job, so the sign
# job never runs and no nightly-next ships without the license tree.
# tests/test_nightly_next_source_archive.py holds this.
# The tarball only when this build may publish it; the license trees always.
set -euo pipefail
if ! ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig" \
  ./scripts/cmux-next/build-ghostty-source-archive.sh "$RUNNER_TEMP/source-archive"; then
  echo "::error title=cmux-next source archive failed::If the log names a Ghostty package without a license file, review its upstream license and pin the text in cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json (update PINNED_MANIFEST_SHA256 in collect-ghostty-licenses.py). nightly-next does not ship without the Ghostty license tree."
  exit 1
fi
