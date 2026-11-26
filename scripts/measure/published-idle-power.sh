#!/usr/bin/env bash
# Observe an already launched public app; never build, launch, or end it.
# Run through cmux-ci run --class exclusive --measurement --display.
# Arguments: bundle=/absolute/App.app pid=N label=NAME seconds=60
set -euo pipefail
bundle= pid= label= seconds=60
for arg in "$@"; do
  case "$arg" in
    bundle=*) bundle="${arg#bundle=}" ;;
    pid=*) pid="${arg#pid=}" ;;
    label=*) label="${arg#label=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$bundle" = /*.app && "$pid" =~ ^[1-9][0-9]*$ && "$label" =~ ^[a-z0-9-]+$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || exit 2
(( seconds <= 180 )) || exit 2
cd "$(git rev-parse --show-toplevel)"
mkdir -p artifacts
out="$(mktemp -d "$PWD/artifacts/published-idle.XXXXXX")"
# Pack whatever the run wrote (a failed run's partial report too), then always remove the scratch folder.
trap 'tar -czf "artifacts/published-idle-$label.tgz" -C "$out" . 2>/dev/null || true; rm -rf "$out"' EXIT
python3 - "$bundle" "$pid" "$label" "$seconds" "$out" <<'PY'
import datetime
import json
import os
import plistlib
import platform
import subprocess
import sys
sys.path.insert(0, os.path.abspath('scripts/cmux-next'))
import bench_memory as bm
import bench_power as bp

# This comparison includes payload processes launched outside the app bundle
# (for example agent executables). Keep the shared bundle-only sampler's
# default scope unchanged; expand just this observer to every descendant.
bundle_owned = bm.owned
def observed_owned(app_pid, app_bundle):
    found = dict(bundle_owned(app_pid, app_bundle))
    children = {}
    for child_pid, parent_pid, command in bm.process_table():
        children.setdefault(parent_pid, []).append((child_pid, command))
    stack = list(found)
    while stack:
        for child_pid, command in children.get(stack.pop(), []):
            if child_pid not in found:
                found[child_pid] = (bm.kind_of(command, app_bundle), command)
                stack.append(child_pid)
    return found
bm.owned = observed_owned

bundle, pid, label, seconds, out = sys.argv[1:]
bundle, pid, seconds = os.path.realpath(bundle), int(pid), int(seconds)
with open(os.path.join(bundle, 'Contents/Info.plist'), 'rb') as f:
    info = plistlib.load(f)
owned = bm.owned(pid, bundle)
if pid not in owned:
    raise SystemExit('Target PID is not in the named bundle; no measurement taken')
utc = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
# Root package power is collected independently by the coordinator. Do not invoke sudo.
bp.powermetrics = lambda _: None
baseline = {p: (cmd, bp.counters(p)) for p, _, cmd in bm.process_table()
            if p not in owned and ('/cmux-tui' in cmd or '/.cmux/host-bin/' in cmd)}
first = {p: bp.counters(p) for p in owned}
try:
    capture = subprocess.run(['screencapture', '-x', os.path.join(out, 'screen.png')],
                             capture_output=True, text=True, timeout=20)
    capture_status, capture_error = capture.returncode, capture.stderr
except subprocess.TimeoutExpired:
    capture_status, capture_error = None, 'capture exceeded 20 seconds'
start = utc()
print('IDLE-WINDOW ' + json.dumps({'start': start, 'label': label, 'pid': pid, 'seconds': seconds}), flush=True)
with open(os.path.join(out, 'top.txt'), 'w') as top_output:
    top = subprocess.Popen(['top', '-l', '2', '-s', str(seconds), '-pid', str(pid), '-stats', 'pid,cpu,power,command'],
                           stdout=top_output, stderr=subprocess.STDOUT)
    try:
        result = bp.measure(pid, bundle, label, seconds)
        try:
            top.wait(timeout=20)
        except subprocess.TimeoutExpired:
            pass
    finally:
        if top.poll() is None:
            top.terminate()
            try:
                top.wait(timeout=5)
            except subprocess.TimeoutExpired:
                top.kill()
                top.wait(timeout=5)
after = bm.owned(pid, bundle)
last = {p: bp.counters(p) for p in owned}
measured_count = sum(row['count'] for row in result['kinds'].values())
valid = (set(owned) == set(after) and measured_count == len(owned)
         and all(first[p] is not None and last[p] is not None for p in owned))
result.update(start=start, end=utc(), bundle=bundle, pid=pid,
              host=platform.node().split('.')[0], os=platform.platform(), chip=platform.machine(),
              version=info.get('CFBundleShortVersionString'), bundle_id=info.get('CFBundleIdentifier'),
              members_before=owned, members_after=after, valid=valid, top_status=top.returncode,
              measured_count=measured_count,
              process_scope='bundle-owned processes and all observed descendants',
              validity_scope='stable observed membership and readable endpoint counters; transient processes may be missed',
              capture_status=capture_status, capture_error=capture_error)
result['existing_daemons'] = [{'pid': p, 'command': cmd, 'before': first, 'after': bp.counters(p)}
                              for p, (cmd, first) in baseline.items()]
with open(os.path.join(out, 'report.json'), 'w') as f:
    json.dump(result, f, indent=2)
print('IDLE-RESULT ' + json.dumps(result), flush=True)
if not valid:
    raise SystemExit('Invalid measurement: process membership changed or counters became unreadable')
PY
