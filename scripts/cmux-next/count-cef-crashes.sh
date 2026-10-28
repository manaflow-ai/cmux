#!/usr/bin/env bash
# Counts the app's crash reports on the perf minis by kind and build, since a time (P0 #1 and the parent-tracker
# abort, handoff/cef-snapshot-crash-result.md). Read-only: ssh + grep over ~/Library/Logs/DiagnosticReports.
#
#   scripts/cmux-next/count-cef-crashes.sh SINCE [HOSTS...]
#     SINCE   a UTC time, e.g. 2026-10-28T12:00:00Z (reports written at or after it)
#     HOSTS   default: cmux17 cmux18 cmux19 cmux21 cmux22 cmux23 cmux24 (never cmux16)
#
# Prints one row per report (host, file, kind, app bundle, CEF image UUID) and a total per kind, app and CEF UUID.
# Kinds: snapshot (OnSnapshotFromSurfaceReceived), tracker (CmuxParentViewTracker), other.
# CEF UUIDs: 4C4C4413-... = cef-stage-c8953bc613cd (no fix); 4C4C448F-... = cef-stage-e110f7a37c80 (snapshot fix).
set -euo pipefail
since=${1:?usage: count-cef-crashes.sh SINCE [HOSTS...]}
shift || true
hosts=("$@"); [ ${#hosts[@]} -gt 0 ] || hosts=(cmux17 cmux18 cmux19 cmux21 cmux22 cmux23 cmux24)
epoch=$(date -u -d "$since" +%s)
remote='cd ~/Library/Logs/DiagnosticReports 2>/dev/null || exit 0
for f in cmux*.ips; do
  [ -e "$f" ] || continue
  [ "$(stat -f %m "$f")" -ge '"$epoch"' ] || continue
  kind=other
  grep -q OnSnapshotFromSurfaceReceived "$f" && kind=snapshot
  grep -q CmuxParentViewTracker "$f" && kind=tracker
  app=$(grep -o "cmux DEV [^/\"]*\.app" "$f" | head -1 | tr " " "_")
  cef=$(/usr/bin/python3 -I -c "import json,sys
t=open(sys.argv[1]).read().split(chr(10),1)[1]
b=json.loads(t)
print(next((i[\"uuid\"].upper() for i in b.get(\"usedImages\",[]) if i.get(\"name\")==\"Chromium Embedded Framework\"),\"none\"))" "$f" 2>/dev/null || echo unreadable)
  echo "$(hostname -s) ${f// /_} $kind ${app:-unknown} $cef"
done'
rows=$(for h in "${hosts[@]}"; do [ "$h" = cmux16 ] && continue; timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" "$remote" 2>/dev/null || echo "$h - unreachable - -"; done)
echo "$rows"
echo "--- totals since $since (kind, app, CEF UUID: count)"
echo "$rows" | awk 'NF==5 && $3!="unreachable" {c[$3" "$4" "$5]++} END {for (k in c) print c[k], k}' | sort -rn
