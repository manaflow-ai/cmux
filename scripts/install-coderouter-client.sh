#!/usr/bin/env bash
# Install the exact official Rust CodeRouter core used by this development build.
set -euo pipefail
app="${1:?app bundle is required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/Resources/coderouter-cli.json"
target="darwin-$(uname -m)"
[[ "$target" != darwin-arm64 ]] || target=darwin-arm64
if [[ "$target" != darwin-arm64 ]]; then
  echo 'CodeRouter development artifact is arm64; this build will use the installed CLI.'
  exit 0
fi
url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["url"])' "$manifest" "$target")"
digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["sha256"])' "$manifest" "$target")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$url" == https://github.com/manaflow-ai/coderouter-releases/releases/download/* ]]
cache="${CMUX_CODEROUTER_CACHE:-$HOME/Library/Caches/cmux/coderouter}"
mkdir -p "$cache" "$app/Contents/Resources/bin"
binary="$cache/$digest"
valid() { [[ -f "$1" && "$(shasum -a 256 "$1" | awk '{print $1}')" == "$digest" ]]; }
if ! valid "$binary"; then
  temporary="$(mktemp "$cache/.download.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$temporary"
  valid "$temporary" || { echo 'CodeRouter checksum mismatch' >&2; exit 1; }
  chmod 755 "$temporary"
  mv "$temporary" "$binary"
fi
install -m 755 "$binary" "$app/Contents/Resources/bin/coderouter"
cp "$manifest" "$app/Contents/Resources/coderouter-cli.json"
"$app/Contents/Resources/bin/coderouter" --version
