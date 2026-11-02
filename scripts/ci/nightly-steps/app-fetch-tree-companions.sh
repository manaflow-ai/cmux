#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Fetch the resolved cmux-tui tree companions". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The resolved tree's attested acpmux companion: an input of Bundle acpmux.
set -euo pipefail
scripts/cmux-next/pin-cmux-tui.sh fetch-acpmux
acpmux_bin="$(scripts/cmux-next/pin-cmux-tui.sh acpmux-path)"
[[ -x "$acpmux_bin" ]] || { echo "error: fetched tree has no executable acpmux companion" >&2; exit 1; }
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
echo "Using attested same-tree acpmux companion: $acpmux_bin"

# The resolved client "Bundle the cmux-tui client" installs after the compile: fetch and verify it into
# CMUX_TUI_CLIENT_CACHE now, in the background beside the compile, on a scratch bundle. Its downloads took
# 30-100 s of that step (runs 41481821056-41485637444); install-cmux-tui-client.sh reuses a cached slice
# only when its sha256 matches the attested manifest, so the install there checks everything again and
# a failed prefetch only leaves it to download as before (app-bundle-cmux-tui-client.sh joins it).
if [[ "${CMUX_TUI_CLIENT_COMMIT:-}" =~ ^[0-9a-f]{40}$ && -n "${CMUX_TUI_CLIENT_CACHE:-}" ]]; then
  scratch="$RUNNER_TEMP/cmux-tui-prefetch/cmux.app"
  rm -rf "${scratch%/*}"
  mkdir -p "$scratch/Contents"
  # The token reaches only the prefetch (its attestation check), never the fetch above.
  GH_TOKEN="${PREFETCH_GH_TOKEN:-}" \
    python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" cmux-tui-client -- \
    ./scripts/install-cmux-tui-client.sh "$scratch" \
    --manifest-url "https://files.cmux.com/cmux-tui/${CMUX_TUI_CLIENT_COMMIT}/manifest.json" \
    --expected-commit "$CMUX_TUI_CLIENT_COMMIT" \
    --require-capability wireguard-hub \
    --require-acpmux \
    || echo "::warning title=cmux-tui prefetch::could not start; Bundle the cmux-tui client downloads it"
fi
