#!/usr/bin/env bash
# Linux half of the webview gallery's Mac parity check (B7, webviews-linux-parity): builds the gallery at this
# checkout and renders the same manifest as scripts/measure/gallery-mac-reference.sh, in Chromium and WebKit
# through scripts/gallery-matrix/runner.ts, with the UI font pinned the way the gallery CI pins it
# (scripts/ci/pin-browser-test-font.sh). scripts/gallery-matrix/parity.py compares the two artifacts.
#   cmux-ci run --class light --kinds linux --script scripts/measure/gallery-linux-reference.sh \
#     --ref <sha> --artifact artifacts/gallery-linux-reference.tgz [--arg=--entries --arg=ID,ID]
# Arguments go to webviews/scripts/gallery/manifest.ts (default: the Mac script's, component frame, at most 80).
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
out="$(mktemp -d)"
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Chromium's singleton socket path must fit a unix socket's 108 bytes; the font alias stays in this run's own
# fontconfig directory, not the worker's home.
export TMPDIR="$out" XDG_CONFIG_HOME="$out/config"
command -v bun >/dev/null || { curl -fsSL https://bun.sh/install | bash -s bun-v1.4.4 >/dev/null; }
export PATH="$HOME/.bun/bin:$PATH"
manifest_args=("$@")
[ "${#manifest_args[@]}" -gt 0 ] || manifest_args=(--frame component --limit 80)
(
  cd webviews
  bun install --frozen-lockfile
  CMUX_STRINGS_BEST_EFFORT=1 CMUX_GALLERY_OUT_DIR="$out/gallery" bun run gallery:build
  bun scripts/gallery/manifest.ts "${manifest_args[@]}" --out "$out/manifest.json"
)
cd scripts/gallery-matrix
bun install --frozen-lockfile
line="$("$root/scripts/ci/ensure-system-chrome.sh" | grep -m1 '^CMUX_CHROME_HEADLESS_SHELL=' || true)"
[ -z "$line" ] || export "${line?}"
bunx playwright install webkit > /dev/null
"$root/scripts/ci/pin-browser-test-font.sh"
mkdir -p "$root/artifacts" "$out/render"
cp "$out/manifest.json" "$out/render/manifest.json"
status=0
CMUX_BROWSER_TESTS=1 CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest "$out/manifest.json" --gallery-dir "$out/gallery" \
  --output-dir "$out/render" --engines chromium,webkit || status=$?
fc-match -- -apple-system > "$out/render/font.txt" 2>&1 || true
tar -czf "$root/artifacts/gallery-linux-reference.tgz" -C "$out" render
exit "$status"
