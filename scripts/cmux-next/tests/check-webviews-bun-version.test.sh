#!/usr/bin/env bash
# check-webviews-bun-version.sh is a minimum, not an exact match (Leo, 2026-10-24: "surely we
# can just update bun on everything?"): a newer patch or minor of the pinned major passes, an
# older bun, a prerelease of the pin or another major fails with the install command.
# Fake bun binaries and a fake webviews/package.json; no network, no real bun.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/scripts" "$TMP/webviews" "$TMP/bin"
cp "$ROOT/scripts/check-webviews-bun-version.sh" "$TMP/scripts/"
pin() { printf '{\n  "devEngines": {\n    "packageManager": {\n      "name": "%s",\n      "version": "%s",\n      "onFail": "error"\n    }\n  }\n}\n' "${2:-bun}" "$1" > "$TMP/webviews/package.json"; }
fake() { printf '#!/bin/sh\necho %s\n' "$1" > "$TMP/bin/bun"; chmod +x "$TMP/bin/bun"; }
check() { status=0; out=$(PATH="$TMP/bin:$PATH" sh "$TMP/scripts/check-webviews-bun-version.sh" "$@" 2>&1) || status=$?; }

pin 1.4.4
for have in 1.4.4 1.4.5 1.4.10 1.5.0 1.10.0 1.4.5-canary.1 1.4.4+abc; do
  fake "$have"; check
  [[ "$status" == 0 ]] || fail "bun $have must pass a 1.4.4 pin: $out"
done
for have in 1.4.3 1.3.14 1.3.6 1.4.4-rc.1 2.0.0 0.9.9 garbage; do
  fake "$have"; check
  [[ "$status" != 0 ]] || fail "bun $have must fail a 1.4.4 pin"
  [[ "$out" == *"curl -fsSL https://bun.sh/install | bash -s bun-v1.4.4"* ]] || fail "bun $have must print the install command: $out"
done

# --quiet prints nothing; an explicit binary is checked instead of PATH's.
fake 1.3.6; check --quiet
[[ "$status" != 0 && -z "$out" ]] || fail "--quiet must fail silently: $status $out"
printf '#!/bin/sh\necho 1.4.6\n' > "$TMP/newer"; chmod +x "$TMP/newer"
check --quiet "$TMP/newer"
[[ "$status" == 0 ]] || fail "an explicit newer bun must pass: $out"

# No bun at all still names the pin and the install command.
rm "$TMP/bin/bun"; status=0
out=$(PATH="$TMP/bin:/usr/bin:/bin" sh "$TMP/scripts/check-webviews-bun-version.sh" "$TMP/bin/bun" 2>&1) || status=$?
[[ "$status" != 0 && "$out" == *"bun-v1.4.4"* ]] || fail "a missing bun must print the install command: $out"

# The pin must be bun at an exact version.
fake 1.4.4
pin '^1.4.4'; check; [[ "$status" != 0 ]] || fail "a range pin must fail"
pin 1.4.4 npm; check; [[ "$status" != 0 ]] || fail "a non-bun package manager must fail"

echo "check-webviews-bun-version tests: ok"
