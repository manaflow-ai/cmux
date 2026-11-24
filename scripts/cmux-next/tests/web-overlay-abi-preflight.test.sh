#!/usr/bin/env bash
# web-overlay.sh checks the target app's web ABI before it writes web-dev.json or the overlay: every
# running cmux NEXT build reloads every page on any change to web-dev.json, so a write the app would
# refuse blanks it (Leo, 2026-11-22). A mismatch writes nothing and exits 1 with both ABIs and the
# side-copy hint; a match writes; a write that changes nothing leaves the file (and its mtime) alone.
# Runs on a fake app (CMUX_WEB_OVERLAY_APP) and a temp config folder: never the real web-dev.json.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/cmux-next/web-overlay.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-web-overlay-abi.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "web-overlay-abi-preflight.test: $*"; exit 1; }

app="$tmp/cmux NIGHTLY.app"
mkdir -p "$app/Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages"
echo '{"abi": 7}' >"$app/Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"

export CMUX_WEB_OVERLAY_APP="$app"
export CMUX_NEXT_CONFIG_FILE="$tmp/config/cmux-next.json"
export CMUX_WEB_OVERLAY_DIR="$tmp/overlay"
export CMUX_WEB_SLOT_STATE_DIR="$tmp/state"
web_dev="$tmp/config/web-dev.json"

# An output root of build-web-bundles.sh whose pages need web ABI $2.
bundles() {
  local root="$tmp/$1"
  mkdir -p "$root/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane" \
    "$root/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
  echo '<html></html>' >"$root/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html"
  echo "{\"abi\": $2}" >"$root/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/web-abi.json"
  echo "$root"
}

# A mismatch: ABI 4 bundles into an ABI 7 app write nothing, and say both ABIs and the next step.
old="$(bundles old 4)"
if out="$(bash "$SCRIPT" install "$old" --commit abc 2>&1)"; then fail "an ABI 4 install into an ABI 7 app passed: $out"; fi
grep -q "web ABI 4" <<<"$out" || fail "the refusal does not name the overlay's ABI: $out"
grep -q "web ABI 7" <<<"$out" || fail "the refusal does not name the app's ABI: $out"
grep -q "cmux app try \." <<<"$out" || fail "the refusal does not name the side copy: $out"
[[ ! -e "$web_dev" ]] || fail "a refused install wrote web-dev.json: $(cat "$web_dev")"
[[ ! -e "$tmp/overlay/manifest.json" ]] || fail "a refused install wrote manifest.json"
[[ -z "$(ls -A "$tmp/overlay" 2>/dev/null)" ]] || fail "a refused install wrote into the overlay: $(ls -A "$tmp/overlay")"

# A dev server's tree at another ABI: `server --local` refuses before it starts anything.
tree="$tmp/tree"
mkdir -p "$tree/webviews/src"
echo '{}' >"$tree/webviews/package.json"
echo '{"abi": 4}' >"$tree/webviews/src/web-abi.json"
if out="$(bash "$SCRIPT" server --local --worktree "$tree" --port 1 2>&1)"; then fail "server --local at ABI 4 passed: $out"; fi
grep -q "web ABI 4.*web ABI 7" <<<"$out" || fail "server --local's refusal does not name both ABIs: $out"
[[ ! -e "$web_dev" ]] || fail "a refused server --local wrote web-dev.json: $(cat "$web_dev")"
[[ ! -e "$tmp/state/dev-server.pid" ]] || fail "a refused server --local started a dev server"

# A match writes the overlay and web-dev.json.
new="$(bundles new 7)"
out="$(bash "$SCRIPT" install "$new" --commit def 2>&1)" || fail "an ABI 7 install into an ABI 7 app failed: $out"
[[ -f "$tmp/overlay/manifest.json" ]] || fail "a matching install wrote no manifest.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["enabled"] is True and d["overlay"], d' "$web_dev" \
  || fail "a matching install did not point web-dev.json at the overlay: $(cat "$web_dev")"
grep -q "reloads every page in:" <<<"$out" || fail "a write does not say which running apps reload: $out"

# An unchanged write is no write: the same keys again leave the file and its mtime alone.
touch -t 202001010000 "$web_dev"
stamp() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_ino)' "$web_dev"; }
before="$(stamp)"
out="$(bash "$SCRIPT" install "$new" --commit def 2>&1)" || fail "a second matching install failed: $out"
grep -q "unchanged" <<<"$out" || fail "an unchanged web-dev.json was reported as written: $out"
after="$(stamp)"
[[ "$before" == "$after" ]] || fail "an unchanged write touched or replaced web-dev.json ($before -> $after)"

# A change still writes (`off` turns it off), and the same `off` again is a no-op.
out="$(bash "$SCRIPT" off 2>&1)"
grep -q '"enabled": false' <<<"$out" || fail "off did not write enabled false: $out"
out="$(bash "$SCRIPT" off 2>&1)"
grep -q "unchanged" <<<"$out" || fail "a second off rewrote web-dev.json: $out"

# An app with no web-abi.json, or a source with none, is not checked (the app checks nothing).
rm "$app/Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"
out="$(bash "$SCRIPT" install "$old" --commit abc 2>&1)" || fail "an install into an app with no ABI failed: $out"

echo "web-overlay-abi-preflight.test: ok"
