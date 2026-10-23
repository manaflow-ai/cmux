#!/usr/bin/env bash
# Fleet wrapper (pl-sweep-b6 only): every-action-sweep.py plus the action signpost stream and wall-clock stamped log.
set -u
A="${NX_ARTIFACTS:-artifacts/nx}"; mkdir -p "$A"
/usr/bin/log stream --signpost --style ndjson --predicate 'subsystem == "com.cmuxterm.app.next" AND category == "action"' > "$A/signposts.ndjson" 2>"$A/logstream.err" &
LP=$!
python3 -u scripts/cmux-next/every-action-sweep.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$A/sweep" "$@" 2>&1 \
  | python3 -u -c 'import sys,time
for l in sys.stdin: print("%.6f %s" % (time.time(), l), end="", flush=True)' | tee "$A/sweep.log"
RC=${PIPESTATUS[0]}
kill -INT $LP; wait $LP 2>/dev/null
sw_vers > "$A/sw_vers.txt"; system_profiler SPDisplaysDataType 2>/dev/null | grep -iE "resolution|refresh|Hz" > "$A/display.txt"
exit $RC
