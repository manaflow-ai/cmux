#!/usr/bin/env bash
# The customize library walk on demand: `cmux customize use pr:N`, `cmux customize use dir:PATH` and
# `cmux customize library off --all`, run against the newest published cmux NEXT NIGHTLY on a fleet Mac,
# with each step's pass or fail and its whole error printed. The cmuxterm-hq onboarding walk
# (customize_library_walk.py, probe customize-library-live-nightly) runs the same flow on a schedule;
# this script lets the lane that merged a fix see it work at once instead of waiting for that row.
# Leo, 2026-11-14: "piecemeal things that we can just hot patch, hot apply to anybody's build";
# 2026-11-15: "what about if someone just wants to do it without a pull request?".
#   cmux-ci run --class exclusive --label measure \
#     --script scripts/measure/customize-library-nightly.sh --ref <sha> [--arg=prs=N,M] \
#     [--arg=dmg=URL] --artifact .build/customize-library-nightly/report.tgz --timeout 1800
#   prs=N,M   merged feat-cmux-next PRs, newest first; the first whose published web layer has the
#             NIGHTLY's web ABI is used (files.cmux.com/cmux-next-web/pr/N/latest.json). Default: the
#             newest merged PRs that changed webviews/, from this checkout's log
#   dmg=URL   the nightly DMG (default: the newest in the NEXT feed)
# The NIGHTLY runs as a side instance (scripts/cmux-next/side-instance.sh: its own bundle id, config
# folder and web-dev.json), so the Mac's own apps and ~/.config are never touched. The dir: source is
# this checkout (at --ref). Prints `CLW step=NAME ok|fail ...` lines and `CLW_RESULT {json}`; the exit
# status is 0 only when every step passed.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/customize-library-nightly"
rm -rf "$out" && mkdir -p "$out"
dmg="" prs=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    prs=*) prs="${arg#prs=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -z "$prs" ]]; then
  # The newest merged PRs that changed webviews/ (only those publish a web layer), from this checkout's log.
  prs="$(git log -40 --format=%s -- webviews/ | grep -oE '\(#[0-9]+\)$' | tr -d '(#)' | paste -sd, -)"
fi
[[ "$prs" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "prs=N[,M...] takes merged PR numbers" >&2; exit 2; }
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "CLW host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg ref $(git rev-parse HEAD 2>/dev/null)"

work="$(mktemp -d "${TMPDIR:-/tmp}/customize-library-nightly.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="clwalk"
mnt=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "CLW download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux library walk" --customize >&2 || exit 3
app="$("$side" path "$name")"
eval "$("$side" env "$name")"
export CMUX_NEXT_CONFIG_FILE CMUX_CUSTOMIZE_DIR CMUX_WEB_OVERLAY_DIR CMUX_WEB_SLOT_STATE_DIR
cli="$app/Contents/Resources/bin/cmux"
web_dev="$(dirname "$CMUX_NEXT_CONFIG_FILE")/web-dev.json"
"$side" launch "$name" >&2 || exit 3

results=()
step() { # step NAME ok|fail DETAIL
  echo "CLW step=$1 $2 ${3:-}"
  results+=("$(python3 -c 'import json,sys; print(json.dumps({"step": sys.argv[1], "outcome": sys.argv[2], "detail": sys.argv[3][-4000:]}))' "$1" "$2" "${3:-}")")
}
run_cli() { # run_cli LOG SECONDS ARGS...: the CLI's output in LOG, its exit status returned
  local log="$1" secs="$2"; shift 2
  local start=$SECONDS
  "$cli" "$@" >"$log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start > secs )); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "timed out after ${secs}s" >>"$log"; return 124; fi
    sleep 1
  done
  wait "$pid"
}
status_json() { "$cli" customize library status --json 2>&1; }

base_bytes=""
[[ -f "$web_dev" ]] && base_bytes="$(cat "$web_dev")"
step base ok "web-dev.json $( [[ -f "$web_dev" ]] && echo present || echo absent )"

abi="$(python3 - "$app" <<'PY'
import json, pathlib, sys
for f in sorted((pathlib.Path(sys.argv[1]) / "Contents" / "Resources").rglob("web-abi.json")):
    try:
        abi = json.loads(f.read_text()).get("abi")
    except (OSError, ValueError, AttributeError):
        continue
    if isinstance(abi, int):
        print(abi)
        break
PY
)"
pr="$(python3 - "$prs" "$abi" <<'PY'
import json, sys, urllib.request
prs, abi = sys.argv[1].split(","), sys.argv[2]
seen = []
for pr in prs[:20]:
    try:
        with urllib.request.urlopen(f"https://files.cmux.com/cmux-next-web/pr/{pr}/latest.json", timeout=20) as r:
            p = json.load(r)
    except Exception as e:  # noqa: BLE001
        seen.append(f"#{pr} none ({type(e).__name__})")
        continue
    if not isinstance(p, dict) or not p.get("key"):
        seen.append(f"#{pr} no layer")
        continue
    if abi and str(p.get("abi")) != abi:
        seen.append(f"#{pr} abi {p.get('abi')}")
        continue
    print(pr)
    sys.exit(0)
