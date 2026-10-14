#!/usr/bin/env bash
# typeahead-gate.sh TAG ROUNDS [PROOF...] (cx-wb5.76, cx-wb5.78): the typeahead GUI gate. Run it on
# the GUI host through nx-remote, once, detached:
#   nx-remote --detach --needs gui --timeout 5400 -- bash scripts/cmux-next/typeahead-gate.sh TAG 20
# It needs /tmp/TAG.zip on the host: the fleet build of TAG (`cmux-ci build cmux --tag TAG
# --backend-mode local`, then `cmux-ci artifact JOB /tmp/TAG.zip` copied there). It unpacks the app
# into ~/ffre-cmp/TAG, runs each PROOF on a fresh launch of it (input journal on, never activated),
# prints one summary line per proof, and exits 1 when any run lost a key.
#   split, newterm   typeahead-compare.py: Cmd+D or New Terminal Tab, then `echo tkN` + Return at
#                    once; the line runs once, in order, and no other view gets a byte.
#                    runs_by_terminal_id counts runs whose keys went to the daemon by the minted
#                    terminal id before the view attached (cx-wb5.78).
#   split-slowhost   split with every host start 400 ms slower (CMUX_TUI_TEST_HOST_READY_DELAY_MS),
#                    so the keys surely arrive while the terminal is being created.
#   newtab-hello, newtab-chrome   new-tab-typeahead-proof.py: keys typed into a new Cmd-T.
#   cold             new-tab-cold-proof.sh: keys typed into the first Cmd-T of a fresh launch.
# Default: all of them. creation-hold-proof.py (only on branch feat-cmux-next-ff-hold-ends) is
# superseded: it needs `debug.creation_hold` and checks that a split holds keys before its reply,
# which a split that sends keys by terminal id no longer does.
set -u
TAG=${1:?usage: typeahead-gate.sh TAG ROUNDS [PROOF...]} ROUNDS=${2:?rounds}
shift 2
PROOFS=${*:-split newterm split-slowhost newtab-hello newtab-chrome cold}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HOME/ffre-cmp
mkdir -p "$ROOT"
cp "$HERE/typeahead-compare.py" "$HERE/new-tab-typeahead-proof.py" "$HERE/new-tab-cold-proof.sh" "$ROOT/"
cd "$ROOT" || exit 2
rm -rf "$TAG" && mkdir -p "$TAG" && (cd "$TAG" && ditto -x -k "/tmp/$TAG.zip" .) || exit 2
APP="$ROOT/$TAG/cmux DEV $TAG.app"

# One fresh launch of the app around CMD; kills only the app and daemon it started.
run_one() {
  CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_INPUT_JOURNAL=1 nohup "$APP/Contents/MacOS/cmux DEV" > "app-$TAG.out" 2>&1 &
  local pid=$! i p
  for i in $(seq 1 150); do [ -S "/tmp/cmux-debug-$TAG.sock" ] && break; sleep 0.2; done
  sleep 6
  "$@"
  echo "cmd_exit=$?"
  kill "$pid" 2>/dev/null; sleep 3
  for p in $(pgrep -f "ffre-cmp/$TAG/cmux DEV $TAG.app"); do kill "$p"; done
  p=$(pgrep -f "session cmux-app-$TAG "); [ -n "$p" ] && kill "$p"
  sleep 1
}

# 0 when every summary in the output counts as many ok runs as runs.
all_ok() {
  python3 -c '
import json, sys
sums = [json.loads(l)["summary"] for l in sys.stdin if l.startswith("{\"summary\"")]
flat = [v for s in sums for v in (s.values() if all(isinstance(v, dict) for v in s.values()) else [s])]
sys.exit(0 if flat and all(v["ok"] == v["runs"] for v in flat) else 1)'
}

status=0
for proof in $PROOFS; do
  case $proof in
    split|newterm) out=$(run_one python3 typeahead-compare.py "$ROUNDS" "$proof" -- "$TAG") ;;
    split-slowhost) out=$(CMUX_TUI_TEST_HOST_READY_DELAY_MS=400 run_one python3 typeahead-compare.py "$ROUNDS" split -- "$TAG") ;;
    newtab-hello) out=$(run_one python3 new-tab-typeahead-proof.py "$TAG" "$ROUNDS" hello) ;;
    newtab-chrome) out=$(run_one python3 new-tab-typeahead-proof.py "$TAG" "$ROUNDS" chrome://extensions 300) ;;
    cold)
      out=$(bash new-tab-cold-proof.sh "$TAG" "$TAG" "$ROUNDS" 2>/dev/null | grep cold_field)
      ok=$(grep -c '"ok": true' <<<"$out")
      echo "cold: ok $ok of $ROUNDS"
      grep '"ok": false' <<<"$out" | cut -c1-200 | sed 's/^/cold-bad: /'
      [ "$ok" = "$ROUNDS" ] || status=1
      continue ;;
    *) echo "typeahead-gate: unknown proof $proof" >&2; status=2; continue ;;
  esac
  grep -E '"summary"|"ok": false' <<<"$out" | cut -c1-600 | sed "s/^/$proof: /"
  all_ok <<<"$out" || status=1
done
uptime
rm -rf "${ROOT:?}/$TAG" "/tmp/$TAG.zip"
exit $status
