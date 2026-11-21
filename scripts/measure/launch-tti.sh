#!/usr/bin/env bash
# Launch to first interaction (startup-tti) of a cmux NEXT NIGHTLY on a fleet Mac with a console session: the nightly
# launch-tti leg (cmuxterm-hq next-dogfood.yml) run on demand, so a number comes now and not at the next nightly.
# scripts/ci/launch_tti_check.py does the driving: 120 workspaces, cold and warm relaunches, process start to a typed
# key taken (the terminal's echo; the chat composer has no input mark yet).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/launch-tti.sh --ref <landed sha> [--arg=dmg=nightly|URL] [--arg=input=auto|posted|in_app] \
#     [--arg=plan=warm:terminal,warm:terminal] [--arg=workspaces=120] --artifact .build/launch-tti/report.tgz --timeout 2400
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   input=       who types (the check's --input): auto posts keys when this process holds the PostEvent grant and
#                otherwise has the app type its own first-frame key (CMUX_NEXT_LAUNCH_TYPE_PROBE=1)
# Prints TTI-HOST (the Mac, its load), TTI-ROUND per round and one TTI {json}; keeps tti.json and run.log in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/launch-tti"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
dmg=nightly extra=()
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    input=auto|input=posted|input=in_app) extra+=(--input "${arg#input=}") ;;
    plan=*) extra+=(--plan "${arg#plan=}") ;;
    workspaces=*) extra+=(--workspaces "${arg#workspaces=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$dmg" == nightly ]]; then
  feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-tti/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "TTI feed download failed"; exit 3; }
  picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "TTI no nightly build on the feed"; exit 3; }
  echo "$picked" | sed 's/^/TTI pick /'
  dmg="$(sed -n 's/^url=//p' <<<"$picked")"
fi
echo "TTI dmg $dmg"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-tti/1 -o "$out/in.dmg" "$dmg" || { echo "TTI download failed"; exit 3; }
python3 -I -c 'import json, os, shutil, socket; print("TTI-HOST " + json.dumps({"name": socket.gethostname().split(".")[0], "cpus": os.cpu_count(), "load_at_launch": round(os.getloadavg()[0], 2), "free_disk_gb": round(shutil.disk_usage(os.path.expanduser("~")).free / 1e9, 1)}))' | tee "$out/run.log"
scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/ci/launch_tti_check.py" --dmg "$out/in.dmg" --out "$out" \
  ${extra[@]+"${extra[@]}"} 2>&1 | tee -a "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
