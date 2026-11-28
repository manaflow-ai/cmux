#!/usr/bin/env bash
# publish-nightly-identity-legacy publishes only the DMG that
# verify-nightly-identity-legacy launch-smoked (cx-vws1x). This runs the
# check the publish job runs (scripts/ci/nightly-next-legacy-tested-digest.sh)
# on real files: the tested DMG passes; a DMG whose sha256 differs from the
# verified one, a missing tested digest, a tested digest that is not the signed
# one and a missing DMG are refused.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/ci/nightly-next-legacy-tested-digest.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dmg="$tmp/cmux-nightly-next-macos-nightlyid-arm64-3851000000001.dmg"
printf 'the stapled DMG the verify job launched\n' > "$dmg"
tested="$(shasum -a 256 "$dmg" | awk '{print $1}')"
other="$(printf 'another DMG\n' | shasum -a 256 | awk '{print $1}')"

expect() {  # <exit code> <stderr substring> <message> <args...>
  local code="$1" needle="$2" message="$3"; shift 3
  local actual=0
  "$CHECK" "$@" >"$tmp/out" 2>"$tmp/err" || actual=$?
  if [ "$actual" != "$code" ] || ! grep -Fq -- "$needle" "$tmp/out" "$tmp/err"; then
    echo "FAIL: $message (exit $actual, expected $code)"
    cat "$tmp/out" "$tmp/err"
    exit 1
  fi
}

expect 0 "is the tested DMG" "the tested DMG must be published" "$dmg" "$tested" "$tested"
# The DMG on disk was replaced after the smoke: its bytes are not the tested ones.
printf 'a DMG nobody launched\n' > "$tmp/replaced.dmg"
expect 1 "not the tested $tested" "a DMG whose sha256 differs from the verified one must be refused" "$tmp/replaced.dmg" "$tested" "$tested"
expect 1 "no tested sha256" "no tested digest (the verify job failed or was skipped) must be refused" "$dmg" "" "$tested"
expect 1 "but the signing job signed" "a tested digest that is not the signed one must be refused" "$dmg" "$other" "$tested"
expect 1 "no signed sha256" "a missing signed digest must be refused" "$dmg" "$tested" ""
expect 1 "no DMG at" "a missing DMG must be refused" "$tmp/missing.dmg" "$tested" "$tested"
expect 2 "usage:" "a wrong argument count is a usage error" "$dmg" "$tested"
echo "PASS: publish-nightly-identity-legacy publishes only the tested DMG"
