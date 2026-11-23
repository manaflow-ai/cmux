#!/usr/bin/env bash
# Edit to cold launch with no dev build, on a fleet Mac with a console session: a commit's Swift built Release as the
# nightly builds it (scripts/cmux-next/swap-binary.sh), swapped into a side-instance copy of the signed nightly,
# re-sealed, quit and launched cold, and the change seen in the running copy.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/swap-binary-proof.sh \
#     --ref <feat-cmux-next sha> --arg head=<sha> [--arg expect=TEXT] [--arg base=nightly|commit] [--arg nightly=URL] \
#     --artifact .build/swap-binary-proof/report.tgz --timeout 5400
#   head=SHA     the commit to swap in (its diff from the nightly's commit must be one a swap carries)
#   expect=TEXT  a line the head's launch writes to the unified log (its NSLog at launch): the change, seen
#   base=commit  (default) first build the nightly's own commit the same way: the warm build the head's edit then
#                pays for (the edit-to-launchable time), and a fidelity check of that build against the nightly's
#                shipped binary (SB-FIDELITY: size, load commands); base=nightly skips that build
# Prints SB-BUILD, SB-PLACE, SB-SEAL, SB-LAUNCH (each copy launched cold: the request to its control socket answering)
# and SB-PROOF {json}. report.tgz keeps the logs and overlay-head.tgz, the head's overlay (`swap-binary.sh place`
# takes it where a copy runs). The copies are removed at the end; the Mac's own apps are untouched.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/swap-binary-proof"
rm -rf "$out" && mkdir -p "$out"
head="" expect="" base=commit nightly=""
for arg in "$@"; do
  case "$arg" in
    head=*) head="${arg#head=}" ;;
    expect=*) expect="${arg#expect=}" ;;
    base=nightly|base=commit) base="${arg#base=}" ;;
    nightly=https://*) nightly="${arg#nightly=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "head= takes a 40-hex commit" >&2; exit 2; }
tool="$root/scripts/cmux-next/swap-binary.sh" side="$root/scripts/cmux-next/side-instance.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/swap-binary-proof.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
cleanup() {
  [[ -n "${stream_pid:-}" ]] && kill "$stream_pid" 2>/dev/null # the log stream this script started, by its pid
  "$side" remove sb-base >/dev/null 2>&1 || true
  "$side" remove sb-head >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
echo "SB host $(hostname -s) macOS $(sw_vers -productVersion) xcode=\"$(xcodebuild -version 2>/dev/null | tr '\n' ' ')\""

if [[ -z "$nightly" ]]; then
  nightly="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$nightly" || { echo "SB download failed"; exit 3; }
mkdir -p "$work/mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$work/mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$work/mnt" >/dev/null
app="$work/app/cmux NIGHTLY.app"
commit="$(plutil -extract CMUXCommit raw -o - "$app/Contents/Info.plist")"
version="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
echo "SB nightly $nightly version=$version commit=$commit"
"$tool" check "$commit" "$head" || { echo "SB refused: the head's diff is not one a swap carries"; exit 3; }

base_build_s=""
if [[ "$base" == commit ]]; then
  "$tool" build "$commit" "$out/build-base" --like "$app" 2>"$out/build-base.err" | tee "$out/build-base.log" || { tail -30 "$out/build-base.err"; exit 1; }
  base_build_s="$(sed -n 's/.*"build_s": \([0-9]*\).*/\1/p' "$out/build-base/build.json")"
  # The same commit built by this recipe against the binary the nightly shipped (both stripped).
  python3 -I - "$app/Contents/MacOS/cmux" "$out/build-base/app/Contents/MacOS/cmux" <<'PY' | tee "$out/fidelity.txt"
import json, os, subprocess, sys
a, b = sys.argv[1:]
def loads(p):
    return [l.split()[1] for l in subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:] if l.strip()]
def segs(p):
    out = subprocess.run(["size", "-m", p], capture_output=True, text=True).stdout
    return {l.split(":")[0].split()[-1]: int(l.rsplit(":", 1)[1].split()[0]) for l in out.splitlines() if l.startswith("Segment ") and ":" in l}
la, lb = loads(a), loads(b)
print("SB-FIDELITY " + json.dumps({"bytes_nightly": os.path.getsize(a), "bytes_rebuilt": os.path.getsize(b),
    "load_dylibs_equal": la == lb, "only_nightly": [x for x in la if x not in lb], "only_rebuilt": [x for x in lb if x not in la],
    "segments_nightly": segs(a), "segments_rebuilt": segs(b)}))
