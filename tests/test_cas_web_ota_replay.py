#!/usr/bin/env python3
"""scripts/cas/web_ota_replay.py against a stand-in cas-replay: archives unpack, sizes pass in
order as --archive-bytes, and the W1 summary takes p50 over the 1-behind rows only."""
import io
import json
import os
import random
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cas/web_ota_replay.py")

# Prints one row per consecutive pair plus oldest-to-newest, pct = 10 * (to index), and records argv.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
sizes, dirs = [], []
while a:
    x = a.pop(0)
    if x == "--archive-bytes":
        sizes.append(int(a.pop(0)))
    else:
        dirs.append(x)
assert all(os.path.isfile(os.path.join(d, "webviews/dist/app.js")) for d in dirs), dirs
open(os.environ["FAKE_ARGV"], "w").write(json.dumps({"sizes": sizes, "dirs": dirs}))
def row(f, t, pct):
    print(json.dumps({"from": dirs[f], "to": dirs[t], "full": sizes[t], "tree": 1, "want_raw": 1,
                      "want_wire": 1, "ranges": 1, "range_bytes": sizes[t] * pct // 100,
                      "pct_of_full": float(pct), "ms": 1}))
for i in range(1, len(dirs)):
    row(i - 1, i, 10 * i)
row(0, len(dirs) - 1, 99)
'''


def archive(path, files):
    with tarfile.open(path, "w:gz") as t:
        for name, body in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            t.addfile(info, io.BytesIO(body))


def test_token_stays_on_github():
    """An artifact download 302s to blob storage, which rejects a Bearer header with 401: the
    token reaches the first host only."""
    import http.server
    import importlib.util
    import threading
    seen = {}

    class Blob(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen["blob"] = self.headers.get("Authorization")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"zip")

        def log_message(self, *a):
            pass

    blob = http.server.HTTPServer(("127.0.0.1", 0), Blob)

    class Api(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen["api"] = self.headers.get("Authorization")
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{blob.server_port}/blob")
            self.end_headers()

        def log_message(self, *a):
            pass

    gh = http.server.HTTPServer(("127.0.0.1", 0), Api)
    for srv in (blob, gh):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    spec = importlib.util.spec_from_file_location("web_ota_replay", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    body = mod.api(f"http://127.0.0.1:{gh.server_port}/zip", "t0k", raw=True)
    for srv in (blob, gh):
        srv.shutdown()
    assert body == b"zip", body
    assert seen == {"api": "Bearer t0k", "blob": None}, seen


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runs = os.path.join(tmp, "runs")
        base = random.Random(0).randbytes(4000)  # incompressible, so archive sizes grow with i
        for i in range(4):
            d = os.path.join(runs, f"2026-11-25T0{i}:00:00Z-{100 + i}")
            os.makedirs(d)
            # app.js changes every publish, vendor.js never: patch-from moves app.js's delta only.
            archive(os.path.join(d, f"web-bundles-{i:064x}.tar.gz"), {
                "webviews/dist/app.js": base[:1000 * (i + 1)],
                "webviews/dist/vendor.js": bytes(range(256)) * 400})
        fake = os.path.join(tmp, "cas-replay")
        with open(fake, "w") as f:
            f.write(FAKE)
        os.chmod(fake, 0o755)
        env = dict(os.environ, FAKE_ARGV=os.path.join(tmp, "argv.json"))
        env.pop("GITHUB_STEP_SUMMARY", None)
        out = subprocess.run([sys.executable, SCRIPT, "--cas-replay", fake, "--from-dir", runs,
                              "--work", os.path.join(tmp, "work")],
                             check=True, capture_output=True, text=True, env=env).stdout
        s = json.loads(out)
        argv = json.load(open(env["FAKE_ARGV"]))
        assert argv["dirs"] == sorted(argv["dirs"]), argv
        assert len(argv["sizes"]) == 4 and argv["sizes"] == sorted(argv["sizes"]), argv
        # 1-behind rows are 10, 20, 30 %: p50 20, max 30; the 99 % span row is reported apart.
        assert s["pairs"] == 3 and s["pct_p50"] == 20 and s["pct_max"] == 30, s
        assert s["span"]["behind"] == 3 and s["span"]["pct"] == 99, s
        # Patch-from: unchanged vendor.js costs 0; app.js grows by 1000 random bytes a publish.
        rows = [json.loads(x) for x in open(os.path.join(tmp, "work", "rows.jsonl"))]
        assert all(1000 <= r["patch_bytes"] < 1200 for r in rows[:3]) and "patch_bytes" not in rows[3], rows
        assert s["patch_pct_p50"] > 0 and s["patch_pct_max"] < 100, s
        gated = subprocess.run([sys.executable, SCRIPT, "--cas-replay", fake, "--from-dir", runs,
                                "--work", os.path.join(tmp, "work"), "--max-p50", "10"],
                               capture_output=True, text=True, env=env)
        assert gated.returncode == 1, gated
    test_token_stays_on_github()
    print("ok test_cas_web_ota_replay")


if __name__ == "__main__":
    main()
