#!/usr/bin/env bash
# A Release reload is universal (ONLY_ACTIVE_ARCH = NO), and the Bundle acpmux and
# Bundle optchat-chief phases require every app architecture in their binaries.
# build-acpmux.sh and build-optchat-chief.sh default to the host, so a fleet
# --release build of 0fb1b4b7867 (job f03724be4852) failed with "acpmux has
# architectures arm64, but the app needs arm64 x86_64". reload.sh must ask both
# for arm64 and x86_64 on Release, before it builds them, and leave Debug and an
# explicit choice alone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RELOAD="$ROOT/scripts/reload.sh"

block=$(awk '/^# Release reloads build the helper binaries universal/ {on=1} on {print} on && /^fi$/ {exit}' "$RELOAD")
[[ -n "$block" ]] || { echo "FAIL: reload.sh has no Release helper-architecture block"; exit 1; }

block_line=$(grep -n '^# Release reloads build the helper binaries universal' "$RELOAD" | cut -d: -f1)
for helper in build-acpmux.sh build-optchat-chief.sh; do
  first=$(grep -n "scripts/cmux-next/$helper\"\$" "$RELOAD" | head -n 1 | cut -d: -f1)
  first=${first:-$(grep -n "scripts/cmux-next/$helper" "$RELOAD" | head -n 1 | cut -d: -f1)}
  (( block_line < first )) || { echo "FAIL: the Release block comes after reload.sh first runs $helper"; exit 1; }
done

archs() { # configuration [preset acpmux] [preset chief] -> "acpmux|chief"
  env -i PATH=/usr/bin:/bin BUILD_CONFIGURATION="$1" \
    ${2:+CMUX_NEXT_ACPMUX_ARCHS="$2"} ${3:+CMUX_NEXT_OPTCHAT_CHIEF_ARCHS="$3"} \
    bash -c "$block"$'\n''printf "%s|%s" "${CMUX_NEXT_ACPMUX_ARCHS:-}" "${CMUX_NEXT_OPTCHAT_CHIEF_ARCHS:-}"'
}
expect() { [[ "$2" == "$3" ]] || { echo "FAIL: $1: got '$2', want '$3'"; exit 1; }; }

expect "Release" "$(archs Release)" "arm64 x86_64|arm64 x86_64"
expect "Debug" "$(archs Debug)" "|"
expect "an explicit choice" "$(archs Release arm64 x86_64)" "arm64|x86_64"
echo "release-helper-archs.test.sh: ok"
