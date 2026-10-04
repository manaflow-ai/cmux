#!/usr/bin/env bash
# ensure-cef.sh takes the CEF archive from the controller artifact store (keyed by
# the manifest sha256, tailnet identity, no credential) before R2 and GitHub, and
# keeps only bytes that hash to the manifest. A fake controller on 127.0.0.1 signs
# a URL for the archive; R2 is off and GitHub is unreachable.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$TMP"' EXIT
version=cef-test-store
mkdir -p "$TMP/pkg/$version/Chromium Embedded Framework.framework" "$TMP/pkg/$version/include"
echo engine > "$TMP/pkg/$version/Chromium Embedded Framework.framework/engine"
tar -cJf "$TMP/good.tar.xz" -C "$TMP/pkg" "$version"
echo not-the-engine > "$TMP/bad.tar.xz"
sha=$(shasum -a 256 "$TMP/good.tar.xz" | awk '{print $1}')
cat > "$TMP/manifest.json" <<JSON
{"version": "$version", "repo": "manaflow-ai/cef", "tag": "$version",
 "asset": "$version-macos-arm64.tar.xz", "sha256": "$sha",
 "url": "http://127.0.0.1:9/unreachable.tar.xz"}
JSON
# The fake controller: GET /v1/artifacts/sha256:<sha>/url -> {"url": ".../blob"}; /blob serves $TMP/serve.
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, sys
root, sha = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == f"/v1/artifacts/sha256:{sha}/url":
            if self.headers.get("Authorization"):
                self.send_response(400); self.end_headers(); return
            body = json.dumps({"url": f"http://127.0.0.1:{self.server.server_port}/blob", "sha256": "sha256:" + sha}).encode()
        elif self.path == "/blob":
            body = open(os.path.join(root, "serve"), "rb").read()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
cp "$TMP/good.tar.xz" "$TMP/serve"
python3 "$TMP/server.py" "$TMP" "$sha" & server_pid=$!
for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
port=$(cat "$TMP/port")

run() { # <cache> -> output; status in $status
  status=0
  out=$(env -u GH_TOKEN -u GITHUB_TOKEN PATH=/usr/bin:/bin CMUX_CEF_MANIFEST="$TMP/manifest.json" \
    CMUX_CEF_CACHE_DIR="$1" CMUX_CEF_NO_R2=1 CMUX_CEF_STORE_URL="http://127.0.0.1:$port" \
    bash "$ROOT/scripts/cmux-next/ensure-cef.sh" 2>&1) || status=$?
}

run "$TMP/cache1"
[[ "$status" == 0 ]] || { printf 'the store did not serve the engine (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }
grep -q 'controller artifact store' <<<"$out" || { printf 'no store download:\n%s\n' "$out" >&2; exit 1; }
[[ "$(cat "$TMP/cache1/$version/.verified")" == "$sha" ]] || { echo "cache entry not verified" >&2; exit 1; }

# Bytes that do not hash to the manifest are never cached; the other sources fail here.
cp "$TMP/bad.tar.xz" "$TMP/serve"
run "$TMP/cache2"
[[ "$status" == 1 ]] || { printf 'wrong bytes were accepted (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }
grep -q 'checksum mismatch' <<<"$out" || { printf 'no checksum refusal:\n%s\n' "$out" >&2; exit 1; }
[[ ! -e "$TMP/cache2/$version" ]] || { echo "a mismatched archive left a cache entry" >&2; exit 1; }

# CMUX_CEF_NO_STORE=1 skips the store.
cp "$TMP/good.tar.xz" "$TMP/serve"
status=0
out=$(env -u GH_TOKEN -u GITHUB_TOKEN PATH=/usr/bin:/bin CMUX_CEF_MANIFEST="$TMP/manifest.json" \
  CMUX_CEF_CACHE_DIR="$TMP/cache3" CMUX_CEF_NO_R2=1 CMUX_CEF_NO_STORE=1 CMUX_CEF_STORE_URL="http://127.0.0.1:$port" \
  bash "$ROOT/scripts/cmux-next/ensure-cef.sh" 2>&1) || status=$?
[[ "$status" == 1 ]] && ! grep -q 'controller artifact store' <<<"$out" || { printf 'CMUX_CEF_NO_STORE=1 still used the store:\n%s\n' "$out" >&2; exit 1; }
printf 'ensure-cef store tests: ok\n'
