#!/usr/bin/env bash
# Model-check FeedHandoff.tla (plans/cmux-next/feed.md section 5) with the
# pinned tla2tools.jar of run-tlc.sh. FeedHandoff.cfg must pass; the
# NoFreeze mutant must fail NoLostAnswer and the Unfreeze mutant SingleWriter.
# Needs Java 11+. TLC_WORKERS overrides 2.
set -euo pipefail
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
CACHE_DIR="${CMUX_TLA_CACHE:-$HOME/.cache/cmux-tla}"
JAR="$CACHE_DIR/tla2tools-$TLA_VERSION.jar"
HERE="$(cd "$(dirname "$0")" && pwd)"
java -version >/dev/null 2>&1 || { echo "error: java not found; TLC was not run." >&2; exit 2; }
mkdir -p "$CACHE_DIR"
if [ ! -f "$JAR" ] || ! echo "$TLA_SHA256  $JAR" | shasum -a 256 -c - >/dev/null 2>&1; then
  tmp="$JAR.tmp.$$"
  curl -fsSL -o "$tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
  echo "$TLA_SHA256  $tmp" | shasum -a 256 -c - >/dev/null || { rm -f "$tmp"; echo "error: tla2tools.jar sha256 mismatch" >&2; exit 3; }
  mv "$tmp" "$JAR"
fi
run() { # $1 cfg; prints the result line
  local meta; meta="$(mktemp -d "${TMPDIR:-/tmp}/tlc-feed.XXXXXX")"
  (cd "$HERE" && java -XX:+UseParallelGC -Xmx1g -cp "$JAR" tlc2.TLC -workers "${TLC_WORKERS:-2}" -deadlock -metadir "$meta" -config "$1" FeedHandoff.tla) 2>&1 \
    | grep -E "No error has been found|is violated" | head -1
  rm -rf "$meta"
}
fail=0
r="$(run FeedHandoff.cfg)"; echo "fixed: $r"; [[ "$r" == *"No error"* ]] || fail=1
r="$(run FeedHandoff_nofreeze.cfg)"; echo "nofreeze: $r"; [[ "$r" == *"NoLostAnswer is violated"* ]] || fail=1
r="$(run FeedHandoff_unfreeze.cfg)"; echo "unfreeze: $r"; [[ "$r" == *"SingleWriter is violated"* ]] || fail=1
exit $fail
