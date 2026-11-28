#!/usr/bin/env bash
# The two-half screen-share-vs-pair.sh run (peer-token=) as one command, from a lane VM or any host with cmux-ci.
#
#   scripts/measure/screen-share-vs-pair-launch.sh HOST_MAC VIEWER_MAC [--ref SHA] [--viewer-ip IP] [--host-label L] [--queue-anyway] [RUN_ARG...]
#   (--host-label bench for a bench-only worker such as the dedicated bench mini; repeatable)
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
# Exit: the host half's exit (0 measured, 1 failed, 3 unreachable), 2 bad arguments, 4 no viewer address,
# 5 a half was refused at submit (a refused viewer means the host is never sent; a refused host cancels the viewer), 6 a Mac is offline, paused or reserved
# (--queue-anyway queues behind it instead; each half is pinned strictly, so it waits for that Mac and never moves).
# Whenever the launcher exits, it cancels any of its steps still queued or running, so no half outlives it.
set -uo pipefail
[[ $# -ge 2 ]] || { sed -n '3,4p' "$0" >&2; exit 2; }
host_mac=$1 viewer_mac=$2; shift 2
[[ "$host_mac" =~ ^[a-z0-9-]+$ && "$viewer_mac" =~ ^[a-z0-9-]+$ && "$host_mac" != "$viewer_mac" ]] \
  || { echo "HOST_MAC and VIEWER_MAC are two different fleet Mac names" >&2; exit 2; }
ref="" viewer_ip="" run_args=() host_labels=() queue_anyway=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref=${2:-}; shift 2 ;;
    --viewer-ip) viewer_ip=${2:-}; shift 2 ;;
    --host-label) host_labels+=(--label "${2:-}"); shift 2 ;;
    --queue-anyway) queue_anyway=1; shift ;;
    mode=*|partner=*|partner-ip=*|peer-token=*|role=*) echo "$1 is set by this launcher" >&2; exit 2 ;;
    *=*) run_args+=("--arg=$1"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
# Refused here too, before any half is queued: the host half would exit 2 on it (screen-share-vs-pair.sh).
[[ " ${run_args[*]-} " == *" --arg=host=nightly "* && " ${run_args[*]-} " == *" --arg=source=synthetic "* ]] \
  && { echo "host=nightly needs source=screen (the NIGHTLY's helper has no synthetic source; host=commit runs synthetic)" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
ref=${ref:-$(git merge-base HEAD origin/feat-cmux-next 2>/dev/null || git merge-base HEAD origin/main)}
key="ssvp-$(date -u +%m%d%H%M)-$(openssl rand -hex 3)"
token=$(openssl rand -hex 32)
out=${OUT:-artifacts/screen-share-vs-pair-launch/$key}
mkdir -p "$out"
script=scripts/measure/screen-share-vs-pair.sh
common=(--class exclusive --measurement --label measure --script "$script" --ref "$ref")

# A strictly pinned step on a paused Mac (disk, runner_job, host_lock) or a reserved one sits in the queue until the
# Mac frees up, hours at a time: the probe on a disk-paused viewer waited 140 min before the outer timeout. Ask first.
if [[ -z "$queue_anyway" ]]; then
  for mac in "$host_mac" "$viewer_mac"; do
    table=$(cmux-ci workers --name "$mac" --table 2>&1)
    line=$(grep -E "^$mac " <<<"$table" | head -1)
    why=""
    [[ -n "$line" ]] || why="not in the worker list"
    [[ -z "$why" && "$line" != *" state=online "* ]] && why="offline (${line%%  healthy=*})"
    [[ -z "$why" && "$line" != *" paused=- "* ]] && why="claims paused: $(grep -oE 'paused=[^ ]+' <<<"$line")"
    reserved=$(grep -E "^RESERVED $mac:" <<<"$table" | head -1)
    [[ -z "$why" && -n "$reserved" ]] && why="$reserved"
    [[ -z "$why" ]] || { echo "launch: $mac is $why; pick another Mac or pass --queue-anyway" >&2; exit 6; }
  done
fi

# Cancel what this launcher queued when it exits: a half whose partner never arrives otherwise holds its Mac for the
# 30 min pair wait (the viewer, when the host half is refused at submit) and a probe can wait on a paused Mac for hours.
cancel_live_steps() {
  local f id
  for f in "$out/probe.log" "$out/viewer.log" "$out/host.log"; do
    [[ -f "$f" ]] || continue
    # A finished step refuses the cancel; that refusal is the expected answer and is dropped.
    id=$(grep -oE '^cmux-ci: step [0-9a-f]{24}' "$f" | head -1 | awk '{print $3}')
    [[ -n "$id" ]] && cmux-ci cancel "$id" --reason "screen-share-vs-pair-launch $key exited" >/dev/null 2>&1
  done
}
trap cancel_live_steps EXIT
trap 'exit 143' TERM INT  # an outer timeout's TERM still runs the EXIT trap; each cmux-ci runs under `wait` for that

if [[ -z "$viewer_ip" ]]; then
  echo "launch: probing $viewer_mac for its LAN address" >&2
  # partner= is the host: the probe's ssh leg fails (fleet Macs hold no keys for each other); only its self line counts.
  cmux-ci run "${common[@]}" --target-worker "$viewer_mac" --pin-strict --timeout 900 \
    --arg=mode=probe "--arg=partner=$host_mac" >"$out/probe.log" 2>&1 &
  wait $!
  viewer_ip=$(grep -oE "SSVP self [^ ]+ ip=[0-9.]+" "$out/probe.log" | head -1 | sed 's/.*ip=//')
fi
[[ "$viewer_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
  || { echo "launch: no LAN address for $viewer_mac (see $out/probe.log)" >&2; tail -20 "$out/probe.log" >&2; exit 4; }
echo "launch: pair $key: host $host_mac -> viewer $viewer_mac $viewer_ip at $ref" >&2

cmux-ci run "${common[@]}" --pair "$key" --target-worker "$viewer_mac" --pin-strict --timeout 7200 \
  --arg=role=viewer "--arg=peer-token=$token" --artifact artifacts/screen-share-vs-pair/report.tgz \
  >"$out/viewer.log" 2>&1 &
viewer_pid=$!
# The controller refuses a pinned half at submit (a fleet reservation, a label the worker needs) while the other
# half sits in the pair wait for 30 min. Submit the host only once the viewer's step is accepted.
for _ in $(seq 120); do
  grep -q '^cmux-ci: step ' "$out/viewer.log" 2>/dev/null && break
  kill -0 "$viewer_pid" 2>/dev/null || break
  sleep 1
done
if ! grep -q '^cmux-ci: step ' "$out/viewer.log" 2>/dev/null; then
  wait "$viewer_pid" 2>/dev/null; viewer_rc=$?
  echo "launch: $key viewer half on $viewer_mac was not accepted (exit $viewer_rc); host not submitted:" >&2
  tail -5 "$out/viewer.log" >&2
  exit 5
fi
cmux-ci run "${common[@]}" ${host_labels[@]+"${host_labels[@]}"} --pair "$key" --target-worker "$host_mac" --pin-strict --timeout 7200 \
  --arg=mode=run "--arg=partner=$viewer_mac" "--arg=partner-ip=$viewer_ip" "--arg=peer-token=$token" \
  ${run_args[@]+"${run_args[@]}"} --artifact artifacts/screen-share-vs-pair/report.tgz >"$out/host.log" 2>&1 &
wait $!; host_rc=$?
if ! grep -q '^cmux-ci: step ' "$out/host.log" 2>/dev/null; then
  # The host half was refused at submit: the EXIT trap cancels the queued viewer instead of letting it sit 30 min.
  echo "launch: $key host half on $host_mac was not accepted (exit $host_rc); viewer half cancelled:" >&2
  tail -5 "$out/host.log" >&2
  exit 5
fi
wait "$viewer_pid"; viewer_rc=$?
grep -E '^SSVP |step|cmux-ci run:' "$out/host.log" | tail -30
echo "launch: $key host exit $host_rc, viewer exit $viewer_rc; logs in $out" >&2
exit "$host_rc"
