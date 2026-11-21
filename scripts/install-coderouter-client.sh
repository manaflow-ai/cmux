#!/usr/bin/env bash
# Install the exact official CodeRouter CLI pinned in Resources/coderouter-cli.json
# at Contents/Resources/bin/coderouter, where the Cloud sidebar and `cmux cr`
# look first.
#
#   scripts/install-coderouter-client.sh <app-path>              # this Mac's architecture (dev reloads)
#   scripts/install-coderouter-client.sh <app-path> --universal  # arm64 + x86_64 (release, nightly)
#
# Every download is checked against the manifest's SHA-256 before use. Run
# before signing; the bundle signing pass signs Resources/bin helpers.
set -euo pipefail
app="${1:?app bundle is required}"
mode="${2:-}"
[[ -z "$mode" || "$mode" == --universal ]] || { echo "usage: $0 <app-path> [--universal]" >&2; exit 64; }
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/Resources/coderouter-cli.json"
cache="${CMUX_CODEROUTER_CACHE:-$HOME/Library/Caches/cmux/coderouter}"
mkdir -p "$cache" "$app/Contents/Resources/bin"

field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$manifest" "$1" "$2"
}

# Prints the cached path of one verified manifest artifact. Callers run it in
# a command substitution, where bash ignores `set -e`, so every check returns.
fetch() {
  local target="$1" url digest binary temporary
  url="$(field "$target" url)" || return 1
  digest="$(field "$target" sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "CodeRouter manifest digest for $target is malformed" >&2; return 1; }
  [[ "$url" == https://github.com/manaflow-ai/coderouter-releases/releases/download/* ]] \
    || { echo "CodeRouter manifest URL for $target is not an official release" >&2; return 1; }
  binary="$cache/$digest"
  if [[ ! -f "$binary" || "$(shasum -a 256 "$binary" | awk '{print $1}')" != "$digest" ]]; then
    temporary="$(mktemp "$cache/.download.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$temporary"; then
      rm -f "$temporary"
      echo "CodeRouter download failed: $url" >&2
      return 1
    fi
    if [[ "$(shasum -a 256 "$temporary" | awk '{print $1}')" != "$digest" ]]; then
      rm -f "$temporary"
      echo "CodeRouter checksum mismatch for $target" >&2
      return 1
    fi
    chmod 755 "$temporary" && mv "$temporary" "$binary" || return 1
  fi
  printf '%s\n' "$binary"
}

destination="$app/Contents/Resources/bin/coderouter"
if [[ "$mode" == --universal ]]; then
  arm64="$(fetch darwin-arm64)" || exit 1
  x64="$(fetch darwin-x64)" || exit 1
  staged="$(mktemp "$cache/.universal.XXXXXX")"
  trap 'rm -f "$staged"' EXIT
  lipo -create "$arm64" "$x64" -output "$staged"
  archs="$(lipo -archs "$staged")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "CodeRouter universal binary has '$archs'" >&2; exit 1; }
  install -m 755 "$staged" "$destination"
else
  case "$(uname -m)" in
    arm64) target=darwin-arm64 ;;
    x86_64) target=darwin-x64 ;;
    *) echo "No CodeRouter artifact for $(uname -m); this build will use an installed CLI."; exit 0 ;;
  esac
  binary="$(fetch "$target")" || exit 1
  install -m 755 "$binary" "$destination"
fi
cp "$manifest" "$app/Contents/Resources/coderouter-cli.json"
expected="coderouter $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")"
actual="$("$destination" --version)"
[[ "$actual" == "$expected" ]] || { echo "Bundled CodeRouter reports '$actual', expected '$expected'" >&2; exit 1; }
echo "$actual"
