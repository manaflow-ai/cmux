#!/usr/bin/env bash
# Diagnostic (side branch pl-openpanel-probe, not for landing): one Time Profiler trace and one `sample` of the
# open-panel bench (made and window modes, light session) to find what holds main in beginSheetModal.
#   cmux-ci run --class exclusive --measurement --label bench --target-worker cmux20-bench \
#     --script scripts/measure/open-panel-profile.sh --ref SHA --urgent --reason "..."
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
bash scripts/measure/split-spring.sh --build-only 2>&1 | tail -n 5
trace="$work/openpanel.trace"
xcrun xctrace record --template 'Time Profiler' --all-processes --time-limit 300s --output "$trace" --no-prompt \
  > "$work/xctrace.log" 2>&1 &
recorder=$!
sleep 5 # let the recorder start (a measurement script, not runtime code)
status=0
OPEN_PANEL_SAMPLE=6 bash scripts/measure/split-spring.sh --app-cache --vdisplay=120 --suite=open-panel \
  --sessions=light --modes=made,window --rounds=6 || status=$?
kill -INT "$recorder" 2>/dev/null || true
wait "$recorder" || true
tail -n 5 "$work/xctrace.log" || true
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$work/tp.xml" || true
python3 - "$work/tp.xml" <<'PY' || true
import sys, collections, xml.etree.ElementTree as ET
byid = {}
selfw = collections.Counter(); incl = collections.Counter(); total = 0
other = collections.Counter()
def resolve(e):
    r = e.get("ref")
    return byid.get(r, e) if r else e
for event, e in ET.iterparse(sys.argv[1], events=("end",)):
    if e.get("id"): byid[e.get("id")] = e
    if e.tag != "row": continue
    thread = resolve(e.find("thread")) if e.find("thread") is not None else None
    tfmt = thread.get("fmt", "") if thread is not None else ""
    w = e.find("weight"); w = resolve(w) if w is not None else None
    weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1000000
    if "split-spring" not in tfmt:
        proc = tfmt.split("(")[0] if tfmt else "?"
        other[tfmt.split(" ")[-1] if False else tfmt[:60]] += weight
        continue
    if "Main Thread" not in tfmt:
        continue
    bt = e.find("backtrace"); bt = resolve(bt) if bt is not None else None
    if bt is None: continue
    names = [resolve(f).get("name", "?") for f in bt.findall("frame")]
    if not names: continue
    total += weight
    selfw[names[0]] += weight
    for n in set(names): incl[n] += weight
print(f"OP-PROFILE main-thread samples total_ms={total/1e6:.1f}")
for n, w in selfw.most_common(30): print(f"OP-PROFILE self {w/1e6:8.1f} ms  {n[:160]}")
for n, w in incl.most_common(80): print(f"OP-PROFILE incl {w/1e6:8.1f} ms  {n[:160]}")
for n, w in other.most_common(15): print(f"OP-PROFILE otherthread {w/1e6:8.1f} ms  {n}")
PY
exit "$status"
