#!/usr/bin/env python3
"""scripts/cas/acpmux_update_replay.py against a stand-in cas-replay and three local builds (--keys,
--from-dir): every consecutive update gets today's bytes, zstd, cas/1 and patch-from columns, and a
patch against an identical build is far smaller than the whole binary."""
import json
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cas/acpmux_update_replay.py")

# Consecutive pairs, then oldest -> newest; range_bytes 1000 * (pair index + 1).
FAKE_REPLAY = r'''#!/usr/bin/env python3
import json, sys
dirs = sys.argv[1:]
pairs = [(i - 1, i) for i in range(1, len(dirs))] + ([(0, len(dirs) - 1)] if len(dirs) > 2 else [])
for n, (a, b) in enumerate(pairs):
    print(json.dumps({"from": dirs[a], "to": dirs[b], "full": 1, "want_raw": 7, "want_wire": 5,
                      "ranges": 1, "range_bytes": 1000 * (n + 1), "ms": 0}))
'''


def main():
    with tempfile.TemporaryDirectory() as t:
        fake = os.path.join(t, "cas-replay")
        with open(fake, "w") as f:
            f.write(FAKE_REPLAY)
        os.chmod(fake, 0o755)
        src = os.path.join(t, "src")
        os.makedirs(src)
        rng = random.Random(7)
        base = bytes(rng.getrandbits(8) for _ in range(300_000))
        builds = {"k1": base, "k2": base[:1000] + b"changed" + base[1000:], "k3": base[:1000] + b"changed" + base[1000:]}
        for k, b in builds.items():
            with open(os.path.join(src, k), "wb") as f:
                f.write(b)
        out = subprocess.run([sys.executable, SCRIPT, "--cas-replay", fake, "--keys", "k1,k2,k3",
                              "--from-dir", src, "--work", os.path.join(t, "w")],
                             check=True, capture_output=True, text=True, env={**os.environ, "GITHUB_STEP_SUMMARY": os.path.join(t, "sum.md")})
        s = json.loads(out.stdout)
        assert s["row"] == "A1" and s["builds"] == 3 and s["newest"] == "k3", s
        assert [p["to"] for p in s["pairs"]] == ["k2", "k3"], s["pairs"]
        assert [p["cas_range_bytes"] for p in s["pairs"]] == [1000, 2000], s["pairs"]
        assert s["oldest_to_newest_cas"]["range_bytes"] == 3000, s
        for p in s["pairs"]:
            assert p["today"] == len(builds[p["to"]]), p
            # Random bytes do not compress, but a patch against a near-identical build is tiny.
            assert p["patch"] < p["today"] // 20, p
        assert os.path.isfile(os.path.join(t, "w", "rows.jsonl"))
        summary = open(os.path.join(t, "sum.md")).read()
        assert "RFD 0166 A1" in summary and "cas/1 Range GETs" in summary, summary
    print("ok")


if __name__ == "__main__":
    main()
