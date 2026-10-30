#!/usr/bin/env bash
# Refuse to publish a cmux NIGHTLY-identity DMG that is not the one the
# secret-free verify job launch-smoked (cx-vws1x).
#
# Usage: nightly-next-legacy-tested-digest.sh <dmg> <tested-sha256> <signed-sha256>
# <tested-sha256> is verify-nightly-identity-legacy's tested digest,
# <signed-sha256> the digest sign-nightly-identity-legacy recorded. Both must be
# 64 hex digits, equal, and equal to the DMG's own sha256. Exit 0 when they
# are; exit 1 (and publish nothing) otherwise.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo "usage: $0 <dmg> <tested-sha256> <signed-sha256>" >&2
  exit 2
fi
dmg="$1" tested="$2" signed="$3"
[[ "$tested" =~ ^[0-9a-f]{64}$ ]] || { echo "refused: no tested sha256 from the verify job ('$tested')" >&2; exit 1; }
[[ "$signed" =~ ^[0-9a-f]{64}$ ]] || { echo "refused: no signed sha256 from the signing job ('$signed')" >&2; exit 1; }
[ "$tested" = "$signed" ] || { echo "refused: the verify job tested $tested, but the signing job signed $signed" >&2; exit 1; }
[ -f "$dmg" ] || { echo "refused: no DMG at $dmg" >&2; exit 1; }
actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[ "$actual" = "$tested" ] || { echo "refused: $(basename "$dmg") has sha256 $actual, not the tested $tested" >&2; exit 1; }
echo "publishing $(basename "$dmg"): sha256 $actual is the tested DMG"