print("none: " + ", ".join(seen), file=sys.stderr)
PY
)"
if [[ -z "$pr" ]]; then
  step use-pr fail "no published layer with web ABI ${abi:-unknown} among $prs"
else
  run_cli "$out/use-pr.log" 300 customize use "pr:$pr"; code=$?
  if (( code == 0 )); then step use-pr ok "pr:$pr (abi ${abi:-?}) $(tail -c 400 "$out/use-pr.log")"
  else step use-pr fail "pr:$pr exit $code: $(tail -c 3000 "$out/use-pr.log")"; fi
fi
status_json >"$out/status-after-pr.json"

run_cli "$out/use-dir.log" 1200 customize use "dir:$root"; code=$?
if (( code == 0 )); then step use-dir ok "dir:$root $(tail -c 400 "$out/use-dir.log")"
else
  # The whole error, not a tail cut short: lines naming an error first, then the end of the log.
  errs="$(grep -inE 'error|panic|segmentation|signal|failed|at [A-Za-z_]+ \(' "$out/use-dir.log" | head -40)"
  step use-dir fail "exit $code: $errs ---- tail: $(tail -c 2500 "$out/use-dir.log")"
fi
status_json >"$out/status-after-dir.json"

if [[ -f "$web_dev" ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("overlay") or d.get("enabled") else 1)' "$web_dev" 2>/dev/null; then
  step live ok "web-dev.json: $(head -c 600 "$web_dev")"
else
  step live fail "no layer in web-dev.json ($( [[ -f "$web_dev" ]] && head -c 600 "$web_dev" || echo absent)); status: $(head -c 800 "$out/status-after-dir.json")"
fi

run_cli "$out/off.log" 120 customize library off --all; code=$?
now_bytes=""
[[ -f "$web_dev" ]] && now_bytes="$(cat "$web_dev")"
same="$(python3 -c '
import json, sys
def norm(s):
    if not s.strip(): return None
    try: return json.loads(s)
    except ValueError: return s
print("yes" if norm(sys.argv[1]) == norm(sys.argv[2]) else "no")' "$base_bytes" "$now_bytes")"
if (( code == 0 )) && [[ "$same" == yes ]]; then step off ok "web-dev.json back to base"
else step off fail "exit $code, web-dev.json back to base: $same; $(tail -c 1500 "$out/off.log")"; fi
status_json >"$out/status-after-off.json"

failed=0
printf '%s\n' "${results[@]}" >"$out/steps.jsonl"
grep -q '"outcome": "fail"' "$out/steps.jsonl" && failed=1
echo "CLW_RESULT $(python3 -c 'import json,sys; print(json.dumps({"dmg": sys.argv[1], "pr": sys.argv[2], "abi": sys.argv[3], "steps": [json.loads(l) for l in open(sys.argv[4])]}))' "$dmg" "${pr:-}" "${abi:-}" "$out/steps.jsonl")"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$failed"
