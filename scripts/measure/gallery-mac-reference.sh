#!/usr/bin/env bash
# Fleet entry for the webview gallery's Mac reference renders (B7, webviews-linux-parity): builds a
# tagged cmux-next app and the gallery at this checkout, then renders manifest stages in the app's own
# engines, CEF and WKWebView (scripts/cmux-next/gallery-mac-reference.py; no Playwright on a Mac).
# scripts/gallery-matrix/parity.py compares the result with the Linux gallery's render of the same cases.
# Runs alone on a display worker because it launches an app:
#   cmux-ci run --class exclusive --display --label measure --script scripts/measure/gallery-mac-reference.sh \
#     --ref <sha> --artifact artifacts/gallery-mac-reference.tgz [--arg=--entries --arg=ID,ID]
# Arguments go to webviews/scripts/gallery/manifest.ts (default: component frame, dark and light, at most 80 cases).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="galref"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "gallery-mac-reference: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
manifest_args=("$@")
[ "${#manifest_args[@]}" -gt 0 ] || manifest_args=(--frame component --limit 80)
(
  cd webviews
  bun install --frozen-lockfile
  CMUX_STRINGS_BEST_EFFORT=1 CMUX_GALLERY_OUT_DIR="$out/gallery" bun run gallery:build
  bun scripts/gallery/manifest.ts "${manifest_args[@]}" --out "$out/manifest.json"
)
mkdir -p artifacts "$out/render"
cp "$out/manifest.json" "$out/render/manifest.json"
# Keep the Mac reference tied to the same content-addressed input family as Linux gallery renders.
# The engine is a variant and the Mac runtime is recorded separately in each result row.
if [ -n "${CMUX_SHOTDIFF:-}" ] && [ -x "$CMUX_SHOTDIFF" ]; then
  shotdiff="$CMUX_SHOTDIFF"
else
  cargo build --locked --release -p cmux-shotdiff --bin cmux-shotdiff --manifest-path cmux-tui/Cargo.toml
  shotdiff="$PWD/cmux-tui/target/release/cmux-shotdiff"
fi
chromium_key="$("$shotdiff" key --inputs .github/golden-inputs.json --family desktop-gallery \
  --variant chromium --rev HEAD --repo "$PWD")"
webkit_key="$("$shotdiff" key --inputs .github/golden-inputs.json --family desktop-gallery \
  --variant webkit --rev HEAD --repo "$PWD")"
python3 - "$out/render/input-keys.json" "$chromium_key" "$webkit_key" <<'PY'
import json, sys
dest, chromium, webkit = sys.argv[1:]
json.dump({"schema": "cmux.desktop-input-key/v1", "family": "desktop-gallery", "runtime": "mac-gallery",
           "revision": "HEAD", "variants": {"chromium": json.loads(chromium), "webkit": json.loads(webkit)}},
          open(dest, "w"), indent=2)
PY
status=0
python3 scripts/cmux-next/gallery-mac-reference.py --tag "$tag" --app "$app" --gallery "$out/gallery" \
  --manifest "$out/manifest.json" --out "$out/render" --input-keys "$out/render/input-keys.json" || status=$?
tar -czf artifacts/gallery-mac-reference.tgz -C "$out" render
exit "$status"
