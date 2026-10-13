#!/usr/bin/env bash
# Free tier end to end on a real Mac (cx-ds09i T1/T2): a Developer ID signed
# cmux NEXT Debug build, started by LaunchServices in the GUI session, proves
# the Mac with App Attest through its attest_provider connection, and the
# local relay serves a signed-out agent request with the device token from the
# cmux API at <origin>. Real app, real relay, real API; no screenshot.
#
#   free-tier-attest-e2e.sh <signed-app.zip> <api-origin> <out-dir>
#
# Writes <out-dir>/result.json (statuses, states and error codes only: never a
# token, a proof or a device token). Everything it starts is stopped by the
# pid or the socket it started, and its files are removed at the end, the
# app's keychain item for the free-tier key included.
set -uo pipefail
zip="$1"; origin="$2"; out="$3"
mkdir -p "$out"
root="$(mktemp -d /tmp/hq39ft.XXXXXX)"
home="$root/a"
daemon_pid=""
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null; fi
  if [[ -n "$daemon_pid" ]]; then
    ACPMUX_HOME="$home" ACPMUX_SOCKET="$home/s.sock" "$acpmux" daemon shutdown >/dev/null 2>&1 || kill "$daemon_pid" 2>/dev/null
  fi
  if [[ -n "${bundle_id:-}" ]]; then
    security delete-generic-password -s "com.cmuxterm.next.free-tier.app-attest.$bundle_id" -a key >/dev/null 2>&1
  fi
  rm -rf "$root"
}
trap cleanup EXIT

sw_vers > "$out/host.txt"; sysctl -n hw.model kern.hv_vmm_present >> "$out/host.txt" 2>&1
/usr/bin/ditto -x -k "$zip" "$root/app"
app="$(find "$root/app" -maxdepth 2 -type d -name '*.app' -print -quit)"
acpmux="$app/Contents/Resources/bin/acpmux"
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
codesign --verify --deep --strict "$app" && echo "signature ok" >> "$out/host.txt"
codesign -dv "$app" 2>&1 | grep -E '^(Identifier|TeamIdentifier)=' >> "$out/host.txt"

# The daemon the app's agent pane would start (same binary, same env), with
# its local relay; a job-local home so nothing of the host's own is touched.
mkdir -p "$home"
exec 3< <(ACPMUX_HOME="$home" ACPMUX_SOCKET="$home/s.sock" ACPMUX_LOCAL_ROUTER=1 \
  "$acpmux" daemon run --listen 127.0.0.1:0 --ready-fd 1 --log warn 2>"$out/daemon.err" & echo "pid $!"; wait)
read -r _ daemon_pid <&3
read -r -t 60 ready <&3 || ready=""
echo "daemon: $ready" >> "$out/host.txt"

# LaunchServices start in the GUI session (App Attest needs it), pointed at the API.
open -n --env ACPMUX_HOME="$home" --env ACPMUX_SOCKET="$home/s.sock" \
  --env CMUX_NEXT_FEED_API_URL="$origin" "$app"
app_pid="$(lsappinfo info -only pid "$(lsappinfo find bundlepath="$app" | head -n 1)" 2>/dev/null | sed -E 's/.*=//')"

python3 -I - "$home/router/router.sock" "$out/result.json" <<'PY'
import json, socket, sys, time, http.client
sock_path, result_path = sys.argv[1], sys.argv[2]
result = {"steps": []}

def admin(request):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(sock_path)
    s.sendall((json.dumps(request) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data or b"null")

# The relay and the app's provider: bounded wait for the registration.
deadline = time.time() + 120
status = None
while time.time() < deadline:
    try:
        status = admin({"op": "status"})
        if status.get("free", {}).get("provider"):
            break
    except OSError:
        pass
    time.sleep(1)
result["provider_registered"] = bool(status and status.get("free", {}).get("provider"))
result["state_before"] = (status or {}).get("free", {}).get("state")
if result["provider_registered"]:
    port = status["port"]
    scope = {"harness": "e2e", "session": "e2e", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0}
    key = admin({"op": "mint_key", "scope": scope})["key"]

    def call(method, path, body=None):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        headers = {"authorization": "Bearer " + key, "host": "127.0.0.1:%d" % port}
        if body is not None:
            headers["content-type"] = "application/json"
        c.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        r = c.getresponse()
        text = r.read().decode("utf-8", "replace")
        try:
            payload = json.loads(text)
        except ValueError:
            payload = {}
        return r.status, payload

    # The first signed-out request starts the lease.
    code, models = call("GET", "/v1/models")
    free = [m["id"] for m in models.get("data", []) if m.get("free")]
    result["steps"].append({"step": "models", "status": code, "free_models": free,
                            "error": (models.get("error") or {}).get("code")})
    if free:
        code, reply = call("POST", "/v1/chat/completions",
                           {"model": free[0], "max_tokens": 16, "messages": [{"role": "user", "content": "Say ok."}]})
        result["steps"].append({"step": "chat", "status": code, "error": (reply.get("error") or {}).get("code"),
                                "has_choice": bool(reply.get("choices"))})
    after = admin({"op": "status"})
    result["state_after"] = after.get("free", {}).get("state")
    result["status_has_no_token"] = "eyJ" not in json.dumps(after)
json.dump(result, open(result_path, "w"), indent=1)
print(json.dumps(result, indent=1))
PY