PY
fi
t_edit=$SECONDS
"$tool" build "$head" "$out/build-head" --like "$app" 2>"$out/build-head.err" | tee "$out/build-head.log" || { tail -30 "$out/build-head.err"; exit 1; }
head_build_s="$(sed -n 's/.*"build_s": \([0-9]*\).*/\1/p' "$out/build-head/build.json")"
t_place=$SECONDS
"$side" make sb-head --from "$app" --label "cmux swap head" --swap "$out/build-head" 2>&1 | tee "$out/make-head.log"
[[ ${PIPESTATUS[0]} == 0 ]] || exit 1
place_seal_s=$((SECONDS - t_place)) edit_to_launchable_s=$((SECONDS - t_edit))
"$side" make sb-base --from "$app" --label "cmux swap base" >"$out/make-base.log" 2>&1 || { cat "$out/make-base.log"; exit 1; }
for name in sb-base sb-head; do
  echo "SB-SIG $name $(codesign -dv "$("$side" path "$name")" 2>&1 | grep -E '^(Signature|CodeDirectory)' | tr '\n' ' ')"
  "$tool" diff "$app" "$("$side" path "$name")" >"$out/diff-$name.txt"
  echo "SB-DIFF $name $(awk '{ n = split($2, p, "/"); k = p[1] "/" p[2] "/" p[3]; c[$1 " " k]++ } END { for (x in c) printf "%s(%d) ", x, c[x] }' "$out/diff-$name.txt")"
done

# launch NAME: cold (nothing of the copy runs), the request to its control socket answering; prints the ms.
launch() {
  local name="$1" sock t0 pid
  sock="$("$side" socket "$name")"
  t0="$(python3 -I -c 'import time; print(int(time.time() * 1000))')"
  "$side" launch "$name" >"$out/launch-$name.log" 2>&1 || { echo "SB-LAUNCH $name failed"; return 1; }
  pid="$(cat "$CMUX_SIDE_ROOT/$name/pid")"
  python3 -I - "$sock" "$t0" "$name" "$pid" <<'PY'
import socket, sys, time
sock, t0, name, pid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
deadline = time.time() + 90
while time.time() < deadline:
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(sock); s.close()
        print(f"SB-LAUNCH {name} pid={pid} socket_ms={int(time.time() * 1000) - t0}", flush=True); sys.exit(0)
    except OSError:
        time.sleep(0.05)
print(f"SB-LAUNCH {name} pid={pid} no socket in 90 s", flush=True); sys.exit(1)
PY
}
seen=""
launch sb-base || true
"$side" stop sb-base >/dev/null 2>&1 || true
# The probe's line is written at main(), but the unified log delivers it seconds to tens of seconds later (the
# persisted store a one-shot `log show` reads, and `log stream` too: cmux_next_pair_e2e.py), so a read taken when the
# socket answers can miss a line that was written. A `log stream` started before the head launches is waited on for
# up to 90 s, then `log show` from the launch is the fallback; both keep their output and errors in the report.
stream_pid="" via=none
# Only event records count: `log stream` and `log show` print a banner ("Filtering the log data using ... CONTAINS
# \"swapped-in-1\"") that holds the probe text. An event line starts with its date; the banner and "Timestamp" do not.
probe_event() { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]' "$1" 2>/dev/null | grep -F -- "$expect" >/dev/null 2>&1; }
if [[ -n "$expect" ]]; then
  esc="${expect//\\/\\\\}"; esc="${esc//\"/\\\"}"
  predicate="eventMessage CONTAINS \"$esc\"" # no process filter: the nightly app is "cmux NIGHTLY", and the probe text is unique
  log stream --style compact --level default --predicate "$predicate" >"$out/log-head-stream.txt" 2>"$out/log-head-stream.err" &
  stream_pid=$!
  /bin/sleep 2 # log stream attaches before the app starts
fi
launch_at="$(date '+%Y-%m-%d %H:%M:%S')"
launch sb-head || true
if [[ -n "$expect" ]]; then
  for _ in $(seq 1 90); do
    if probe_event "$out/log-head-stream.txt"; then seen=1 via=stream; break; fi
    kill -0 "$stream_pid" 2>/dev/null || break # the stream ended (its error is in log-head-stream.err)
    /bin/sleep 1
  done
  kill "$stream_pid" 2>/dev/null || true; wait "$stream_pid" 2>/dev/null || true; stream_pid=""
  if [[ -z "$seen" ]]; then
    log show --start "$launch_at" --style compact --predicate "$predicate" >"$out/log-head-show.txt" 2>"$out/log-head-show.err" || true
    if probe_event "$out/log-head-show.txt"; then seen=1 via=show; fi
  fi
  why=""
  [[ -z "$seen" ]] && why=" stream_err=\"$(head -c 200 "$out/log-head-stream.err" | tr '\n"' ' ')\" show_err=\"$(head -c 200 "$out/log-head-show.err" | tr '\n"' ' ')\""
  echo "SB-SEEN expect=\"$expect\" seen=${seen:-0} via=$via$why"
fi
"$side" stop sb-head >/dev/null 2>&1 || true
tar -czf "$out/overlay-head.tgz" -C "$out/build-head" app build.json
python3 -I - "$head" "$commit" "$version" "${base_build_s:-}" "$head_build_s" "$place_seal_s" "$edit_to_launchable_s" "${seen:-}" "$expect" <<'PY'
import json, sys
head, commit, version, bb, hb, ps, e2l, seen, expect = sys.argv[1:]
print("SB-PROOF " + json.dumps({"head": head, "nightly_commit": commit, "nightly_version": version,
    "base_build_s": int(bb) if bb else None, "head_build_s": int(hb), "place_seal_s": int(ps),
    "edit_to_cold_launchable_s": int(e2l), "expect": expect or None, "seen": bool(seen) if expect else None}))
PY
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude 'build-*/app' . 2>/dev/null || true
[[ -z "$expect" || -n "$seen" ]]
