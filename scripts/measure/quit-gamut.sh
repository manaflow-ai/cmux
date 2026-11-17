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
#   head=SHA     instead of a nightly, an A/B of two commits built as launch-ready.sh's dmg=build builds them (a
#                tagged Release app, ad-hoc signed): SHA is the head, base=SHA the base (default: this checkout).
#                The controller runs this script only at a feat-cmux-next commit, so a PR's head is named here.
#   rounds=N     with head=: gamut runs per side (1 to 10, default 3), interleaved base, head, base, ...
#                Each run's update path reports not run (no older build). Prints QG-AB <side> <path>-<state> {medians}.
#   paths=, states=, many=, long_turns=, video=, fresh_rounds=   passed to the check (--paths, --states, --many,
#                --long-turns, --video, --fresh-rounds); the startup paths: paths=fresh-install,cold-cache,loaded,after-run
#   paths=sparkle-update   the update as a person gets it (CMUX-119): the feed's previous build stages the update with
#                its own Sparkle and pre-warm, installs it on quit, and is reopened; then a second launch of the same
#                build. Sparkle installs the feed's newest, so leave build= unset. Prints GAMUT-RATIO lines
#                (first/second for first window, settled, prior chat front and prior chat live)
#   pair=FROM,TO   with paths=sparkle-update: the update from nightly FROM to nightly TO, either of them gone from the
#                feed (a before/after of a fix older than the feed's two builds). A local appcast offers both, each
#                signed by the <dmg>.signature.json published beside its DMG, and the older build checks it instead of
#                its own feed (updates.test_feed); FROM is installed, its Sparkle stages TO. Leave build= unset
# Prints GAMUT-ROUND lines, one GAMUT {json} and the table; keeps gamut.json, gamut.md, app.log and videos in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/quit-gamut"
rm -rf "$out" && mkdir -p "$out"
build="" base="" headsha="" rounds=3 pair="" extra=()
for arg in "$@"; do
  case "$arg" in
    build=*) build="${arg#build=}" ;;
    base=*) base="${arg#base=}" ;;
    head=*) headsha="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    pair=*) pair="${arg#pair=}" ;;
    paths=*) extra+=(--paths "${arg#paths=}") ;;
    states=*) extra+=(--states "${arg#states=}") ;;
    many=*) extra+=(--many "${arg#many=}") ;;
    long_turns=*) extra+=(--long-turns "${arg#long_turns=}") ;;
    video=*) extra+=(--video "${arg#video=}") ;;
    fresh_rounds=*) extra+=(--fresh-rounds "${arg#fresh_rounds=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^([1-9]|10)$ ]] || { echo "rounds must be 1 to 10" >&2; exit 2; }
echo "GAMUT host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion)"

# ab: build base and head, run the gamut on each, rounds times, interleaved; print each side's medians.
ab() {
  local here want side i rc=0 sides=(base head)
  # nightly-fresh-launch.sh's build_dmg, without running its main (as launch-ready.sh sources it).
  sed '/^main "\$@"; exit \$?$/d' scripts/measure/nightly-fresh-launch.sh >"$out/nightly-fresh-launch-lib.sh"
  source "$out/nightly-fresh-launch-lib.sh"
  declare -F build_dmg >/dev/null || { echo "GAMUT build_dmg missing from nightly-fresh-launch.sh"; exit 3; }
  cp scripts/cmux-next/resolve-acpmux.sh "$out/resolve-acpmux.sh" && export NFL_RESOLVE_ACPMUX="$out/resolve-acpmux.sh"
  here="$(git rev-parse HEAD)"
  [[ -n "$base" ]] || base="$here"
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$headsha" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= take 40-hex commits" >&2; exit 2; }
  for want in "$base" "$headsha"; do
    git cat-file -e "$want^{commit}" 2>/dev/null \
      || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$want" || { echo "GAMUT cannot fetch $want"; exit 3; }
  done
  # Each build checks its commit out and comes back here, so the check below is always this checkout's.
  for side in "${sides[@]}"; do
    want="$base"; [[ "$side" == head ]] && want="$headsha"
    echo "GAMUT build $side $want"
    git -c advice.detachedHead=false checkout --quiet --detach "$want" || exit 3
    build_dmg "$out" "$side" release; rc=$?
    git -c advice.detachedHead=false checkout --quiet --detach "$here" || exit 3
    [[ $rc == 0 ]] || { echo "GAMUT build $side failed (build-$side.log)"; exit "$rc"; }
  done
  # The builds are a commit's own code: no signing, publishing or GitHub credential reaches them (as launch-ready.sh).
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  for ((i = 1; i <= rounds; i++)); do
    for side in "${sides[@]}"; do
      python3 scripts/ci/quit_gamut_check.py --dmg "$out/$side.dmg" --out "$out/run-$side-$i" ${extra[@]+"${extra[@]}"} 2>&1 \
        | tee -a "$out/run.log" | sed "s/^/[$side $i] /"
      [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
    done
  done
  python3 -I - "$out" <<'PY'
import json, statistics, sys
from pathlib import Path
FIELDS = ("first_window_ms", "settled_ms", "prior_chat_front_ms", "prior_chat_live_ms", "warm_switch_ms",
          "live_over_warm_switch", "stream_words_in_2s")
rows = {}
for path in sorted(Path(sys.argv[1]).glob("run-*-*/gamut.json")):
    side = path.parent.name.split("-")[1]
    for r in json.loads(path.read_text())["rounds"]:
        if not r.get("not_run"):
            rows.setdefault((side, f"{r['path']}-{r['state']}"), []).append(r)
for (side, key), done in sorted(rows.items(), key=lambda kv: (kv[0][1], kv[0][0])):
    med = {"n": len(done), "failed": sum(1 for r in done if r.get("failures"))}
    for field in FIELDS:
        vals = [r[field] for r in done if isinstance(r.get(field), (int, float))]
        med[field] = round(statistics.median(vals), 1) if vals else None
    print("QG-AB", side, key, json.dumps(med), flush=True)
PY
  rm -f "$out"/*.dmg
  tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude '*.app' . 2>/dev/null || true
  exit "$rc"
}
[[ -n "$headsha" ]] && ab
[[ -z "$base" ]] || { echo "base= needs head=" >&2; exit 2; }
if [[ -n "$pair" ]]; then
  [[ "$pair" =~ ^([0-9]+),([0-9]+)$ && -z "$build" ]] || { echo "pair= takes FROM,TO nightly builds, without build=" >&2; exit 2; }
  from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
  (( from < to )) || { echo "pair=FROM,TO: FROM must be the older build" >&2; exit 2; }
fi

feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-quit-gamut/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" \
  || { echo "GAMUT feed download failed"; exit 3; }
if [[ -n "$pair" ]]; then
  sigs=()
  for b in "$from" "$to"; do
    url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$b.dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-quit-gamut/1 -o "$out/$b.signature.json" \
      "$url.signature.json" || { echo "GAMUT no signature published for nightly $b"; exit 3; }
    sigs+=(--signature "$b=$out/$b.signature.json")
  done
  python3 scripts/ci/quit_gamut_check.py pair-feed --live "$out/feed.xml" "${sigs[@]}" --out "$out/pair-feed.xml" \
    || { echo "GAMUT the pair feed could not be written"; exit 3; }
  echo "GAMUT pair from=$from to=$to (a local feed)"
  extra+=(--test-feed "$out/pair-feed.xml")
  cp "$out/pair-feed.xml" "$out/feed.xml"
fi
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
