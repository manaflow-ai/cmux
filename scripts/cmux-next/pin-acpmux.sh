#!/usr/bin/env bash
# Pin or fetch the hosted macOS arm64 acpmux the cmux-next app bundles.
#
# The pin (scripts/cmux-next/acpmux.pin) names one manaflow-ai/acpmux commit,
# the public commit-addressed binary its artifacts workflow published
# (url=https://files.cmux.com/acpmux/<commit>/acpmux-aarch64-apple-darwin),
# and the binary's sha256. bundle-acpmux.sh bundles
# .build/acpmux/<commit>/acpmux when its sha256 matches. `fetch` needs no
# GitHub credentials (the acpmux repo is private; the binary is public).
#
# Usage: pin-acpmux.sh pin --commit <sha> | fetch | show
set -euo pipefail
BASE="${CMUX_ACPMUX_PIN_BASE:-https://files.cmux.com/acpmux}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
pin_file="$script_dir/acpmux.pin"
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$pin_file"; }

case "${1:-}" in
  pin)
    [[ "${2:-}" == --commit && -n "${3:-}" ]] || { echo "usage: pin-acpmux.sh pin --commit <sha>" >&2; exit 2; }
    commit="$3"
    tmp="$(mktemp)"
    curl -fsSL --proto '=https' "$BASE/$commit/manifest.json" -o "$tmp"
    sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"]["acpmux-aarch64-apple-darwin"])' "$tmp")"
    rm -f "$tmp"
    printf '# Hosted acpmux the cmux-next app bundles. Refresh: scripts/cmux-next/pin-acpmux.sh pin --commit <sha>\ncommit=%s\nurl=%s/%s/acpmux-aarch64-apple-darwin\nsha256=%s\n' "$commit" "$BASE" "$commit" "$sha" > "$pin_file"
    "$0" fetch
    ;;
  fetch)
    [[ -f "$pin_file" ]] || { echo "no $pin_file; nothing to fetch"; exit 0; }
    commit="$(field commit)"; url="$(field url)"; want="$(field sha256)"
    dest="$repo_root/.build/acpmux/$commit/acpmux"
    if [[ -f "$dest" && "$(sha256_of "$dest")" == "$want" ]]; then exit 0; fi
    mkdir -p "$(dirname "$dest")"
    tmp="$dest.download"
    curl -fsSL --proto '=https' "$url" -o "$tmp"
    got="$(sha256_of "$tmp")"
    [[ "$got" == "$want" ]] || { rm -f "$tmp"; echo "error: $url has sha256 $got, pin says $want" >&2; exit 1; }
    chmod 755 "$tmp"
    mv "$tmp" "$dest"
    echo "fetched acpmux $commit"
    ;;
  show)
    cat "$pin_file" 2>/dev/null || echo "no pin"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
