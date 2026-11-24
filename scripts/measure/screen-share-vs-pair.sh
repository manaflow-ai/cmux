#!/usr/bin/env bash
# screen-share-vs.py on a fleet Mac pair as one cmux-ci job, for a lane VM with no ssh path to the pair
# (since the 2026-11-22 control-plane cutover the broker's tailnet reaches only some minis, so `--via spool`
# cannot drive both Macs). The job runs on one Mac of the pair and drives the other over the office LAN.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/screen-share-vs-pair.sh \
#     --ref SHA --target-worker cmux17 --arg=mode=probe --arg=partner=cmux20
#
# mode=probe  prints this Mac's name and LAN address and whether `ssh -o BatchMode=yes` reaches the partner by
#             each name it tries (NAME, NAME.local, partner-ip=IP when given). Exit 0 when one does, 1 when none.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="" partner="" partner_ip=""
for arg in "$@"; do
  case "$arg" in
    mode=probe) mode="${arg#mode=}" ;;
    partner=*) partner="${arg#partner=}" ;;
    partner-ip=*) partner_ip="${arg#partner-ip=}" ;;
    *) echo "screen-share-vs-pair.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$partner" =~ ^[a-z0-9-]+$ ]] || { echo "screen-share-vs-pair.sh: partner= is a fleet Mac name" >&2; exit 2; }
[[ -z "$partner_ip" || "$partner_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "partner-ip= is an IPv4 address" >&2; exit 2; }
[[ "$mode" == probe ]] || { echo "screen-share-vs-pair.sh: mode=probe is the only mode so far" >&2; exit 2; }

echo "SSVP self $(hostname -s) en0=$(ipconfig getifaddr en0 2>/dev/null) en1=$(ipconfig getifaddr en1 2>/dev/null) user=$(id -un)"
echo "SSVP keys $(ls ~/.ssh 2>/dev/null | grep -v -E '^known_hosts' | tr '\n' ' ')"
reached=1
for target in "$partner" "$partner.local" ${partner_ip:+"$partner_ip"}; do
  addr=$(dscacheutil -q host -a name "$target" 2>/dev/null | awk '/ip_address/ {print $2; exit}')
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$target" 'hostname -s' 2>&1 | tail -1)
  rc=$?
  echo "SSVP ssh $target addr=${addr:-?} rc=$rc out=${out:0:160}"
  [[ "$out" == "$partner"* ]] && reached=0
done
exit "$reached"
