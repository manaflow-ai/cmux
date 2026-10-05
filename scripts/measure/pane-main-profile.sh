#!/usr/bin/env bash
# One Instruments time profile of the agent pane's 20 MB prompt bench
# (AgentPaneTransportBenchParse/aTwentyMegabytePromptOnTheMainThread): prints the heaviest
# main-thread frames of the test process (self and inclusive). Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/pane-main-profile.sh --ref SHA
set -euo pipefail
work="$(mktemp -d)"
lane_log="$work/lane.log"
# Builds the tests (and picks the Xcode); also runs the parse bench once.
CMUX_PANE_TRANSPORT_BENCH=1 ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext AgentPaneTransportBenchParse \
  2>&1 | tee "$lane_log"
DEVELOPER_DIR="$(sed -n 's/^Xcode: //p' "$lane_log" | tail -n 1)"
export DEVELOPER_DIR
trace="$work/prompt.trace"
xcrun xctrace record --template 'Time Profiler' --all-processes --time-limit 180s --output "$trace" --no-prompt &
recorder=$!
sleep 5 # let the recorder start (a measurement script, not runtime code)
CMUX_PANE_TRANSPORT_BENCH=1 swift test --package-path Packages/macOS/CmuxNext --skip-build \
  --filter aTwentyMegabytePromptOnTheMainThread 2>&1 | grep -E "PANE-MAIN|passed|failed" || true
kill -INT "$recorder"
wait "$recorder" || true
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$work/tp.xml"
python3 - "$work/tp.xml" <<'PY'
import sys, collections, xml.etree.ElementTree as ET
byid = {}
selfw = collections.Counter(); incl = collections.Counter(); total = 0
def resolve(e):
    r = e.get("ref")
    return byid.get(r, e) if r else e
for event, e in ET.iterparse(sys.argv[1], events=("end",)):
    if e.get("id"): byid[e.get("id")] = e
    if e.tag != "row": continue
    thread = resolve(e.find("thread")) if e.find("thread") is not None else None
    tfmt = thread.get("fmt", "") if thread is not None else ""
    if "Main Thread" not in tfmt or not any(p in tfmt for p in ("swiftpm-testing-helper", "CmuxNextPackageTests", "xctest")):
        continue
    w = e.find("weight"); w = resolve(w) if w is not None else None
    weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1000000
    bt = e.find("backtrace"); bt = resolve(bt) if bt is not None else None
    if bt is None: continue
    names = [resolve(f).get("name", "?") for f in bt.findall("frame")]
    if not names: continue
    total += weight
    selfw[names[0]] += weight
    for n in set(names): incl[n] += weight
print(f"PANE-PROFILE main-thread samples total_ms={total/1e6:.1f}")
for n, w in selfw.most_common(25): print(f"PANE-PROFILE self {w/1e6:8.1f} ms  {n[:160]}")
for n, w in incl.most_common(40): print(f"PANE-PROFILE incl {w/1e6:8.1f} ms  {n[:160]}")
PY
