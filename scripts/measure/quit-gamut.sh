#!/usr/bin/env bash
# Quit gamut of a published cmux NEXT nightly on a fleet Mac with a console session (CMUX-630;
# scripts/ci/quit_gamut_check.py does the driving): each quit path (the Dock's quit Apple event, Cmd-Q, the scripted
# quit, an update relaunch, SIGKILL, SIGTERM) crossed with what the agents are doing (idle, mid-turn, a queued
# message, a running tool, a long chat, 30+ workspaces); per round, does in-flight work survive, and the ms from
# the reopened process's start to its first window and to a settled UI.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/quit-gamut.sh --ref <sha> [--arg=paths=dock,kill] [--arg=states=midturn,tool] \
#     [--arg=build=N] [--arg=video=midturn,tool] --artifact .build/quit-gamut/report.tgz --timeout 3600
#   build=N      the nightly build to measure (default: the newest the NIGHTLY feed offers); the update rounds
#                start on the feed's build before it
#   paths=, states=, many=, long_turns=, video=   passed to the check (--paths, --states, --many, --long-turns, --video)
#   paths=sparkle-update   the update as a person gets it (CMUX-119): the feed's previous build stages the update with
#                its own Sparkle and pre-warm, installs it on quit, and is reopened; then a second launch of the same
#                build. Sparkle installs the feed's newest, so leave build= unset. Prints GAMUT-RATIO lines
#                (first/second for first window, settled, prior chat front and prior chat live)
# Prints GAMUT-ROUND lines, one GAMUT {json} and the table; keeps gamut.json, gamut.md, app.log and videos in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/quit-gamut"
rm -rf "$out" && mkdir -p "$out"
build="" extra=()
for arg in "$@"; do
  case "$arg" in
    build=*) build="${arg#build=}" ;;
    paths=*) extra+=(--paths "${arg#paths=}") ;;
    states=*) extra+=(--states "${arg#states=}") ;;
    many=*) extra+=(--many "${arg#many=}") ;;
    long_turns=*) extra+=(--long-turns "${arg#long_turns=}") ;;
    video=*) extra+=(--video "${arg#video=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "GAMUT host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion)"
feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-quit-gamut/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" \
  || { echo "GAMUT feed download failed"; exit 3; }
picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml" ${build:+--build "$build"})" \
  || { echo "GAMUT no nightly build on the feed"; exit 3; }
echo "$picked" | sed 's/^/GAMUT pick /'
newest="$(sed -n 's/^build=//p' <<<"$picked")"
dmg="$(sed -n 's/^url=//p' <<<"$picked")"
# The update rounds' older build: the newest Nightly-offered item below the measured one.
older="$(python3 -c '
import re, sys
sys.path.insert(0, "scripts/ci")
import nightly_next_launch_smoke as n
text = open(sys.argv[1]).read()
below = [(int(v.group(1)), e.group(1)) for i in n.ITEM.findall(text)
         for v, e in [(n.VERSION.search(i), n.ENCLOSURE.search(i))] if v and e and n.nightly_offered(i) and int(v.group(1)) < int(sys.argv[2])]
print(max(below)[1] if below else "")' "$out/feed.xml" "$newest")"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-quit-gamut/1 -o "$out/in.dmg" "$dmg" || { echo "GAMUT download failed"; exit 3; }
if [[ -n "$older" ]]; then
  echo "GAMUT update-from $older"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-quit-gamut/1 -o "$out/older.dmg" "$older" \
    || { echo "GAMUT the older nightly's download failed: the update rounds cannot run"; exit 3; }
  extra+=(--update-dmg "$out/older.dmg")
else
  echo "GAMUT no older nightly on the feed: the update rounds report not run"
fi
python3 scripts/ci/quit_gamut_check.py --dmg "$out/in.dmg" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg" "$out/older.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
