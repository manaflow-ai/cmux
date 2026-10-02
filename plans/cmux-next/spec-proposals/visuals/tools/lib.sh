export CMUX_QUIET=1
R=/tmp/specvis/rpc.sh
IMG=/tmp/specvis/images
hover(){ $R rpc debug.mouse "{\"action\":\"hover\",\"x\":$1,\"y\":$2}" >/dev/null; sleep ${3:-0.35}; }
mouse(){ $R rpc debug.mouse "{\"action\":\"$1\",\"x\":$2,\"y\":$3}" >/dev/null; sleep 0.3; }
shot(){ mkdir -p "$IMG/$(dirname $1)"; /tmp/specvis/venv/bin/python /tmp/specvis/shot.py "$IMG/$1.png" "${@:2}" >/dev/null; echo "shot $1"; }
tun(){ $R rpc debug.tunables "{\"action\":\"set\",\"key\":\"$1\",\"value\":$2}" >/dev/null; sleep 0.5; }
tunreset(){ $R rpc debug.tunables "{\"action\":\"reset\",\"key\":\"$1\"}" >/dev/null; sleep 0.5; }
appearance(){ $R rpc debug.appearance "{\"mode\":\"$1\"}" >/dev/null; sleep 1.2; }
cfg(){ echo "$1" > /tmp/specvis/cfg/cmux.json; $R reload-config >/dev/null 2>&1; sleep 1.2; }
away(){ hover 640 400 0.3; }
