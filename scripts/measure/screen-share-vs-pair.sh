#!/usr/bin/env bash
# screen-share-vs.py on a fleet Mac pair as one cmux-ci job, for a lane VM with no ssh path to the pair
# (since the 2026-11-22 control-plane cutover the broker's tailnet reaches only some minis, so `--via spool`
# cannot drive both Macs). The job runs on the shared Mac and drives the viewing Mac over the office LAN by ssh.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/screen-share-vs-pair.sh \
#     --ref SHA --target-worker cmux20 --artifact artifacts/screen-share-vs-pair/report.tgz --timeout 3600 \
#     --arg=mode=run --arg=partner=cmux17 [--arg=loss=1] [--arg=source=screen] [--arg=fps-trials=3] [--arg=trials=10]
#
# mode=probe  prints this Mac's name and LAN address and whether `ssh -o BatchMode=yes` reaches the partner by
#             each name it tries (NAME, NAME.local, partner-ip=IP when given). Exit 0 when one does, 1 when none.
# mode=run    the probe, then the rd tools built at this commit (screen-stream-eval.sh tools-only=1), then
#             `screen-share-vs.py run --stacks cmux --local-mac THIS --via ssh` with this Mac as host and the
#             partner as viewer. loss=PCT (default 0: none) is --host-test-loss, the share of video and parity
#             datagrams the host drops after its loss meter counts them sent (no shaper, no sudo); the leg's
#             --link is `loss<PCT>` then, else `wired`. report.tgz holds run.jsonl (the --out file, which
#             cmuxterm-hq's screen_share_fast_receipt.py extract reads), run.log and probe.txt.
# Exit: 0 measured, 1 the run failed, 2 bad arguments, 3 the partner is unreachable or the tools did not build.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="" partner="" partner_ip="" loss=0 source=screen fps_trials=3 trials=10
for arg in "$@"; do
  case "$arg" in
    mode=probe|mode=run) mode="${arg#mode=}" ;;
    partner=*) partner="${arg#partner=}" ;;
    partner-ip=*) partner_ip="${arg#partner-ip=}" ;;
    loss=*) loss="${arg#loss=}" ;;
    source=screen|source=synthetic) source="${arg#source=}" ;;
    fps-trials=*) fps_trials="${arg#fps-trials=}" ;;
    trials=*) trials="${arg#trials=}" ;;
    *) echo "screen-share-vs-pair.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -n "$mode" ]] || { echo "screen-share-vs-pair.sh: mode=probe or mode=run" >&2; exit 2; }
[[ "$partner" =~ ^[a-z0-9-]+$ ]] || { echo "screen-share-vs-pair.sh: partner= is a fleet Mac name" >&2; exit 2; }
[[ -z "$partner_ip" || "$partner_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "partner-ip= is an IPv4 address" >&2; exit 2; }
[[ "$loss" =~ ^[0-9]{1,2}([.][0-9]{1,3})?$ ]] || { echo "loss= is a percentage below 100" >&2; exit 2; }
[[ "$fps_trials" =~ ^[0-9]{1,2}$ && "$trials" =~ ^[0-9]{1,3}$ ]] || { echo "fps-trials= and trials= are counts" >&2; exit 2; }

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
target=""
for t in "$partner" "$partner.local" ${partner_ip:+"$partner_ip"}; do
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

viewer_ip=$(ssh -o BatchMode=yes "$target" 'ipconfig getifaddr en0 || ipconfig getifaddr en1' 2>/dev/null | tail -1)
echo "SSVP pair host $self ${self_ip:-?} -> viewer $target ${viewer_ip:-?}" | tee -a "$work/probe.txt"
[[ -n "$self_ip" ]] || { echo "SSVP no LAN address on $self" | tee -a "$work/probe.txt"; pack; exit 3; }

echo "SSVP building the rd tools at $(git rev-parse --short HEAD)"
scripts/measure/screen-stream-eval.sh tools-only=1 >"$work/tools.log" 2>&1 \
  && tar -xzf artifacts/screen-stream-eval/tools.tar.gz -C "$work" \
  || { tail -40 "$work/tools.log"; cp "$work/tools.log" "$work/run.log"; pack; exit 3; }

link=wired loss_args=()
if [[ "$loss" != 0 ]]; then
  link="loss${loss}" loss_args=(--host-test-loss "$loss")
fi
python3 -I cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py run \
  --host "$self" --viewer "$target" --host-ip "$self_ip" --local-mac "$self" --via ssh \
  --tools "$work/tools" --stacks cmux --source "$source" --link "$link" ${loss_args[@]+"${loss_args[@]}"} \
  --fps-trials "$fps_trials" --trials "$trials" --label "pair-job" --rev "$(git rev-parse HEAD)" \
  --out "$work/run.jsonl" 2>&1 | tee "$work/run.log"
rc=${PIPESTATUS[0]}
echo "SSVP done rc=$rc host=$self viewer=$partner link=$link at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pack
[[ "$rc" == 0 ]] || exit 1
