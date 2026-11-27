#!/usr/bin/env bash
# The two-half screen-share-vs-pair.sh run (peer-token=) as one command, from a lane VM or any host with cmux-ci.
#
#   scripts/measure/screen-share-vs-pair-launch.sh HOST_MAC VIEWER_MAC [--ref SHA] [--viewer-ip IP] [RUN_ARG...]
#   e.g. scripts/measure/screen-share-vs-pair-launch.sh cmux19 cmux23 host=nightly inputs=key,click,scroll samples=30 trials=2
#
# By hand the pair is three cmux-ci runs: a mode=probe step on the viewer to learn its LAN address (the host half
# needs partner-ip= and nothing on a lane VM knows a mini's office address), then the host and viewer halves with
# the same --pair key and peer-token, each pinned. This makes the token and key, reads the viewer's address from
# its probe (unless --viewer-ip), starts both halves at once and waits for both. RUN_ARGs go to the host half
# (mode=run, partner= and partner-ip= are set here). Logs and report.tgz land in $OUT (default
# artifacts/screen-share-vs-pair-launch/<key>/): host.log, viewer.log, probe.log.
# The controller runs an unlisted scripts/measure script only at a commit on feat-cmux-next or main, so --ref
# defaults to this checkout's merge-base with origin/feat-cmux-next (a PR head is refused with HTTP 400).
# Exit: the host half's exit (0 measured, 1 failed, 3 unreachable), 2 bad arguments, 4 no viewer address.
set -uo pipefail
[[ $# -ge 2 ]] || { sed -n '3,4p' "$0" >&2; exit 2; }
host_mac=$1 viewer_mac=$2; shift 2
[[ "$host_mac" =~ ^[a-z0-9-]+$ && "$viewer_mac" =~ ^[a-z0-9-]+$ && "$host_mac" != "$viewer_mac" ]] \
  || { echo "HOST_MAC and VIEWER_MAC are two different fleet Mac names" >&2; exit 2; }
ref="" viewer_ip="" run_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref=${2:-}; shift 2 ;;
    --viewer-ip) viewer_ip=${2:-}; shift 2 ;;
    mode=*|partner=*|partner-ip=*|peer-token=*|role=*) echo "$1 is set by this launcher" >&2; exit 2 ;;
    *=*) run_args+=("--arg=$1"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
ref=${ref:-$(git merge-base HEAD origin/feat-cmux-next 2>/dev/null || git merge-base HEAD origin/main)}
key="ssvp-$(date -u +%m%d%H%M)-$(openssl rand -hex 3)"
token=$(openssl rand -hex 32)
out=${OUT:-artifacts/screen-share-vs-pair-launch/$key}
mkdir -p "$out"
script=scripts/measure/screen-share-vs-pair.sh
common=(--class exclusive --measurement --label measure --script "$script" --ref "$ref")

if [[ -z "$viewer_ip" ]]; then
  echo "launch: probing $viewer_mac for its LAN address" >&2
  # partner= is the host: the probe's ssh leg fails (fleet Macs hold no keys for each other); only its self line counts.
  cmux-ci run "${common[@]}" --target-worker "$viewer_mac" --pin-strict --timeout 900 \
    --arg=mode=probe "--arg=partner=$host_mac" >"$out/probe.log" 2>&1
  viewer_ip=$(grep -oE "SSVP self [^ ]+ ip=[0-9.]+" "$out/probe.log" | head -1 | sed 's/.*ip=//')
fi
[[ "$viewer_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
  || { echo "launch: no LAN address for $viewer_mac (see $out/probe.log)" >&2; tail -20 "$out/probe.log" >&2; exit 4; }
echo "launch: pair $key: host $host_mac -> viewer $viewer_mac $viewer_ip at $ref" >&2

cmux-ci run "${common[@]}" --pair "$key" --target-worker "$viewer_mac" --pin-strict --timeout 7200 \
  --arg=role=viewer "--arg=peer-token=$token" --artifact artifacts/screen-share-vs-pair/report.tgz \
  >"$out/viewer.log" 2>&1 &
viewer_pid=$!
cmux-ci run "${common[@]}" --pair "$key" --target-worker "$host_mac" --pin-strict --timeout 7200 \
  --arg=mode=run "--arg=partner=$viewer_mac" "--arg=partner-ip=$viewer_ip" "--arg=peer-token=$token" \
  ${run_args[@]+"${run_args[@]}"} --artifact artifacts/screen-share-vs-pair/report.tgz >"$out/host.log" 2>&1
host_rc=$?
wait "$viewer_pid"; viewer_rc=$?
grep -E '^SSVP |step|cmux-ci run:' "$out/host.log" | tail -30
echo "launch: $key host exit $host_rc, viewer exit $viewer_rc; logs in $out" >&2
exit "$host_rc"
