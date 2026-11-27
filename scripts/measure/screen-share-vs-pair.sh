#!/usr/bin/env bash
# screen-share-vs.py on a fleet Mac pair as one cmux-ci job, for a lane VM with no ssh path to the pair
# (since the 2026-11-22 control-plane cutover the broker's tailnet reaches only some minis, so `--via spool`
# cannot drive both Macs). The job runs on the shared Mac and drives the viewing Mac over the office LAN by ssh.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/screen-share-vs-pair.sh \
#     --ref SHA --target-worker cmux20 --artifact artifacts/screen-share-vs-pair/report.tgz --timeout 3600 \
#     --arg=mode=run --arg=partner=cmux17 [--arg=loss=1] [--arg=profile=ultra] [--arg=source=screen] [--arg=fps-trials=3] [--arg=trials=10] \
#     [--arg=inputs=key,click,scroll] [--arg=samples=30] [--arg=host=nightly]
#
# mode=probe  prints this Mac's name and LAN address and whether `ssh -o BatchMode=yes` reaches the partner by
#             each name it tries (NAME, NAME.local, partner-ip=IP when given). Exit 0 when one does, 1 when none.
# mode=run    the probe, then the rd tools built at this commit (screen-stream-eval.sh tools-only=1), then
#             `screen-share-vs.py run --stacks cmux --local-mac THIS --via ssh` with this Mac as host and the
#             partner as viewer. loss=PCT (default 0: none) is --host-test-loss, the share of video and parity
#             datagrams the host drops after its loss meter counts them sent (no shaper, no sudo); the leg's
#             --link is `loss<PCT>` then, else `wired`. report.tgz holds run.jsonl (the --out file, which
#             cmuxterm-hq's screen_share_fast_receipt.py extract reads), run.log and probe.txt.
# profile=    standard|ultra is --encode-profile (default: none sent, the host runs standard); with
#             profile=ultra each leg's label gains `-ultra`, so a first p50 from any two reachable Macs
#             reads as not-the-wired-pair unless the pair is cmux20 -> cmux17.
# inputs=     the cmux leg's timed presses, one leg per kind (--cmux-input; default key): key,click,scroll,clipboard (clipboard: copy-paste round trips, cap clipboard.text)
#             times each through the host's injector, samples= presses per trial (default 30). run.jsonl
#             holds every leg's rows; the fps trials run with the first kind only.
# host=nightly  the shared Mac serves from the NIGHTLY's Screen Sharing helper (its
#             Contents/Library/cmux NIGHTLY Helper.app, what the app's `cmux rd serve` runs) through
#             --host-bin, not the cmux-rd built at this commit: the installed /Applications/cmux NIGHTLY.app
#             (the granted copy), else the newest DMG in the appcast; probe.txt names which and its version.
#             Default host=commit.
# peer-token=HEX (64 hex) runs the pair with no ssh between the Macs (fleet Macs hold no key to each other) as
#             the two halves of one `--pair KEY` job, as screen-stream-eval.sh stage-table= does: the viewing
#             Mac's step (role=viewer) serves `screen-share-vs.py peer-serve` on its LAN address, port 4181, and
#             this one drives it with --via peer, so it needs partner-ip= (the viewer's LAN address):
#   cmux-ci run ... --pair KEY --target-worker HOST_MAC --pin-strict --arg=mode=run --arg=partner=VIEWER_MAC \
#     --arg=partner-ip=VIEWER_IP --arg=peer-token=$token [the run args]
#   cmux-ci run ... --pair KEY --target-worker VIEWER_MAC --pin-strict --arg=role=viewer --arg=peer-token=$token \
#     --artifact artifacts/screen-share-vs-pair/report.tgz
#             The viewer half ends at the host half's /done, or after hold-s= (default 3600) seconds.
# host-ip=lan|tailnet  the address the viewer dials for the clock probe and the stream (--host-ip). lan (default)
#             is this Mac's en0/en1 address. tailnet is its 100.64.0.0/10 address. A launchd step's own sockets to
#             an office-LAN address get EHOSTUNREACH (`No route to host`) from macOS Local Network privacy, so both
#             LAN halves run inside CmuxScreenEvalLauncher.app (the rig here, peer-serve on the viewer), which
#             holds that grant once it is allowed at each Mac's console; the run checks it before any leg
#             (`localnet` in run.jsonl) and stops naming the Mac that lacks it. Two Macs on one LAN reach each
#             other directly inside WireGuard; the leg's --link is `wired-tailnet` then.
# Exit: 0 measured, 1 the run failed, 2 bad arguments, 3 the partner is unreachable or the tools did not build.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="" partner="" partner_ip="" loss=0 profile= source=screen fps_trials=3 trials=10 inputs=key samples=30 host=commit role=host peer_token="" hold_s=3600 host_ip_kind=lan
for arg in "$@"; do
  case "$arg" in
    mode=probe|mode=run) mode="${arg#mode=}" ;;
    partner=*) partner="${arg#partner=}" ;;
    partner-ip=*) partner_ip="${arg#partner-ip=}" ;;
    loss=*) loss="${arg#loss=}" ;;
    profile=standard|profile=ultra) profile="${arg#profile=}" ;;
    source=screen|source=synthetic) source="${arg#source=}" ;;
    fps-trials=*) fps_trials="${arg#fps-trials=}" ;;
    trials=*) trials="${arg#trials=}" ;;
    inputs=*) inputs="${arg#inputs=}" ;;
    samples=*) samples="${arg#samples=}" ;;
    host=commit|host=nightly) host="${arg#host=}" ;;
    role=host|role=viewer) role="${arg#role=}" ;;
    peer-token=*) peer_token="${arg#peer-token=}" ;;
    hold-s=*) hold_s="${arg#hold-s=}" ;;
    host-ip=lan|host-ip=tailnet) host_ip_kind="${arg#host-ip=}" ;;
    *) echo "screen-share-vs-pair.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$peer_token" || "$peer_token" =~ ^[0-9a-f]{64}$ ]] || { echo "peer-token= is 64 hex" >&2; exit 2; }
