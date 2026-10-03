#!/usr/bin/env bash
# Cross check the session host's corpus snapshots (ghostty-vt, from the
# ghostty-next submodule) against GhosttyNextKit's surface encoder on macOS.
# Run on a Mac build host from the cmux repo root:
#   schemas/terminal-corpus/crosscheck/run.sh <release-tag> <zip-sha256> <out-dir>
set -euo pipefail
tag="$1"; sha="$2"; out="$3"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
here="$root/schemas/terminal-corpus/crosscheck"
mkdir -p "$out/host" "$out/phone"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Host snapshots: the corpus test writes READY and COMPLETE per case.
git -C "$root" submodule update --init --depth 1 ghostty ghostty-next
(cd "$root/cmux-tui" && CMUX_TERMINAL_CORPUS_OUT="$out/host" \
  cargo test -p ghostty-vt --test terminal_corpus -- --nocapture)

# 2. GhosttyNextKit release, checked against its pinned sha256.
curl -fsSL -o "$work/kit.zip" \
  "https://github.com/manaflow-ai/ghostty-next/releases/download/$tag/GhosttyNextKit.xcframework.zip"
echo "$sha  $work/kit.zip" | shasum -a 256 -c -
(cd "$work" && unzip -q kit.zip)
x="$work/GhosttyNextKit.xcframework"

# 3. The surface side, configured like the session host's terminal:
#    - scrollback budget 50 MB (cmux-tui DEFAULT_SCROLLBACK_LIMIT_BYTES);
#    - the default colors the frontend sends the host (Ghostty's theme);
#    - no cursor-blink default (libghostty-vt's default cursor policy);
#    - legacy grapheme width: the host terminal leaves mode 2027 off.
cat > "$work/ghostty.conf" <<'CONF'
scrollback-limit = 50000000
foreground = ffffff
background = 282c34
cursor-style-blink = false
grapheme-width-method = legacy
CONF
xcrun --sdk macosx swiftc -O -swift-version 6 -target arm64-apple-macos13 \
  -I "$x/macos-arm64/Headers" "$here/main.swift" "$x/macos-arm64/libghostty-internal.a" \
  -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework CoreVideo \
  -framework QuartzCore -framework IOSurface -framework Metal -framework Foundation \
  -framework AppKit -framework Carbon -lc++ -o "$work/crosscheck"
"$work/crosscheck" "$root/schemas/terminal-corpus" "$out/host" "$out/phone" "$work/ghostty.conf"
