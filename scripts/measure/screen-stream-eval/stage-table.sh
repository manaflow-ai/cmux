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
# (--apple-viewer) logs in with the fleet login the worker wrote for a vnc-login step (CMUX_CI_VNC_LOGIN_FILE).
# cmux's Present and Total cells (Leo, 2026-11-16: "we should be able to like pin down at each step like what is
# actually bottlenecking us") come from a DEV cmux NEXT app built at this commit on each Mac (reload.sh --tag, as
# chat-open.sh builds one): the viewer's is --app-viewer, the host's (the sharing app that approves the hub session)
# is --app-host-app. The host app is started as a child of this step, so it inherits the launcher's Screen Recording;
# it publishes its path through the peer server under /tmp/cmux-stage-table-<token hash>.host-app. Both apps sign in
# to the device hub with CMUX_STAGE_TABLE_AUTH_FILE (default: the Mac's ~/rd-hub-rig/private/creds.env, the Mac Screen
# rig's agent test-account file). Without that file, or when an app build or launch fails, the run keeps Apple's leg
# and the cmux rows end at decode, and a SCREEN-STREAM-EVAL-STAGE line says why.
set -uo pipefail
role="$1" addr="$2" token_file="$3" out="$4" legs="${5:-}"
root="$EVAL_ROOT"
vs="$root/cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py"
port=4181
mkdir -p "$out"

# A DEV app at this commit: its path on stdout, the build's log in $out/app-build-ROLE.log.
build_app() {
  local tag="stagetable" app
  git -C "$root" submodule update --init --depth 1 ghostty ghostty-next >"$out/app-build-$1.log" 2>&1 || return 1
  (cd "$root" && CMUX_NEXT_REQUIRE_CEF=0 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag") >>"$out/app-build-$1.log" 2>&1 || return 1
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/app-build-$1.log" | tail -n 1)"
  [[ -n "$app" && -d "$app" ]] || return 1
  printf '%s\n' "$app"
}
# The hub sign-in file of this Mac, or nothing.
auth_file() {
  local f="${CMUX_STAGE_TABLE_AUTH_FILE:-}" home
  if [[ -z "$f" ]]; then
    home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
    f="$home/rd-hub-rig/private/creds.env"
  fi
  [[ -f "$f" ]] && printf '%s\n' "$f"
}
# Where the host half tells the viewer half its app (the peer server runs `cat`): per run, by the token.
host_app_file="/tmp/cmux-stage-table-$(shasum -a 256 "$token_file" | cut -c1-16).host-app"

if [[ "$role" == host ]]; then
  echo "SCREEN-STREAM-EVAL-STAGE stage-table host serving $addr:$port"
  rm -f "$host_app_file"
  python3 -I "$vs" peer-serve --bind "$addr" --port "$port" --token-file "$token_file" --hold-s 7200 &
  serve=$!
  app_pid=""
  trap '[[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null; rm -f "$host_app_file"' EXIT
  # The sharing app, while the viewer builds its own: a one-word answer in the file either way ("none" = no app).
  host_app="none" why=""
  creds=$(auth_file) || creds=""
  if [[ -z "$creds" ]]; then
    why="no hub sign-in file (CMUX_STAGE_TABLE_AUTH_FILE, ~/rd-hub-rig/private/creds.env)"
  elif ! app=$(build_app host); then
    why="the app build failed: $(tail -n 5 "$out/app-build-host.log" | tr '\n' ' ' | cut -c1-300)"
  else
    printf '{}' >"$out/host-app-cmux.json"
    exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
    # A direct child, not `open`: the app then shares this process's Screen Recording grant.
    CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation CMUX_AUTH_CREDENTIALS_FILE="$creds" \
      CMUX_NEXT_CONFIG_FILE="$out/host-app-cmux.json" CMUX_NEXT_TEST_WINDOW_FRAME="1300,80,600,500" \
      "$app/Contents/MacOS/$exe" >"$out/host-app.log" 2>&1 &
    app_pid=$!
    ready=0
    for _ in $(seq 1 60); do
      st=$(python3 -I "$vs" app rpc debug.device_hub '{"action":"state"}' --app "$app" 2>/dev/null | tail -n 1)
      if python3 -I -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("signed_in") else 1)' "$st" 2>/dev/null; then ready=1; break; fi
      sleep 2
    done
    if [[ "$ready" == 1 ]]; then
      python3 -I "$vs" app rpc debug.device_hub '{"action":"set_shared","shared":true}' --app "$app" >"$out/host-app-share.json" 2>&1
      host_app="$app"
    else
      why="the host app never signed in to the hub (host-app.log)"
    fi
  fi
  [[ "$host_app" == none ]] && echo "SCREEN-STREAM-EVAL-STAGE stage-table host: no sharing app, cmux Present and Total end at decode: $why"
  [[ "$host_app" != none ]] && echo "SCREEN-STREAM-EVAL-STAGE stage-table host: sharing app $host_app (pid $app_pid)"
  printf '%s\n' "$host_app" >"$host_app_file.tmp" && mv "$host_app_file.tmp" "$host_app_file"
  wait "$serve"
  exit $?
