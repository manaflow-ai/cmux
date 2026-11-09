#!/usr/bin/env bash
# Relaunch restore of a published cmux NEXT build on a fleet Mac with a console session (cmuxterm-hq#7149 row L5;
# scripts/ci/relaunch_restore_check.py does the driving): seed workspaces, a terminal process with scrollback and an
# agent chat, Quit and Keep Sessions, relaunch, and time quit to usable with every probe equal.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/relaunch-restore.sh --ref <sha> [--arg=dmg=nightly|URL] [--arg=rounds=3] \
#     --artifact .build/relaunch-restore/report.tgz --timeout 1800
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
# Prints L5-ROUND lines per relaunch and one L5 {json} verdict; keeps l5.json, report.json and app.log in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/relaunch-restore"
rm -rf "$out" && mkdir -p "$out"
dmg=nightly extra=()
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    rounds=*) extra+=(--rounds "${arg#rounds=}") ;;
    budget_ms=*) extra+=(--budget-ms "${arg#budget_ms=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "L5 host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
if [[ "$dmg" == nightly ]]; then
  feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # the one feed since #36287
  curl -fsSL --proto '=https' --retry 3 -A cmux-relaunch-restore/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "L5 feed download failed"; exit 3; }
  picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "L5 no nightly build on the feed"; exit 3; }
  echo "$picked" | sed 's/^/L5 pick /'
  dmg="$(sed -n 's/^url=//p' <<<"$picked")"
fi
echo "L5 dmg $dmg"
curl -fsSL --proto '=https' --retry 3 -A cmux-relaunch-restore/1 -o "$out/in.dmg" "$dmg" || { echo "L5 download failed"; exit 3; }
python3 scripts/ci/relaunch_restore_check.py --dmg "$out/in.dmg" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
