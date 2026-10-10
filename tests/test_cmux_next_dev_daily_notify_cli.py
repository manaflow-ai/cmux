#!/usr/bin/env python3
"""Exercise deferred dev publication through the notifier CLI and HTTP protocol."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
KEY = "b" * 40
BRANCH = "cmux-next-dev-" + SHA
marker = {"version": 1, "key": KEY, "sha": SHA, "status_sha": SHA,
          "origin": "push", "branch": BRANCH, "tiers": ["scheme"],
          "dev_daily": True, "dev_daily_sha": SHA}
archive = io.BytesIO()
with zipfile.ZipFile(archive, "w") as zipped:
    zipped.writestr("marker.json", json.dumps(marker))
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/repos/o/r/actions/artifacts?"):
            body = json.dumps({"artifacts": [{"id": 4, "workflow_run": {"id": 7},
                "archive_download_url": self.server.url + "/marker.zip"}]}).encode()
        elif self.path == "/marker.zip":
            body = archive.getvalue()
        elif self.path == "/repos/o/r/git/ref/heads/" + BRANCH:
            body = json.dumps({"object": {"sha": SHA}}).encode()
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        requests.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        self.send_response(204)
        self.end_headers()

    def do_DELETE(self):
        requests.append((self.path, "deleted"))
        self.send_response(204)
        self.end_headers()


server = HTTPServer(("127.0.0.1", 0), Handler)
server.url = "http://127.0.0.1:" + str(server.server_port)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_next_tree_notify.py"),
        "--repo", "o/r", "--key", KEY, "--state", "ready"],
        env={**os.environ, "GH_TOKEN": "fixture", "GITHUB_API_URL": server.url},
        capture_output=True, text=True, timeout=20)
finally:
    server.shutdown()
    server.server_close()
    thread.join()
assert result.returncode == 0, result.stderr
assert len(requests) == 2, (requests, result.stdout)
path, dispatch = requests[0]
assert path == "/repos/o/r/actions/workflows/cmux-next.yml/dispatches", requests
assert dispatch["ref"] == BRANCH, dispatch
assert dispatch["inputs"].get("dev_daily") == "true", "deferred callback lost dev_daily: " + str(dispatch)
assert dispatch["inputs"].get("dev_daily_sha") == SHA, dispatch
assert dispatch["inputs"]["same_tree_sha"] == SHA, dispatch
assert requests[1] == ("/repos/o/r/actions/artifacts/4", "deleted"), requests
print("deferred dev daily notifier CLI: ok")