[[ "$hold_s" =~ ^[0-9]{1,5}$ ]] || { echo "hold-s= is seconds" >&2; exit 2; }
[[ "$role" == host || -n "$peer_token" ]] || { echo "role=viewer needs peer-token=" >&2; exit 2; }
[[ "$role" == viewer ]] && mode=run partner=peer
[[ -n "$mode" ]] || { echo "screen-share-vs-pair.sh: mode=probe or mode=run" >&2; exit 2; }
[[ "$partner" =~ ^[a-z0-9-]+$ ]] || { echo "screen-share-vs-pair.sh: partner= is a fleet Mac name" >&2; exit 2; }
[[ -z "$partner_ip" || "$partner_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "partner-ip= is an IPv4 address" >&2; exit 2; }
[[ "$loss" =~ ^[0-9]{1,2}([.][0-9]{1,3})?$ ]] || { echo "loss= is a percentage below 100" >&2; exit 2; }
[[ "$fps_trials" =~ ^[0-9]{1,2}$ && "$trials" =~ ^[0-9]{1,3}$ && "$samples" =~ ^[0-9]{1,3}$ ]] \
  || { echo "fps-trials=, trials= and samples= are counts" >&2; exit 2; }
[[ "$inputs" =~ ^(key|click|scroll|clipboard)(,(key|click|scroll|clipboard))*$ ]] || { echo "inputs= lists key, click, scroll and clipboard" >&2; exit 2; }
# The synthetic sources exist only in bench builds (cmux-rd-host lib.rs: "macOS bench builds"); the NIGHTLY's
# helper is a release build, so its `serve --source synthetic-still` prints no key, every trial sends the viewer
# `peer_key: null` and fails "answer line: invalid type: null", and the run ends with no sample at all.
[[ "$role" == viewer || "$host" != nightly || "$source" != synthetic ]] \
  || { echo "screen-share-vs-pair.sh: host=nightly needs source=screen (the NIGHTLY's helper has no synthetic source; host=commit runs synthetic)" >&2; exit 2; }

out=artifacts/screen-share-vs-pair
work=$(mktemp -d "${TMPDIR:-/tmp}/ssvp.XXXXXX")
# viewer_done: the host half's /done to the viewer half, once. On every exit after the viewer answered: an early
# exit 3 (no LAN address, the tools build, the NIGHTLY helper, the rig) left the viewer Mac serving its whole hold-s=.
viewer_url=""
viewer_done() {
  [[ -n "$viewer_url" ]] || return 0
  python3 -I -c 'import sys, urllib.request
urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/done", data=b"{}", method="POST",
    headers={"X-Eval-Token": open(sys.argv[2]).read().strip()}), timeout=10).close()' "$viewer_url" "$work/peer-token" || true
  viewer_url=""
}
trap 'viewer_done; rm -rf "$work"' EXIT
mkdir -p "$out"
self=$(hostname -s)
self_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
pack() { tar -czf "$out/report.tgz" -C "$work" $(cd "$work" && ls run.jsonl run.log probe.txt rig.log 2>/dev/null); }

