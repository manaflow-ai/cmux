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
# published within CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS (default 1500). Otherwise it installs
# the newest published tree's client (TREE_FALLBACK, from resolve-tree-pending.sh), and never fails:
# waiting up to 45 min for the tip's tree, failing, and waiting again on the retry cost 23.8 h
# of 48.6 h (RFD 0021 row 1, 2026-11-19 to 21). The bounded wait only lasts while a same-key
# cmux-tui artifacts run is making progress: await-tree-client.sh stops after two idle checks,
# about 5 min, when nothing will publish the tree, and lasts up to CMUX_TUI_TREE_CLIENT_REBUILD_GRACE_SECONDS
# (default 1200) longer while that run rebuilds a primary macOS leg a runner shutdown killed. A single look (the old behavior, still set by
# ..._FALLBACK_WAIT_SECONDS=0) shipped a client 75 commits behind its app. Run 45825165164
# (tip cec1e3c, 2026-11-26) looked at 13:16:42Z, but tree 2460ebd1 was published at 13:40:41Z by
# artifacts run 45825165044, which the same push had started. So every nightly whose tip changed
# the tree shipped the previous tree, and a merged Rust change missed that NIGHTLY. With no
# fallback tree, or CMUX_TUI_TREE_CLIENT_FALLBACK=off, it waits for the tip's tree as before.
fallback_wait="${CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS:-1500}"
[[ "$fallback_wait" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS must be whole seconds" >&2; exit 2; }
# This step runs on the signing Mac: with a fallback tree in hand, two unreadable runs answers in a row
# (about 5 min) bundle it rather than hold that Mac for the whole bound (await-tree-client.sh's notes).
unreadable_checks="${CMUX_TUI_TREE_CLIENT_UNREADABLE_CHECKS:-2}"
# Likewise a publisher rebuilding its failed primary macOS leg lands the tree about 30 min late: with a
# fallback tree in hand, the first such answer bundles it (NIGHTLY 46123570780 held that Mac 1869 s for one).
rebuild_ends="${CMUX_TUI_TREE_CLIENT_REBUILD_ENDS:-1}"
# And a publisher that failed (on any attempt) ends it at the first check, not a second one 5 min later
# for a retry that lands the tree long after this Mac moves on (NIGHTLY 46146914237: 254 s).
failed_ends="${CMUX_TUI_TREE_CLIENT_FAILED_ENDS:-1}"
# Leo, 2026-11-26: "cant we just accept the nightly using an older tui version". TREE_FALLBACK is
# searched once, in resolve-nightly-cmux-tui-client, about an hour before this step. A tree published
# in between never reached the bundle: nightlies 46114171177, 46116717235 and 46119598955
# (2026-11-28) read "TREE_FALLBACK: " (the newest trees within 24 h were still publishing at
# resolve time), the tip's own artifacts run then failed build-linux, and each failed here,
# though by now tree 0a91e0f1 (32 commits, 0 h behind) was published. So with no fallback in
# hand this step searches again, the same search (pin-cmux-tui.sh resolve-newest-published,
# 24 h bound), before waiting, and once more if the wait fails.
fallback_search_seconds="${CMUX_TUI_TREE_BUNDLE_FALLBACK_SEARCH_SECONDS:-300}"
[[ "$fallback_search_seconds" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_BUNDLE_FALLBACK_SEARCH_SECONDS must be whole seconds" >&2; exit 2; }
search_fallback_now() {
  local out commit key source
  [[ "${CMUX_TUI_TREE_CLIENT_FALLBACK:-on}" != off ]] && (( fallback_search_seconds > 0 )) || return 1
  echo "searching the newest published cmux-tui tree within 24 h now ($1)" >&2
  out="$(CMUX_TUI_TREE_PROBE_CACHE="" CMUX_TUI_TREE_CHANNEL_LOOK=1 CMUX_TUI_TREE_TIP_WAIT_SECONDS=0 CMUX_TUI_TREE_SAME_PATHS="" CMUX_TUI_TREE_DISPATCH="" GITHUB_STEP_SUMMARY="" \
    CMUX_TUI_TREE_SEARCH_COMMITS="${CMUX_TUI_TREE_FALLBACK_SEARCH_COMMITS:-300}" \
    bash scripts/ci/timeout.sh "$fallback_search_seconds" bash scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published </dev/null)" || return 1
  commit="$(sed -n 's/^commit=//p' <<<"$out" | head -1)"
  key="$(sed -n 's/^key=//p' <<<"$out" | head -1)"
  source="$(sed -n 's/^source_commit=//p' <<<"$out" | head -1)"
  [[ "$commit" =~ ^[0-9a-f]{40}$ && "$key" =~ ^[0-9a-f]{40}$ && "$key" != "$CMUX_TUI_CLIENT_KEY" ]] || return 1
  fallback_commit="$commit" fallback_key="$key"
  echo "::notice title=cmux-tui client::resolve had no fallback tree; found tree $key of ${source:-?} (published by $commit) now"
}
if [[ "$TREE_PENDING" == true ]]; then
  read -r -a c <<<"$TREE_CANDIDATES"
  fallback_commit="" fallback_key=""
  read -r fallback_commit fallback_key _ <<<"${TREE_FALLBACK:-}" || true
  if ! [[ "$fallback_commit" =~ ^[0-9a-f]{40}$ && "$fallback_key" =~ ^[0-9a-f]{40}$ ]]; then
    fallback_commit="" fallback_key=""
    search_fallback_now "TREE_FALLBACK='${TREE_FALLBACK:-}'" || true
  fi
  if [[ "${CMUX_TUI_TREE_CLIENT_FALLBACK:-on}" != off && "$fallback_commit" =~ ^[0-9a-f]{40}$ && "$fallback_key" =~ ^[0-9a-f]{40}$ ]]; then
    if cmux_tui_commit="$(CMUX_TUI_TREE_CLIENT_WAIT_SECONDS="$fallback_wait" CMUX_TUI_TREE_CLIENT_UNREADABLE_CHECKS="$unreadable_checks" CMUX_TUI_TREE_CLIENT_REBUILD_ENDS="$rebuild_ends" CMUX_TUI_TREE_CLIENT_FAILED_ENDS="$failed_ends" scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"; then
      echo "::notice title=cmux-tui client::exact tree $CMUX_TUI_CLIENT_KEY of the build commit, from ${cmux_tui_commit:0:12}"
    else
      cmux_tui_commit="$fallback_commit" client_key="$fallback_key" tree_used=fallback
      echo "::warning title=cmux-tui client::the build commit's tree $CMUX_TUI_CLIENT_KEY is not published after a ${fallback_wait} s bounded wait (or its publisher is rebuilding a failed macOS leg); bundling the newest published tree $fallback_key (published by $fallback_commit) instead"
    fi
  else
    echo "no fallback tree (TREE_FALLBACK='${TREE_FALLBACK:-}', CMUX_TUI_TREE_CLIENT_FALLBACK=${CMUX_TUI_TREE_CLIENT_FALLBACK:-on}); waiting for tree $CMUX_TUI_CLIENT_KEY" >&2
    if ! cmux_tui_commit="$(scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${c[@]}")"; then
      search_fallback_now "the wait for tree $CMUX_TUI_CLIENT_KEY failed" || exit 1
      cmux_tui_commit="$fallback_commit" client_key="$fallback_key" tree_used=fallback
      echo "::warning title=cmux-tui client::the build commit's tree $CMUX_TUI_CLIENT_KEY will not be published; bundling the newest published tree $fallback_key (published by $fallback_commit) instead"
    fi
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
static_capabilities() {
  ./scripts/cmux-next/check-daemon-capabilities.sh --static-only --binary "$app/Contents/Resources/bin/cmux-tui"
}
# A fallback tree also has to serve every capability this app's tree needs: run 44975559258 bundled
# a tree from before language-packs-v1 (#45928), and the static check below failed the nightly
# instead of taking the tip's tree.
if [[ "$tree_used" == fallback ]] && ! { install_client && static_capabilities; }; then
  # A fallback tree the installer refuses (an older tree without a required capability), or one
  # missing a capability this app needs: the tip's own tree after all, with the bounded wait.
  echo "::warning title=cmux-tui client::the fallback tree $client_key did not install or lacks a needed capability; waiting for the build commit's tree $CMUX_TUI_CLIENT_KEY"
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
static_capabilities
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
