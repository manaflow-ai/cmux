# Functional smoke test on a Linux build box (not a measurement host).
set -u
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$HOME/rdhost-target}
cargo build --release ${FEATURES:-} 2>&1 | grep -E '^(warning|error)' -A5 | head -40
B=$CARGO_TARGET_DIR/release/rdhost
which Xvfb >/dev/null || sudo apt-get install -y xvfb >/tmp/xvfb.log 2>&1
if [ "${RESTART:-1}" = 1 ]; then
  pkill -x Xvfb; pkill -f 'rdhost serve'; sleep 0.5
  (Xvfb :99 -screen 0 ${SCREEN:-1920x1080}x24 -nolisten tcp >/tmp/xvfb.out 2>&1 &)
  for i in $(seq 1 50); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
  ($B serve --display :99 --port 7400 --log-dir /tmp/rdlogs ${SERVE_ARGS:-} >/tmp/serve.log 2>&1 &)
  for i in $(seq 1 50); do ss -ltn | grep -q ':7400 ' && break; sleep 0.1; done
fi
for w in ${WORKLOADS:-marker}; do
  $B client --addr 127.0.0.1:7400 --workload $w --samples ${N:-30} --capture ${CAP:-damage} --idle-secs ${IDLE:-5} --out /tmp/c-$w.json; echo "exit $?"
  python3 - "$w" <<'PY'
import json,sys
d=json.load(open('/tmp/c-%s.json'%sys.argv[1]))
g=d['g2g_ms'] or {}
v=d['video']; h=d['host']
f=lambda s:(s or {}).get('p50')
print(sys.argv[1], 'n',d['samples'],'loss',d['losses'],'g2g p50/p95/max',g.get('p50'),g.get('p95'),g.get('max'),
 '| kbps %.0f fps %.1f key %d nosps %d decerr %d'%(v['kbit_per_s'],v['frames_per_s'],v['keyframes_total'],v['idr_without_sps'],v['decode_errors']),
 '| dec',f(d['decode_ms']),'| host cpu',f(h['cpu_pct_process']),'sys',f(h['cpu_pct_system']),'cap',f(h['capture_ms_p50']),'conv',f(h['convert_ms_p50']),'enc',f(h['encode_ms_p50']),'d2s',f(h['damage_to_send_ms_p50']),'i2d',f(h['inject_to_damage_ms_p50']))
PY
done
tail -3 /tmp/serve.log