{
  echo "SSVP self $self ip=${self_ip:-?} user=$(id -un)"
  echo "SSVP keys $(ls ~/.ssh 2>/dev/null | grep -v -E '^known_hosts' | tr '\n' ' ')"
} | tee "$work/probe.txt"
vs=cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py
# tcp_check ADDR PORT: one TCP connect from this step, printed as `ok` or the errno and its name.
tcp_check() {
  python3 -I -c 'import errno, socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close(); print("ok")
except OSError as e:
    print("errno=%s %s %s" % (e.errno, errno.errorcode.get(e.errno or 0, "?"), e.strerror or type(e).__name__))' "$1" "$2"
}
peer_port=4181
rig_root=""
if [[ -n "$peer_token" ]]; then
  printf '%s\n' "$peer_token" >"$work/peer-token"; chmod 600 "$work/peer-token"
  # Each cmux-ci step has its own HOME, so the two halves share no home-relative --root: both use one
  # absolute path, named from the token so both halves agree on it, and each removes it when done.
  rig_root="/tmp/ssvp-rd-$(printf '%s' "$peer_token" | shasum -a 256 | cut -c1-12)"
fi
# The rig root screen-share-vs.py uses on both Macs. Over peer-serve the two steps run in different homes (a
# worker's step home, the bench account's), so its home-relative default fails "different homes". Absolute, the
# same on both Macs, per run by the secret token (no other account can claim it first), space-free. One root only:
# the source=screen rig listens under $rig_root, and a second --root on the leg (last flag wins) sent every rig
# ping elsewhere, so the leg failed "the rig is not running" right after `SSVP rig up=1`.
root_args=()
[[ -n "$rig_root" ]] && root_args=(--root "$rig_root")
if [[ "$role" == viewer ]]; then
  [[ -n "$self_ip" ]] || { echo "SSVP no LAN address on $self" | tee -a "$work/probe.txt"; pack; exit 3; }
  echo "SSVP viewer serving $self_ip:$peer_port for ${hold_s} s" | tee -a "$work/probe.txt"
  # What decides whether the host half's dial lands: this Mac's Application Firewall (read only) and a
  # connect to its own LAN address once the server listens (a refused self-connect is a bind problem).
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  [[ -x "$fw" ]] && echo "SSVP firewall $("$fw" --getglobalstate --getblockall --getstealthmode 2>&1 | tr -s ' \n' ' ')" \
    | tee -a "$work/probe.txt"
  (sleep 3; echo "SSVP self-connect $self_ip:$peer_port $(tcp_check "$self_ip" "$peer_port")" \
    | tee -a "$work/probe.txt") &
  # Inside CmuxScreenEvalLauncher.app (screen-stream-eval.sh peer-serve=): the bench peer-serve starts sends
  # the stream's UDP to the shared Mac's LAN address, which macOS Local Network privacy refuses this step's
  # own processes (`sends refused: No route to host (os error 65)`); the app holds that grant.
  bash scripts/measure/screen-stream-eval.sh "peer-serve=$self_ip" "peer-port=$peer_port" "peer-hold=$hold_s" \
    "peer-token-file=$work/peer-token" 2>&1 | tee "$work/run.log"
  rc=${PIPESTATUS[0]}
  [[ -n "$rig_root" ]] && rm -rf "$rig_root"
  pack; exit "$rc"
