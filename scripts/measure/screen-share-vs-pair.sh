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
# inputs=     the cmux leg's timed presses, one leg per kind (--cmux-input; default key): key,click,scroll
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
# Exit: 0 measured, 1 the run failed, 2 bad arguments, 3 the partner is unreachable or the tools did not build.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="" partner="" partner_ip="" loss=0 profile= source=screen fps_trials=3 trials=10 inputs=key samples=30 host=commit role=host peer_token="" hold_s=3600
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
[[ "$inputs" =~ ^(key|click|scroll)(,(key|click|scroll))*$ ]] || { echo "inputs= lists key, click and scroll" >&2; exit 2; }

out=artifacts/screen-share-vs-pair
work=$(mktemp -d "${TMPDIR:-/tmp}/ssvp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
self=$(hostname -s)
self_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
pack() { tar -czf "$out/report.tgz" -C "$work" $(cd "$work" && ls run.jsonl run.log probe.txt 2>/dev/null); }

{
  echo "SSVP self $self ip=${self_ip:-?} user=$(id -un)"
  echo "SSVP keys $(ls ~/.ssh 2>/dev/null | grep -v -E '^known_hosts' | tr '\n' ' ')"
} | tee "$work/probe.txt"
vs=cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py
peer_port=4181
if [[ -n "$peer_token" ]]; then
  printf '%s\n' "$peer_token" >"$work/peer-token"; chmod 600 "$work/peer-token"
fi
if [[ "$role" == viewer ]]; then
  [[ -n "$self_ip" ]] || { echo "SSVP no LAN address on $self" | tee -a "$work/probe.txt"; pack; exit 3; }
  echo "SSVP viewer serving $self_ip:$peer_port for ${hold_s} s" | tee -a "$work/probe.txt"
  python3 -I "$vs" peer-serve --bind "$self_ip" --port "$peer_port" --token-file "$work/peer-token" \
    --hold-s "$hold_s" 2>&1 | tee "$work/run.log"
  rc=${PIPESTATUS[0]}
  pack; exit "$rc"
fi
target=""
[[ -n "$peer_token" ]] && [[ -z "$partner_ip" ]] && { echo "peer-token= needs partner-ip=" >&2; exit 2; }
via_args=(--via ssh)
if [[ -n "$peer_token" ]]; then
  # The viewer half starts with its step: wait for its server up to 30 min (it may queue behind the host's).
  url="http://$partner_ip:$peer_port"
  for _ in $(seq 1 360); do
    got=$(python3 -I - "$url" "$work/peer-token" <<'PY' 2>&1
import json, sys, urllib.request
token = open(sys.argv[2]).read().strip()
req = urllib.request.Request(sys.argv[1] + "/run", method="POST", headers={"X-Eval-Token": token},
                             data=json.dumps({"cmd": "hostname -s", "timeout": 10}).encode())
res = json.loads(urllib.request.urlopen(req, timeout=10).read())
print(res["out"].strip() if res.get("rc") == 0 else "rc=%s" % res.get("rc"))
PY
    )
    [[ "$got" == "$partner"* ]] && break
    sleep 5
  done
  echo "SSVP peer $url out=${got:0:160}" | tee -a "$work/probe.txt"
  [[ "$got" == "$partner"* ]] && target="$partner" via_args=(--via peer --peer-url "$url" --peer-token-file "$work/peer-token")
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

link=wired loss_args=() profile_args=() suffix=
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
    --host "$self" --viewer "$target" --host-ip "$self_ip" --local-mac "$self" "${via_args[@]}" \
    --tools "$work/tools" ${host_args[@]+"${host_args[@]}"} --stacks cmux --source "$source" --link "$link" \
    ${loss_args[@]+"${loss_args[@]}"} ${profile_args[@]+"${profile_args[@]}"} --cmux-input "$kind" --samples "$samples" \
    --fps-trials "$legfps" --trials "$trials" --label "pair-job-$host-$kind$suffix" --rev "$(git rev-parse HEAD)" \
    --out "$work/run-$kind.jsonl" 2>&1 | tee -a "$work/run.log"
  leg=${PIPESTATUS[0]}
  cat "$work/run-$kind.jsonl" >>"$work/run.jsonl" 2>/dev/null
  [[ "$leg" == 0 ]] || rc=$leg
done
if [[ -n "$peer_token" ]]; then  # the viewer half ends now, not at its hold
  python3 -I -c 'import sys, urllib.request
urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/done", data=b"{}", method="POST",
    headers={"X-Eval-Token": open(sys.argv[2]).read().strip()}), timeout=10).close()' "$url" "$work/peer-token" || true
fi
echo "SSVP done rc=$rc host=$self ($host) viewer=$partner link=$link inputs=$inputs at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pack
[[ "$rc" == 0 ]] || exit 1