fi

[[ "$role" == viewer ]] || { echo "stage-table.sh: host or viewer" >&2; exit 2; }
[[ "$legs" =~ ^[a-z0-9=-]+(,[a-z0-9=-]+)*$ ]] || { echo "stage-table.sh: legs are LINK or LINK=PROFILE, comma-separated" >&2; exit 2; }
login="${CMUX_CI_VNC_LOGIN_FILE:-}"
[[ -n "$login" && -f "$login" ]] || echo "SCREEN-STREAM-EVAL-STAGE stage-table: no vnc login file (CMUX_CI_VNC_LOGIN_FILE): Apple's legs fail"

# The tools at this commit, as screen-stream-eval.sh tools-only=1 builds them (screen-share-vs.py --tools).
echo "SCREEN-STREAM-EVAL-STAGE stage-table tools"
tools="$EVAL_BIN"
for tool in preflight scene ocr window-id marker-locate; do
  [[ -x "$tools/screen-eval-$tool" ]] || swiftc -O -o "$tools/screen-eval-$tool" "$root/scripts/measure/screen-stream-eval/$tool.swift" || exit 4
done
[[ -x "$tools/cmux-rd-marker" ]] || swiftc -O -o "$tools/cmux-rd-marker" "$root/cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift" || exit 4
bash "$root/scripts/measure/screen-stream-eval/targets/rd.sh" build >"$out/rd-build.log" 2>&1 || { tail -40 "$out/rd-build.log"; exit 4; }
git -C "$root" rev-parse HEAD >"$tools/rev"
# This Mac's DEV app (while the host half builds its own).
creds=$(auth_file) || creds=""
viewer_app="" app_why=""
if [[ -z "$creds" ]]; then app_why="no hub sign-in file here (CMUX_STAGE_TABLE_AUTH_FILE, ~/rd-hub-rig/private/creds.env)"
elif ! viewer_app=$(build_app viewer); then app_why="the viewer app build failed: $(tail -n 5 "$out/app-build-viewer.log" | tr '\n' ' ' | cut -c1-300)"; fi

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
# The sharing app on the host (its half builds it while this one built the tools): up to 30 more minutes.
app_args=()
host_app=""
[[ -z "$app_why" ]] && for _ in $(seq 1 360); do
  host_app=$(python3 -I - "$url" "$token_file" "$host_app_file" <<'PY' 2>/dev/null
import json, sys, urllib.request
token = open(sys.argv[2]).read().strip()
req = urllib.request.Request(sys.argv[1] + "/run", method="POST", headers={"X-Eval-Token": token},
                             data=json.dumps({"cmd": "cat " + sys.argv[3], "timeout": 10}).encode())
res = json.loads(urllib.request.urlopen(req, timeout=10).read())
print(res["out"].strip() if res.get("rc") == 0 else "")
PY
  ) && [[ -n "$host_app" ]] && break
  sleep 5
done
if [[ -n "$app_why" ]]; then :
elif [[ -z "$host_app" ]]; then app_why="the host half never published its app"
elif [[ "$host_app" == none ]]; then app_why="the host half has no sharing app (see its log)"
else app_args=(--app-viewer "$viewer_app" --app-viewer-env "CMUX_AUTH_CREDENTIALS_FILE=$creds" --app-host-app "$host_app"); fi
[[ -n "$app_why" ]] && echo "SCREEN-STREAM-EVAL-STAGE stage-table: no app viewer, cmux Present and Total end at decode: $app_why"
viewer_name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
echo "SCREEN-STREAM-EVAL-STAGE stage-table $host_name ($addr) -> $viewer_name ($self_ip), legs $legs"

python3 -I "$vs" run --host "$host_name" --viewer "$viewer_name" --local-mac "$viewer_name" --via peer \
  --peer-url "$url" --peer-token-file "$token_file" --host-ip "$addr" --viewer-ip "$self_ip" \
  --tools "$tools" --legs "$legs" --apple-viewer ${app_args[@]+"${app_args[@]}"} --vnc-user cmux --vnc-password-file "${login:-/nonexistent}" \
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
