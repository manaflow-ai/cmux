#!/usr/bin/env bash
# The Chief's codex for DEV and NIGHTLY app builds: the cmux codex fork
# release (codex, codex-code-mode-host, codex-responses-api-proxy from one
# build; the fork reads the Chief's CODEX_PROMPT_CACHE_KEY), pinned by tag
# and SHA-256, downloaded once with the build host's gh login and cached.
# Prints the directory that holds the three binaries (codex is the fork's
# cmux-codex, renamed). Exit 1 with one line on stderr when it cannot.
#
#   scripts/cmux-next/fetch-chief-codex.sh [--cached-only]
#
# Env: CMUX_CHIEF_CODEX_CACHE overrides the cache root.
set -euo pipefail

TAG="cmux-codex-v0.1.7"
REPO="manaflow-ai/codex"
ASSET="cmux-codex-aarch64-apple-darwin.tar.gz"
SHA256="a1746fa7b896268119b0794df966ca01ec13fa067613572cd67d8a65a5cd2c11"

cached_only=0
[[ "${1:-}" == "--cached-only" ]] && cached_only=1

root="${CMUX_CHIEF_CODEX_CACHE:-$HOME/Library/Caches/cmux-build/chief-codex}"
dir="$root/$TAG-${SHA256:0:12}"
if [[ -x "$dir/codex" && -x "$dir/codex-code-mode-host" && -x "$dir/codex-responses-api-proxy" ]]; then
  echo "$dir"
  exit 0
fi
if [[ "$cached_only" == 1 ]]; then
  echo "chief codex: $TAG is not cached at $dir" >&2
  exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "chief codex: gh is not installed" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-codex.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
if ! gh release download "$TAG" --repo "$REPO" -p "$ASSET" -D "$tmp" >/dev/null 2>&1; then
  echo "chief codex: downloading $TAG from $REPO failed (gh login with access to the private repo?)" >&2
  exit 1
fi
actual="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
  echo "chief codex: $ASSET has SHA-256 $actual, expected $SHA256" >&2
  exit 1
fi
mkdir -p "$tmp/x"
tar -xzf "$tmp/$ASSET" -C "$tmp/x"
mv "$tmp/x/cmux-codex" "$tmp/x/codex"
for b in codex codex-code-mode-host codex-responses-api-proxy; do
  [[ -f "$tmp/x/$b" ]] || { echo "chief codex: $ASSET has no $b" >&2; exit 1; }
  chmod 755 "$tmp/x/$b"
done
mkdir -p "$root"
rm -rf "$dir"
mv "$tmp/x" "$dir"
echo "$dir"
