#!/usr/bin/env bash
# Stills and short clips of every live wallpaper, made off any Mac on a Linux box with no GPU
# (Chromium on SwiftShader), for review. Gets what it needs where it is missing: naga-cli at the
# crate's pin (build.mjs), playwright-core and its Chromium, and ffmpeg from PyPI's
# imageio-ffmpeg. Run it from the repository root, for example through the fleet:
#
#   cmux-ci test --setup rust --not-tests --timeout 10800 --artifact OUT -- design/live-wallpapers-gallery/record.sh
#
# Writes to $FAST_CHECKS_OUT (or ./.build/wallpaper-record): gallery/<id>-stills.png (every
# variant, dark and light, from shoot.mjs) and <id>/<theme>/{still.png,clip.mp4} (record.mjs).
# RECORD_IDS=a,b limits it; RECORD_SECONDS and RECORD_FPS set the clip (default 6 s at 20).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${FAST_CHECKS_OUT:-$PWD/.build/wallpaper-record}"
mkdir -p "$out"
tools="${RUNNER_TEMP:-/tmp}/wallpaper-record-tools"
mkdir -p "$tools"
export PATH="$tools/bin:$HOME/.cargo/bin:$PATH"

naga_pin="$(sed -n 's/^naga = { version = "\([0-9.]*\)".*/\1/p' "$here/../../cmux-tui/crates/cmux-wallpaper/Cargo.toml" | head -n 1)"
if ! command -v naga >/dev/null || ! naga --version 2>/dev/null | grep -q "$naga_pin"; then
  cargo install --locked --quiet --root "$tools" naga-cli --version "$naga_pin"
fi
node --version >/dev/null
if [ ! -f "$tools/node_modules/playwright-core/index.js" ]; then
  npm install --silent --prefix "$tools" playwright-core@1.62.1 >/dev/null
fi
export PLAYWRIGHT_CORE="$tools/node_modules/playwright-core/index.js"
node "$tools/node_modules/playwright-core/cli.js" install --with-deps chromium-headless-shell >/dev/null 2>&1 \
  || node "$tools/node_modules/playwright-core/cli.js" install chromium-headless-shell >/dev/null
ffmpeg_bin="$(command -v ffmpeg || true)"
if [ -z "$ffmpeg_bin" ]; then
  python3 -m venv "$tools/venv" >/dev/null
  "$tools/venv/bin/pip" install --quiet imageio-ffmpeg
  ffmpeg_bin="$("$tools/venv/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
fi

NAGA=naga node "$here/build.mjs"
node "$here/shoot.mjs" "$out/gallery" >/dev/null
node "$here/record.mjs" "$out" "${RECORD_IDS:-}" "${RECORD_SECONDS:-6}" "${RECORD_FPS:-20}"

# Each clip as H.264 (yuv420p plays everywhere), then its frames go.
for frames in "$out"/*/*/frames; do
  [ -d "$frames" ] || continue
  "$ffmpeg_bin" -loglevel error -y -framerate "${RECORD_FPS:-20}" -i "$frames/%06d.png" \
    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$(dirname "$frames")/clip.mp4"
  rm -rf "$frames"
done
find "$out" -name clip.mp4 | sort
