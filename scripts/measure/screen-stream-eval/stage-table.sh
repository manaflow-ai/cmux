#!/usr/bin/env bash
# The stage ledger (cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py `run --legs`) on a fleet Mac pair, as the
# two halves of one screen-stream-eval.sh pair job (README.md, "Stage table on two Macs"). screen-stream-eval.sh runs
# it after its grant check, inside CmuxScreenEvalLauncher.app when the step's own processes hold no grants, so the
# rig on the host and observe on the viewer get the launcher's Screen Recording and Accessibility.
#   stage-table.sh host LAN_IP TOKEN_FILE OUT          the shared Mac: serve the viewer's commands (peer-serve)
#   stage-table.sh viewer HOST_IP TOKEN_FILE OUT LEGS  the viewing Mac: build the tools, run every leg, print the table
# The viewer half drives the host over the LAN (screen-share-vs.py --via peer): each command is one HTTP POST that
# carries the run's token, to the host half's server on HOST_IP:4181, which takes the first private-address client
# that holds the token and that one only, and ends at the viewer's /done or after 2 h. Apple's presented Total
# (--apple-viewer) logs in with the fleet login the worker wrote for a vnc-login step (CMUX_CI_VNC_LOGIN_FILE), else
# with the fleet password in the viewer's login keychain (manaflow-fleet-sudo, as fleet-sudo --login-keychain stores it).
set -uo pipefail
role="$1" addr="$2" token_file="$3" out="$4" legs="${5:-}"
root="$EVAL_ROOT"
vs="$root/cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py"
port=4181
mkdir -p "$out"

if [[ "$role" == host ]]; then
  echo "SCREEN-STREAM-EVAL-STAGE stage-table host serving $addr:$port"
  python3 -I "$vs" peer-serve --bind "$addr" --port "$port" --token-file "$token_file" --hold-s 7200
  exit $?
fi

[[ "$role" == viewer ]] || { echo "stage-table.sh: host or viewer" >&2; exit 2; }
[[ "$legs" =~ ^[a-z0-9=-]+(,[a-z0-9=-]+)*$ ]] || { echo "stage-table.sh: legs are LINK or LINK=PROFILE, comma-separated" >&2; exit 2; }
login="${CMUX_CI_VNC_LOGIN_FILE:-}"
if [[ -z "$login" || ! -f "$login" ]]; then
  # No vnc-login step (the controller has no fleet login source): the fleet password this Mac's login keychain holds
  # (`fleet-sudo --login-keychain HOST` stores it as manaflow-fleet-sudo; the fleet Macs share one), in a 0600 file
  # under this step's output that is removed when the step ends. Never argv, environment or logs.
  login=""
  if pw=$(security find-generic-password -s manaflow-fleet-sudo -w 2>/dev/null) && [[ -n "$pw" && "$pw" != *$'\n'* ]]; then
    login=$(umask 077 && mktemp "$out/.vnc-login.XXXXXX") && printf '%s\n' "$pw" >"$login" || login=""
    trap 'rm -f "$login"' EXIT
    echo "SCREEN-STREAM-EVAL-STAGE stage-table: vnc login from this Mac's keychain (manaflow-fleet-sudo)"
  fi
  unset pw
  [[ -n "$login" ]] || echo "SCREEN-STREAM-EVAL-STAGE stage-table: no vnc login file (CMUX_CI_VNC_LOGIN_FILE) and no manaflow-fleet-sudo in this Mac's keychain (fleet-sudo --login-keychain HOST): Apple's legs fail"
fi

# The tools at this commit, as screen-stream-eval.sh tools-only=1 builds them (screen-share-vs.py --tools).
echo "SCREEN-STREAM-EVAL-STAGE stage-table tools"
tools="$EVAL_BIN"
for tool in preflight scene ocr window-id marker-locate; do
  [[ -x "$tools/screen-eval-$tool" ]] || swiftc -O -o "$tools/screen-eval-$tool" "$root/scripts/measure/screen-stream-eval/$tool.swift" || exit 4
done
[[ -x "$tools/cmux-rd-marker" ]] || swiftc -O -o "$tools/cmux-rd-marker" "$root/cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift" || exit 4
bash "$root/scripts/measure/screen-stream-eval/targets/rd.sh" build >"$out/rd-build.log" 2>&1 || { tail -40 "$out/rd-build.log"; exit 4; }
git -C "$root" rev-parse HEAD >"$tools/rev"

# The host half starts with its step; wait for its server (30 min, as peer.py's agent does).
url="http://$addr:$port"
self_ip=$(python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect((sys.argv[1], 9)); print(s.getsockname()[0])' "$addr") || exit 4
host_name=""
for _ in $(seq 1 360); do
  host_name=$(python3 -I - "$url" "$token_file" <<'PY' 2>/dev/null
import json, sys, urllib.request
token = open(sys.argv[2]).read().strip()
req = urllib.request.Request(sys.argv[1] + "/run", method="POST", headers={"X-Eval-Token": token},
                             data=json.dumps({"cmd": "scutil --get LocalHostName", "timeout": 10}).encode())
res = json.loads(urllib.request.urlopen(req, timeout=10).read())
print(res["out"].strip() if res.get("rc") == 0 else "")
PY
  ) && [[ -n "$host_name" ]] && break
  sleep 5
done
[[ -n "$host_name" ]] || { echo "SCREEN-STREAM-EVAL-ERROR stage-table: the host half never answered at $url"; exit 4; }
viewer_name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
echo "SCREEN-STREAM-EVAL-STAGE stage-table $host_name ($addr) -> $viewer_name ($self_ip), legs $legs"

python3 -I "$vs" run --host "$host_name" --viewer "$viewer_name" --local-mac "$viewer_name" --via peer \
  --peer-url "$url" --peer-token-file "$token_file" --host-ip "$addr" --viewer-ip "$self_ip" \
  --tools "$tools" --legs "$legs" --apple-viewer --vnc-user cmux --vnc-password-file "${login:-/nonexistent}" \
  --out "$out/ledger.jsonl" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
python3 -I "$vs" table "$out/ledger.jsonl" | tee "$out/table.txt"
# The host half ends now, not at its 2 h hold.
python3 -I - "$url" "$token_file" <<'PY' || true
import sys, urllib.request
token = open(sys.argv[2]).read().strip()
urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/done", data=b"{}", method="POST",
                                              headers={"X-Eval-Token": token}), timeout=10).close()
PY
exit "$status"
