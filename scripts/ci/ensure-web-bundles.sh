#!/usr/bin/env bash
# Makes the cmux-next web bundles current in this checkout before a fleet Swift run
# (scripts/ci/package-test-lane.sh). The bundles are build output since cx-vn5, and the
# package tests read them: without this step every page-bundle suite fails on a mini.
#
# A source-keyed cache under CMUX_CI_CACHE_DIR (default ~/Library/Caches/cmux-ci) keeps one
# build per `web-bundle-key.py --source` key, as cmux-next.yml's Linux web-bundles job does
# with the Actions cache: a hit installs it (build-web-bundles.sh --from), a miss builds into
# the cache (--out-root) and installs that. Bundles that are already current build nothing.
# The build uses the bun that webviews/package.json pins and node 22.18 or newer; a mini
# without them gets the pinned versions installed into the cache's tools directory.
#
# Test seams: CMUX_WEB_BUNDLES_BUILD (the build script), CMUX_WEB_BUNDLES_KEY (the source key).
set -euo pipefail

BUILD="${CMUX_WEB_BUNDLES_BUILD:-scripts/cmux-next/build-web-bundles.sh}"
CACHE="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}"
NODE_PIN="24.11.1"

if "$BUILD" --verify > /dev/null 2>&1; then
  echo "web bundles are current"
  exit 0
fi

bun_pin="$(python3 -c 'import json; m = (json.load(open("webviews/package.json")).get("devEngines") or {}).get("packageManager") or {}; print(m.get("version", ""))')"
tools="$CACHE/tools"
if [ -z "$bun_pin" ]; then
  echo "error: webviews/package.json pins no bun version" >&2
  exit 1
fi
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ]; then
  if [ ! -x "$tools/bun-$bun_pin/bin/bun" ]; then
    echo "installing bun $bun_pin into $tools/bun-$bun_pin"
    mkdir -p "$tools"
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$tools/bun-$bun_pin" bash -s "bun-v$bun_pin" > /dev/null
  fi
  export PATH="$tools/bun-$bun_pin/bin:$PATH"
fi
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)' 2>/dev/null; then
  node_dir="$tools/node-v$NODE_PIN-darwin-$(uname -m | sed 's/x86_64/x64/')"
  if [ ! -x "$node_dir/bin/node" ]; then
    echo "installing node $NODE_PIN into $node_dir"
    mkdir -p "$tools"
    curl -fsSL "https://nodejs.org/dist/v$NODE_PIN/$(basename "$node_dir").tar.gz" | tar -xz -C "$tools"
  fi
  export PATH="$node_dir/bin:$PATH"
fi

key="${CMUX_WEB_BUNDLES_KEY:-$(python3 scripts/cmux-next/web-bundle-key.py . --source)}"
entry="$CACHE/web-bundles/$key"
if [ ! -d "$entry" ]; then
  echo "building the web bundles for source key ${key:0:12}"
  rm -rf "$entry.tmp"
  mkdir -p "$(dirname "$entry")"
  if ! "$BUILD" --out-root "$entry.tmp"; then
    rm -rf "$entry.tmp"
    echo "error: the cmux-next web bundles did not build" >&2
    exit 1
  fi
  # Another step on this mini may have filled the entry meanwhile; either build serves.
  mv "$entry.tmp" "$entry" 2>/dev/null || rm -rf "$entry.tmp"
else
  echo "web bundles cached for source key ${key:0:12}"
fi
"$BUILD" --from "$entry"
