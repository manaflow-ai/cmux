#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Prefetch the cmux-tui client while the tree publishes". Moved out of the workflow
# to keep nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The tree was pending in 10 of 15 nightly-next runs (2026-11-03), so "Fetch the resolved cmux-tui tree companions"
# skipped its prefetch and "Bundle the cmux-tui client" waited for the tree and downloaded the client after the
# compile: 45-139 s there against 15-33 s with the prefetch. This starts the same wait (await-tree-client.sh) and
# the same install into CMUX_TUI_CLIENT_COMMIT's cache in the background, beside the compile.
# app-bundle-cmux-tui-client.sh joins it and still resolves the commit and installs itself; the install reuses a
# cached slice only when its sha256 matches the attested manifest, so a prefetch of another commit only downloads.
#   start   start the background wait and install
#   run     (the background command) wait for the tree's client, then install it on a scratch bundle
set -euo pipefail
scratch="$RUNNER_TEMP/cmux-tui-prefetch/cmux.app"
case "${1:-}" in
  start)
    rm -rf "${scratch%/*}"
    mkdir -p "$scratch/Contents"
    GH_TOKEN="${PREFETCH_GH_TOKEN:-}" \
      python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" cmux-tui-client -- \
      bash "$0" run \
      || echo "::warning title=cmux-tui prefetch::could not start; Bundle the cmux-tui client downloads it"
    ;;
  run)
    read -r -a candidates <<<"$TREE_CANDIDATES"
    commit="$(scripts/cmux-next/await-tree-client.sh "$CMUX_TUI_CLIENT_KEY" "${candidates[@]}")"
    exec ./scripts/install-cmux-tui-client.sh "$scratch" \
      --manifest-url "https://files.cmux.com/cmux-tui/${commit}/manifest.json" \
      --expected-commit "$commit" \
      --require-capability wireguard-hub \
      --require-acpmux
    ;;
  *) echo "usage: $0 start | run" >&2; exit 2 ;;
esac
