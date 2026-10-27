#!/usr/bin/env bash
# Runs TLC on a formal model in this directory with a pinned tla2tools.jar
# (downloaded once, sha256-checked). Usage: plans/cmux-next/formal/tlc.sh [model]
# (default hovercard). Needs Java 11 or later.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
model="${1:-hovercard}"
version="1.7.4"  # the run-tlc.sh pin; v1.8.0 is a rolling prerelease whose jar changes
url="https://github.com/tlaplus/tlaplus/releases/download/v${version}/tla2tools.jar"
sha256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux/tla2tools-${version}.jar"
if [[ ! -f "$cache" ]]; then
  mkdir -p "$(dirname "$cache")"
  curl -fsSL "$url" -o "$cache.part"
  mv "$cache.part" "$cache"
fi
actual="$(shasum -a 256 "$cache" | awk '{print $1}')"
if [[ "$actual" != "$sha256" ]]; then
  echo "tla2tools.jar sha256 mismatch: $actual (want $sha256)" >&2
  rm -f "$cache"
  exit 1
fi
cd "$here"
exec java -XX:+UseParallelGC -cp "$cache" tlc2.TLC -workers auto -deadlock -cleanup "$model.tla" -config "$model.cfg"
