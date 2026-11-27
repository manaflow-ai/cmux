#!/usr/bin/env bash
# Where a published cmux NEXT nightly's fresh-home launch spends its time (goal next-launch-instant, CMUX-571),
# on a fleet Mac with a console session: per round, a fresh copy with a fresh home (the nightly dogfood's
# launch), the same copy with another fresh home, and that home warm (scripts/measure/nightly-fresh-launch.py).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/nightly-fresh-launch.sh --ref <sha> [--arg=dmg=nightly|URL] [--arg=rounds=2] \
#     --artifact .build/nightly-fresh-launch/report.tgz --timeout 1800
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   rounds=N     rounds of the three launches (1 to 5, default 2)
#   arms=extra   also the pre-warm arms and the unified log around each fresh launch (nightly-fresh-launch.py --arms)
#   arms=prewarm also only the pre-warm arms (PREWARM_ARMS)
# Prints NFL-FACT, NFL-LAUNCH, NFL-MARKS and NFL-MEDIAN lines; keeps report.json in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/nightly-fresh-launch"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
dmg=nightly rounds=2 arms=base
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    arms=base|arms=extra|arms=prewarm) arms="${arg#arms=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^[1-5]$ ]] || { echo "rounds= must be 1 to 5" >&2; exit 2; }
echo "NFL host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
if [[ "$dmg" == nightly ]]; then
  dmg="$(curl -fsSL --proto '=https' --retry 3 -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "NFL no nightly DMG in the feed"; exit 3; }
echo "NFL dmg $dmg"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-nightly-fresh-launch/1 -o "$out/in.dmg" "$dmg" || { echo "NFL download failed"; exit 3; }
source scripts/ci/lib/signing-runtime-guard.sh
cmux_signing_runtime_guard || exit 3
GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/measure/nightly-fresh-launch.py" \
  --dmg "$out/in.dmg" --out "$out/run" --rounds "$rounds" --arms "$arms" 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
exit "$rc"
