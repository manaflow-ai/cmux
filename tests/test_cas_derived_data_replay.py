#!/usr/bin/env python3
"""scripts/cas/derived_data_replay.py (RFD 0166 row B1) end to end against a local stand-in for
the public CI cache and a stand-in cas-replay: it walks main's first-parent commits, keeps the
newest seeds that exist (HEAD), streams each tar.zst into a tree, passes the archive sizes in
order as --archive-bytes, removes the trees it made, and takes p50 over the 1-behind rows."""
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cas/derived_data_replay.py")
PREFIX = "admission-derived-data-v1-macOS-ARM64-f00d-j12-"

# One row per consecutive pair plus oldest-to-newest, pct = 10 * (to index); records argv.
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
seen = [open(os.path.join(d, "Build/Intermediates.noindex/seed.txt")).read() for d in dirs]
open(os.environ["FAKE_ARGV"], "w").write(json.dumps({"sizes": sizes, "dirs": dirs, "seen": seen}))
def row(f, t, pct):
    print(json.dumps({"from": dirs[f], "to": dirs[t], "full": sizes[t], "tree": 5, "want_raw": 1,
                      "want_wire": 1, "ranges": 1, "range_bytes": sizes[t] * pct // 100,
                      "pct_of_full": float(pct), "ms": 1}))
for i in range(1, len(dirs)):
    row(i - 1, i, 10 * i)
if len(dirs) > 2:
    row(0, len(dirs) - 1, 99)
'''


def seed_archive(text):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as t:
        body = text.encode()
        info = tarfile.TarInfo("Build/Intermediates.noindex/seed.txt")
        info.size = len(body)
        t.addfile(info, io.BytesIO(body))
    return subprocess.run(["zstd", "-q", "-c"], input=raw.getvalue(), capture_output=True, check=True).stdout


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def main():
    if not shutil.which("zstd"):
        print("skip test_cas_derived_data_replay: no zstd")
        return
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        git(repo, "init", "-q")
        shas = []
        for i in range(8):
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", f"c{i}")
            shas.append(git(repo, "rev-parse", "HEAD"))
        git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        # Seeds at commits 1, 4 and 6 (of 0..7); the newest two are 4 and 6, replayed 4 then 6.
        objects = {f"/v1/macOS-ARM64/objects/{PREFIX}{shas[i]}.tar.zst": seed_archive(f"seed {i}")
                   for i in (1, 4, 6)}
        agents = set()

        class Cache(http.server.BaseHTTPRequestHandler):
            def reply(self, with_body):
                agents.add(self.headers.get("User-Agent"))
                body = objects.get(self.path)
                if body is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if with_body:
                    self.wfile.write(body)

            def do_HEAD(self):
                self.reply(False)

            def do_GET(self):
                self.reply(True)

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Cache)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        fake = os.path.join(tmp, "cas-replay")
        with open(fake, "w") as f:
            f.write(FAKE)
        os.chmod(fake, 0o755)
        work = os.path.join(tmp, "work")
        env = dict(os.environ, FAKE_ARGV=os.path.join(tmp, "argv.json"),
                   CI_CACHE_R2_PUBLIC_URL=f"http://127.0.0.1:{srv.server_port}")
        env.pop("GITHUB_STEP_SUMMARY", None)
        base = [sys.executable, SCRIPT, "--cas-replay", fake, "--prefix", PREFIX, "--git-dir", repo,
                "--work", work, "--count", "2"]
        out = subprocess.run(base, check=True, capture_output=True, text=True, env=env).stdout
        s = json.loads(out)
        argv = json.load(open(env["FAKE_ARGV"]))
        assert argv["seen"] == ["seed 4", "seed 6"], argv
        sizes = [len(objects[f"/v1/macOS-ARM64/objects/{PREFIX}{shas[i]}.tar.zst"]) for i in (4, 6)]
        assert argv["sizes"] == sizes, argv
        assert s["row"] == "B1" and s["pairs"] == 1 and s["pct_p50"] == 10 and s["span"] is None, s
        assert s["seeds"] == [shas[4], shas[6]], s
        assert not os.listdir(os.path.join(work, "trees")), "trees it made are removed"
        assert agents == {"cmux-cas-replay-b1"}, agents

        # Three seeds: 2 pairs (10, 20 %), p50 15, the 99 % span reported apart; --max-p50 gates.
        out = subprocess.run(base[:-1] + ["3", "--keep"], check=True, capture_output=True, text=True, env=env).stdout
        s = json.loads(out)
        assert s["pairs"] == 2 and s["pct_p50"] == 15 and s["pct_max"] == 20 and s["span"]["pct"] == 99, s
        gated = subprocess.run(base + ["--max-p50", "5"], capture_output=True, text=True, env=env)
        assert gated.returncode == 1, gated

        # Fewer than two seeds is a skip (exit 0), not a failure.
        out = subprocess.run(base[:5] + ["admission-derived-data-v1-macOS-ARM64-none-j12-"] + base[6:],
                             check=True, capture_output=True, text=True, env=env).stdout
        assert "skipped" in json.loads(out), out
        srv.shutdown()

    sys.path.insert(0, os.path.join(ROOT, "scripts/cas"))
    import derived_data_replay as mod
    log = (f"r2-cache: restored {PREFIX}{'b' * 40}\n"
           f"r2-cache: saved {PREFIX}{'a' * 40}\n  key: {PREFIX}{'c' * 40}\n")
    assert mod.saved_key(log) == PREFIX + "a" * 40
    assert mod.prefix_from_key(mod.saved_key(log)) == PREFIX
    assert mod.saved_key(f"adopted {PREFIX}{'b' * 40}") == PREFIX + "b" * 40
    assert mod.saved_key("nothing") is None
    print("ok test_cas_derived_data_replay")


if __name__ == "__main__":
    main()