fi
target=""
[[ -n "$peer_token" ]] && [[ -z "$partner_ip" ]] && { echo "peer-token= needs partner-ip=" >&2; exit 2; }
via_args=(--via ssh)
if [[ -n "$peer_token" ]]; then
  # The viewer half starts with its step: wait for its server up to 30 min (it may queue behind the host's).
  url="http://$partner_ip:$peer_port"
  # Each try's last line names its error (`URLError ... [Errno 65] No route to host` is macOS Local Network
  # privacy refusing this step the LAN; a refused or timed-out connect is a viewer not up yet).
  echo "SSVP tcp $partner_ip:22 $(tcp_check "$partner_ip" 22)" | tee -a "$work/probe.txt"
  echo "SSVP route $(route -n get "$partner_ip" 2>&1 | awk '/gateway|interface/ {printf "%s ", $0}' | tr -s ' ')" \
    | tee -a "$work/probe.txt"
  unreach=0
  for _ in $(seq 1 360); do
    got=$(python3 -I - "$url" "$work/peer-token" <<'PY' 2>&1 | tail -1
import json, sys, urllib.request
token = open(sys.argv[2]).read().strip()
req = urllib.request.Request(sys.argv[1] + "/run", method="POST", headers={"X-Eval-Token": token},
                             data=json.dumps({"cmd": "hostname -s", "timeout": 10}).encode())
res = json.loads(urllib.request.urlopen(req, timeout=10).read())
print(res["out"].strip() if res.get("rc") == 0 else "rc=%s" % res.get("rc"))
PY
    )
    [[ "$got" == "$partner"* ]] && break
    # EHOSTUNREACH a minute running is not a viewer still queued: the dial itself is refused, every try alike.
    if [[ "$got" == *"Errno 65"* ]]; then unreach=$((unreach + 1)); else unreach=0; fi
    [[ "$unreach" -ge 12 ]] && break
    sleep 5
  done
  echo "SSVP peer $url out=${got:0:300}" | tee -a "$work/probe.txt"
  [[ "$got" == "$partner"* ]] && target="$partner" viewer_url="$url" \
    via_args=(--via peer --peer-url "$url" --peer-token-file "$work/peer-token")
