#!/usr/bin/env bash
# Writes <bin>/cmux-tui.version.json: `<bin>/cmux-tui --version --json` of the
# binary just placed (build_commit, build_identity). The app's version handoff
# (DaemonLauncher.bundledBuild) reads this file instead of running the binary:
# the first exec of a binary macOS has not seen yet costs about 800 ms, and on a
# new copy of the app that exec sat before daemon_connected, the first tree and
# the first typed key (handshake to daemon_connected p50 768 ms cold, 322 ms
# warm; launch-tti job 140262416321, 2026-11-27).
#
# write-daemon-capabilities.sh runs it, so every path that places bin/cmux does
# (bundle-cmux-tui.sh, install-cmux-tui-client.sh, write-cmux-tui-version.sh).
# The old file goes first: a binary that cannot answer leaves none, and the app
# runs the binary as before rather than trust another build's stamp.
#
# Usage: write-cmux-tui-build-stamp.sh <bin dir>
set -euo pipefail
bin_dir="${1:?usage: write-cmux-tui-build-stamp.sh <bin dir>}"
out="$bin_dir/cmux-tui.version.json"
rm -f "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-build-stamp.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ -x "$bin_dir/cmux-tui" ]] &&
    "$bin_dir/cmux-tui" --version --json </dev/null >"$work/version.json" 2>/dev/null &&
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and ("build_identity" in d or "build_commit" in d) else 1)' "$work/version.json" 2>/dev/null; then
  cp "$work/version.json" "$out"
  chmod 644 "$out"
  echo "cmux-tui.version.json: $(tr -d '\n' <"$out" | head -c 200)"
else
  echo "warning: cmux-tui.version.json: \`cmux-tui --version --json\` gave no build; the app runs the binary for it"
fi
