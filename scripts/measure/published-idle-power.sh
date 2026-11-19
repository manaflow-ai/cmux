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
python3 - "$bundle" "$pid" "$label" "$seconds" "$out" <<'PY'
import datetime
import json
import os
import plistlib
import subprocess
import sys
sys.path.insert(0, os.path.abspath('scripts/cmux-next'))
import bench_memory as bm
import bench_power as bp

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
capture = subprocess.run(['screencapture', '-x', os.path.join(out, 'screen.png')], capture_output=True, text=True)
start = utc()
print('IDLE-WINDOW ' + json.dumps({'start': start, 'label': label, 'pid': pid, 'seconds': seconds}), flush=True)
top = subprocess.Popen(['top', '-l', '2', '-s', str(seconds), '-pid', str(pid), '-stats', 'pid,cpu,power,command'],
                       stdout=open(os.path.join(out, 'top.txt'), 'w'), stderr=subprocess.STDOUT)
result = bp.measure(pid, bundle, label, seconds)
result.update(start=start, end=utc(), bundle=bundle, pid=pid,
              version=info.get('CFBundleShortVersionString'), bundle_id=info.get('CFBundleIdentifier'),
              members_before=owned, members_after=bm.owned(pid, bundle),
              capture_status=capture.returncode, capture_error=capture.stderr)
result['existing_daemons'] = [{'pid': p, 'command': cmd, 'before': first, 'after': bp.counters(p)}
                              for p, (cmd, first) in baseline.items()]
top.wait(timeout=20)
with open(os.path.join(out, 'report.json'), 'w') as f:
    json.dump(result, f, indent=2)
print('IDLE-RESULT ' + json.dumps(result), flush=True)
PY
tar -czf "artifacts/published-idle-$label.tgz" -C "$out" .