fi
[[ -n "$peer_token" ]] || for t in "$partner" "$partner.local" ${partner_ip:+"$partner_ip"}; do
  got=$(ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$t" 'hostname -s' 2>&1 | tail -1)
  rc=$?
  echo "SSVP ssh $t rc=$rc out=${got:0:160}" | tee -a "$work/probe.txt"
  [[ -z "$target" && "$got" == "$partner"* ]] && target="$t"
done
if [[ -z "$target" ]]; then
  echo "SSVP unreachable: no ssh route from $self to $partner" | tee -a "$work/probe.txt"
  pack; exit 3
fi
[[ "$mode" == probe ]] && { pack; exit 0; }

viewer_ip="$partner_ip"
[[ -n "$peer_token" ]] || viewer_ip=$(ssh -o BatchMode=yes "$target" 'ipconfig getifaddr en0 || ipconfig getifaddr en1' 2>/dev/null | tail -1)
echo "SSVP pair host $self ${self_ip:-?} -> viewer $target ${viewer_ip:-?}" | tee -a "$work/probe.txt"
[[ -n "$self_ip" ]] || { echo "SSVP no LAN address on $self" | tee -a "$work/probe.txt"; pack; exit 3; }
dial_ip="$self_ip"
if [[ "$host_ip_kind" == tailnet ]]; then
  # This Mac's tailnet address, from its interfaces (no tailscale CLI needed): the first inet in 100.64.0.0/10.
  dial_ip=$(ifconfig 2>/dev/null | awk '$1 == "inet" && $2 ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ {print $2; exit}')
  [[ -n "$dial_ip" ]] || { echo "SSVP host-ip=tailnet: no 100.64.0.0/10 address on $self" | tee -a "$work/probe.txt"; pack; exit 3; }
  echo "SSVP host-ip tailnet $dial_ip (the viewer dials it; LAN $self_ip)" | tee -a "$work/probe.txt"
fi

echo "SSVP building the rd tools at $(git rev-parse --short HEAD)"
scripts/measure/screen-stream-eval.sh tools-only=1 >"$work/tools.log" 2>&1 \
  && tar -xzf artifacts/screen-stream-eval/tools.tar.gz -C "$work" \
  || { tail -40 "$work/tools.log"; cp "$work/tools.log" "$work/run.log"; pack; exit 3; }

host_args=()
if [[ "$host" == nightly ]]; then
  # The installed NIGHTLY first: its helper is the copy macOS granted Screen Recording and Accessibility.
  app="/Applications/cmux NIGHTLY.app" dmg="installed"
  if [[ ! -d "$app" ]]; then
    dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    [[ "$dmg" == https://* ]] || { echo "SSVP no NIGHTLY installed and no DMG in the feed" | tee -a "$work/probe.txt"; pack; exit 3; }
    mnt="$work/mnt" app="$work/app/cmux NIGHTLY.app"; mkdir -p "$mnt" "$work/app"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" \
      && hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null \
      && ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app"
    hdiutil detach "$mnt" >/dev/null 2>&1
  fi
  helper="$app/Contents/Library/cmux NIGHTLY Helper.app/Contents/MacOS/cmux-screen-sharing"
  [[ -x "$helper" ]] || { echo "SSVP no Screen Sharing helper in $app ($dmg)" | tee -a "$work/probe.txt"; pack; exit 3; }
  version="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null)"
  printf '#!/bin/sh\nexec %q "$@"\n' "$helper" >"$work/nightly-host"; chmod +x "$work/nightly-host"
  host_args=(--host-bin "$work/nightly-host")
  echo "SSVP host NIGHTLY ${version:-?} $dmg" | tee -a "$work/probe.txt"
fi

# source=screen over the peer route: the rig (it starts the host and posts the input) runs in the launcher app's
# grants, which a step's own processes lack (screen-stream-eval.sh rig=); the legs reach it at --root.
rig_pid=""
if [[ "$source" == screen && -n "$rig_root" ]]; then
  mkdir -p "$rig_root" && chmod 700 "$rig_root"
  bash scripts/measure/screen-stream-eval.sh "rig=$rig_root" >"$work/rig.log" 2>&1 &
  rig_pid=$!
  up=0
  for _ in $(seq 1 600); do  # up to 2 min: the first run on a Mac installs the launcher
    python3 -I "$vs" rig-call --root "$rig_root" '{"cmd": "ping"}' 2>/dev/null | grep -q '"ok": *true' && { up=1; break; }
    kill -0 "$rig_pid" 2>/dev/null || break
    sleep 0.2
  done
  echo "SSVP rig up=$up $(grep -m1 SCREEN-STREAM-EVAL-RIG "$work/rig.log")" | tee -a "$work/probe.txt"
  if [[ "$up" != 1 ]]; then
    tail -20 "$work/rig.log" | tee -a "$work/probe.txt"
    kill "$rig_pid" 2>/dev/null; rm -rf "$rig_root"; pack; exit 3
  fi
fi
link=wired loss_args=() profile_args=() suffix=
[[ "$host_ip_kind" == tailnet ]] && link=wired-tailnet
[[ -n "$profile" ]] && { profile_args=(--encode-profile "$profile"); suffix="-$profile"; }
if [[ "$loss" != 0 ]]; then
  link="loss${loss}" loss_args=(--host-test-loss "$loss")
fi
rc=0 first=1
: >"$work/run.jsonl"; : >"$work/run.log"
for kind in ${inputs//,/ }; do
  legfps=0; [[ "$first" == 1 ]] && legfps="$fps_trials"; first=0
  echo "SSVP leg input=$kind host=$host samples=$samples trials=$trials" | tee -a "$work/run.log"
  python3 -I "$vs" run \
    --host "$self" --viewer "$target" --host-ip "$dial_ip" --local-mac "$self" "${via_args[@]}" \
    --tools "$work/tools" ${host_args[@]+"${host_args[@]}"} --stacks cmux --source "$source" --link "$link" \
    ${loss_args[@]+"${loss_args[@]}"} ${profile_args[@]+"${profile_args[@]}"} --cmux-input "$kind" --samples "$samples" \
    --fps-trials "$legfps" --trials "$trials" --label "pair-job-$host-$kind$suffix" --rev "$(git rev-parse HEAD)" \
    ${root_args[@]+"${root_args[@]}"} \
    --out "$work/run-$kind.jsonl" 2>&1 | tee -a "$work/run.log"
  leg=${PIPESTATUS[0]}
  cat "$work/run-$kind.jsonl" >>"$work/run.jsonl" 2>/dev/null
  [[ "$leg" == 0 ]] || rc=$leg
done
if [[ -n "$rig_pid" ]]; then
  python3 -I "$vs" rig-call --root "$rig_root" '{"cmd": "quit"}' >/dev/null 2>&1
  for _ in $(seq 1 50); do kill -0 "$rig_pid" 2>/dev/null || break; sleep 0.2; done
  kill "$rig_pid" 2>/dev/null; wait "$rig_pid" 2>/dev/null
fi
[[ -n "$rig_root" ]] && rm -rf "$rig_root"
viewer_done  # the viewer half ends now, not at its hold
echo "SSVP done rc=$rc host=$self ($host) viewer=$partner link=$link inputs=$inputs at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pack
[[ "$rc" == 0 ]] || exit 1
