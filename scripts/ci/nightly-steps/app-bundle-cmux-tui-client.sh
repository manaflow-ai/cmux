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
# nightly-next compiles arm64 only (NIGHTLY_COMPILE_ARCHS); thin-app-bundle.sh drops any x86_64 slice
# before signing, so fetch only the slices the variants ship. Run 42675465011 failed on an x86_64 slice
# files.cmux.com trickled at 6 KB/s, a slice that build would have thrown away.
client_arch=universal
[[ "${NIGHTLY_COMPILE_ARCHS:-}" == arm64 ]] && client_arch=arm64
app="build-universal/Build/Products/Release/cmux.app"
cmux_tui_commit="$CMUX_TUI_CLIENT_COMMIT"
client_key="$CMUX_TUI_CLIENT_KEY"
tree_used=exact
# While the tip's tree publishes (TREE_PENDING), the app installs that tree's client when it is
# published by now (one look: the tree, then each candidate's manifest). Otherwise it installs
# the newest published tree's client (TREE_FALLBACK, from resolve-tree-pending.sh) right away:
# waiting up to 45 min for the tip's tree, failing, and waiting again on the retry cost 23.8 h
# of 48.6 h (RFD 0021 row 1, 2026-11-19 to 21). With no fallback tree, or
# CMUX_TUI_TREE_CLIENT_FALLBACK=off, it waits for the tip's tree as before.
if [[ "$TREE_PENDING" == true ]]; then
  read -r -a c <<<"$TREE_CANDIDATES"
  fallback_commit="" fallback_key=""
  read -r fallback_commit fallback_key _ <<<"${TREE_FALLBACK:-}" || true
  if [[ "${CMUX_TUI_TREE_CLIENT_FALLBACK:-on}" != off && "$fallback_commit" =~ ^[0-9a-f]{40}$ && "$fallback_key" =~ ^[0-9a-f]{40}$ ]]; then
    if cmux_tui_commit="$(CMUX_TUI_TREE_CLIENT_WAIT_SECONDS=0 scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"; then
      echo "::notice title=cmux-tui client::exact tree $CMUX_TUI_CLIENT_KEY of the build commit, from ${cmux_tui_commit:0:12}"
    else
      cmux_tui_commit="$fallback_commit" client_key="$fallback_key" tree_used=fallback
      echo "::warning title=cmux-tui client::the build commit's tree $CMUX_TUI_CLIENT_KEY is not published yet; bundling the newest published tree $fallback_key (published by $fallback_commit) instead of waiting for it"
    fi
  else
    echo "no fallback tree (TREE_FALLBACK='${TREE_FALLBACK:-}', CMUX_TUI_TREE_CLIENT_FALLBACK=${CMUX_TUI_TREE_CLIENT_FALLBACK:-on}); waiting for tree $CMUX_TUI_CLIENT_KEY" >&2
    cmux_tui_commit="$(scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"
  fi
fi
[[ "$cmux_tui_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "resolve-nightly-cmux-tui-client produced no commit" >&2; exit 1; }
# The prefetch "Fetch the resolved cmux-tui tree companions" (app-fetch-tree-companions.sh), or while the
# tree publishes "Prefetch the cmux-tui client while the tree publishes" (app-prefetch-pending-cmux-tui.sh),
# started beside the compile. A failed or unfinished one is ended and its cache dropped, so the install
# below downloads everything itself, as it did without it. A pending tree's prefetch waits for the tree as
# await-tree-client.sh above did, so by now it is at most one 20 s poll behind: 60 s more for it.
state="$RUNNER_TEMP/nightly-helper-builds"
join_timeout=120
[[ "$TREE_PENDING" == true ]] && join_timeout=180
if [[ "$tree_used" == fallback && -f "$state/cmux-tui-client.pid" ]]; then
  # The pending prefetch waits for the tip's tree, which this build no longer installs. Only it:
  # other helpers (webview-checks) are joined later.
  python3 scripts/ci/background_build.py stop --state "$state" cmux-tui-client
  rm -rf "${CMUX_TUI_CLIENT_CACHE:?}"
elif [[ -f "$state/cmux-tui-client.pid" ]]; then
  set +e
  python3 scripts/ci/background_build.py join --state "$state" cmux-tui-client --timeout "$join_timeout" 2>&1 \
    | sed 's/^::error::/::warning::/'
  joined=${PIPESTATUS[0]}
  set -e
  if [[ "$joined" -ne 0 ]]; then
    python3 scripts/ci/background_build.py stop --state "$state"
    rm -rf "${CMUX_TUI_CLIENT_CACHE:?}"
  fi
fi
install_client() {
  ./scripts/install-cmux-tui-client.sh \
    "$app" \
    --arch "$client_arch" \
    --manifest-url "https://files.cmux.com/cmux-tui/${cmux_tui_commit}/manifest.json" \
    --expected-commit "$cmux_tui_commit" \
    --require-capability wireguard-hub \
    --require-acpmux \
    --require-companions
}
if [[ "$tree_used" == fallback ]] && ! install_client; then
  # A fallback tree the installer refuses (an older tree without a required capability): the
  # tip's own tree after all, with the bounded wait.
  echo "::warning title=cmux-tui client::the fallback tree $client_key did not install; waiting for the build commit's tree $CMUX_TUI_CLIENT_KEY"
  cmux_tui_commit="$(scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"
  client_key="$CMUX_TUI_CLIENT_KEY" tree_used=exact
  [[ "$cmux_tui_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "await-tree-client.sh produced no commit" >&2; exit 1; }
  install_client
elif [[ "$tree_used" != fallback ]]; then
  install_client
fi
# The client and its SSH payloads arrive after the strip above, so
# strip again; already-stripped binaries are unchanged. bin/cmux-tui and
# bin/acpmux are symlinks to bin/cmux.
./scripts/strip-release-bundle.sh "$app"
./scripts/cmux-next/write-cmux-tui-version.sh "$app" "$cmux_tui_commit" "$client_key"
./scripts/cmux-next/check-daemon-capabilities.sh --static-only --binary "$app/Contents/Resources/bin/cmux-tui"
# Which tree shipped: the marker gate (await-tree-marker.sh) reads key= to accept a fallback tree.
echo "cmux-tui client: $tree_used tree $client_key from $cmux_tui_commit (build commit's tree: ${CMUX_TUI_CLIENT_KEY:-none})"
{
  echo "### cmux-tui client bundled"
  echo "- $tree_used tree \`$client_key\`, client of \`$cmux_tui_commit\`"
  [[ "$tree_used" != fallback ]] || echo "- the build commit's tree \`$CMUX_TUI_CLIENT_KEY\` was not published yet"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "commit=$cmux_tui_commit"
  echo "key=$client_key"
  echo "tree=$tree_used"
} >> "$GITHUB_OUTPUT"
