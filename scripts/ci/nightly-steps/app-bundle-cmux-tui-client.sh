#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bundle the cmux-tui client". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# One attested commit manifest for every variant, also on a reused app: the
# resolved commit, or while the tree publishes the one await-tree-client.sh finds.
# install-cmux-tui-client.sh verifies the manifest's build-provenance
# attestation with gh before trusting it.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
cmux_tui_commit="$CMUX_TUI_CLIENT_COMMIT"
if [[ "$TREE_PENDING" == true ]]; then
  read -r -a c <<<"$TREE_CANDIDATES"
  cmux_tui_commit="$(scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"
fi
[[ "$cmux_tui_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "resolve-nightly-cmux-tui-client produced no commit" >&2; exit 1; }
# The prefetch "Fetch the resolved cmux-tui tree companions" started beside the compile
# (app-fetch-tree-companions.sh). A failed or unfinished one is ended and its cache
# dropped, so the install below downloads everything itself, as it did without it.
state="$RUNNER_TEMP/nightly-helper-builds"
if [[ -f "$state/cmux-tui-client.pid" ]]; then
  set +e
  python3 scripts/ci/background_build.py join --state "$state" cmux-tui-client --timeout 120 2>&1 \
    | sed 's/^::error::/::warning::/'
  joined=${PIPESTATUS[0]}
  set -e
  if [[ "$joined" -ne 0 ]]; then
    python3 scripts/ci/background_build.py stop --state "$state"
    rm -rf "${CMUX_TUI_CLIENT_CACHE:?}"
  fi
fi
./scripts/install-cmux-tui-client.sh \
  "$app" \
  --manifest-url "https://files.cmux.com/cmux-tui/${cmux_tui_commit}/manifest.json" \
  --expected-commit "$cmux_tui_commit" \
  --require-capability wireguard-hub \
  --require-acpmux
# The client and its SSH payloads arrive after the strip above, so
# strip again; already-stripped binaries are unchanged. bin/cmux-tui and
# bin/acpmux are symlinks to bin/cmux.
./scripts/strip-release-bundle.sh "$app"
./scripts/cmux-next/write-cmux-tui-version.sh "$app" "$cmux_tui_commit" "$CMUX_TUI_CLIENT_KEY"
./scripts/cmux-next/check-daemon-capabilities.sh --static-only --binary "$app/Contents/Resources/bin/cmux-tui"
echo "commit=$cmux_tui_commit" >> "$GITHUB_OUTPUT"
