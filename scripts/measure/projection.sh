#!/usr/bin/env bash
# Projection window of a published cmux NEXT build on a fleet Mac with a console session (cmuxterm-hq#7149 row
# L10; scripts/ci/projection_check.py does the driving): this checkout's change shows in a projection window of
# the running NIGHTLY within 5 s of the save, the main windows untouched, one click runs a named test, and a
# theme and shortcut edit reload live.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/projection.sh --ref <sha> [--arg=dmg=nightly|URL | --arg=app=ZIP-URL] \
#     --artifact .build/projection/report.tgz --timeout 1800
# Prints L10-STEP lines and one L10 {json} verdict (exit 3: the NIGHTLY predates projection windows).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/projection"
rm -rf "$out" && mkdir -p "$out"
dmg=nightly app="" extra=()
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    app=https://*) app="${arg#app=}" ;;
    budget_ms=*) extra+=(--budget-ms "${arg#budget_ms=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "L10 host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
if [[ -n "$app" ]]; then
  # A built app (a fleet DEV build's cmux.app.zip), for a commit no NIGHTLY carries yet.
  echo "L10 app $app"
  curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -o "$out/app.zip" "$app" || { echo "L10 download failed"; exit 3; }
  ditto -x -k "$out/app.zip" "$out/app" && rm -f "$out/app.zip"
  bundle="$(find "$out/app" -maxdepth 2 -name '*.app' -type d | head -1)"
  [[ -n "$bundle" ]] || { echo "L10 no app in the zip"; exit 3; }
  python3 scripts/ci/projection_check.py --app "$bundle" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
  tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude app . 2>/dev/null || true
  exit "$rc"
fi
if [[ "$dmg" == nightly ]]; then
  feed="https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
  curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "L10 feed download failed"; exit 3; }
  picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "L10 no nightly build on the feed"; exit 3; }
  echo "$picked" | sed 's/^/L10 pick /'
  dmg="$(sed -n 's/^url=//p' <<<"$picked")"
fi
echo "L10 dmg $dmg"
curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -o "$out/in.dmg" "$dmg" || { echo "L10 download failed"; exit 3; }
python3 scripts/ci/projection_check.py --dmg "$out/in.dmg" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
