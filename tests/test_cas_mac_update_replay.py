#!/usr/bin/env python3
"""scripts/cas/mac_update_replay.py against a stand-in 7zz and cas-replay. Each DMG unpacks to a
.app tree, the trees replay with the DMG sizes as --archive-bytes and the DMGs replay alone. Today's
bytes are the Sparkle delta when the appcast lists one from that build, else the whole DMG, and
--max-mb gates on the N-behind tree bytes."""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cas/mac_update_replay.py")

# `7zz x -y -snld DMG -oDIR`: DIR/cmux NIGHTLY.app/Contents/MacOS/cmux holding the DMG's bytes.
FAKE_7ZZ = r'''#!/usr/bin/env python3
import os, sys
dmg = sys.argv[4]
out = sys.argv[5][2:]
d = os.path.join(out, "cmux NIGHTLY.app", "Contents", "MacOS")
os.makedirs(d)
open(os.path.join(d, "cmux"), "wb").write(open(dmg, "rb").read())
os.symlink("/Applications", os.path.join(out, "Applications"))
'''

# Rows 0->1, 1->2, 0->2. range_bytes: a tree is 10 * (to index + span) bytes, a DMG dir 100 *.
FAKE_REPLAY = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
sizes, dirs = [], []
while a:
    x = a.pop(0)
    if x == "--archive-bytes":
        sizes.append(int(a.pop(0)))
    else:
        dirs.append(x)
log = os.environ["FAKE_LOG"]
with open(log, "a") as f:
    f.write(json.dumps({"sizes": sizes, "dirs": dirs}) + "\n")
tree = bool(sizes)
if tree:
    assert all(os.path.isfile(os.path.join(d, "cmux NIGHTLY.app/Contents/MacOS/cmux")) for d in dirs), dirs
else:
    assert all(os.listdir(d) == ["archive.dmg"] for d in dirs), dirs
unit = 10 if tree else 100
for f_, t, k in ((0, 1, 1), (1, 2, 2), (0, 2, 5)):
    print(json.dumps({"from": dirs[f_], "to": dirs[t], "full": 1, "tree": 4000, "want_raw": 1,
                      "want_wire": unit * k - 1, "ranges": 1, "range_bytes": unit * k,
                      "pct_of_full": 1.0, "ms": 1}))
'''

APPCAST = b'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><sparkle:version>300</sparkle:version>
<enclosure url="https://x/300.dmg" length="3000" sparkle:edSignature="s"/>
<sparkle:deltas><enclosure url="https://x/300-200.delta" sparkle:deltaFrom="200" length="42"/></sparkle:deltas>
</item>
<item><sparkle:version>200</sparkle:version><enclosure url="https://x/200.dmg" length="2000"/>
<sparkle:deltas><enclosure url="https://x/200-100.delta" sparkle:deltaFrom="100" length="7"/></sparkle:deltas>
</item></channel></rss>
'''


def tool(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, 0o755)
    return path


def test_feed_parse():
    import importlib.util
    sys.path.insert(0, os.path.dirname(SCRIPT))
    spec = importlib.util.spec_from_file_location("mac_update_replay", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.feed_newest(APPCAST) == "300"
    today = mod.sparkle_today(APPCAST, "300", {"100": 1000, "200": 2000, "300": 3000})
    assert today == {"100": (3000, "dmg"), "200": (42, "delta"), "300": (3000, "dmg")}, today


def main():
    test_feed_parse()
    with tempfile.TemporaryDirectory() as tmp:
        dmgs = os.path.join(tmp, "dmgs")
        os.makedirs(dmgs)
        for build, n in (("100", 1000), ("200", 2000), ("300", 3000)):
            with open(os.path.join(dmgs, f"{build}.dmg"), "wb") as f:
                f.write(b"d" * n)
        seven = tool(os.path.join(tmp, "7zz"), FAKE_7ZZ)
        replay = tool(os.path.join(tmp, "cas-replay"), FAKE_REPLAY)
        appcast = os.path.join(tmp, "appcast.xml")
        with open(appcast, "wb") as f:
            f.write(APPCAST)
        env = dict(os.environ, FAKE_LOG=os.path.join(tmp, "log.jsonl"))
        env.pop("GITHUB_STEP_SUMMARY", None)
        base = [sys.executable, SCRIPT, "--cas-replay", replay, "--seven-zip", seven, "--from-dir", dmgs,
                "--appcast-file", appcast, "--work", os.path.join(tmp, "work"), "--behind", "2"]
        s = json.loads(subprocess.run(base, check=True, capture_output=True, text=True, env=env).stdout)
        calls = [json.loads(line) for line in open(env["FAKE_LOG"])]
        assert len(calls) == 2, calls
        assert calls[0]["sizes"] == [1000, 2000, 3000], calls
        assert [os.path.basename(d) for d in calls[0]["dirs"]] == ["100", "200", "300"], calls
        assert calls[1]["sizes"] == [], calls
        assert s["to"] == "300" and s["dmg_bytes"] == 3000, s
        # 2 behind: no delta from 100 in 300's item (the 100 delta belongs to 200), so today is the DMG.
        b = s["behind"]
        assert (b["from"], b["today_bytes"], b["today_kind"]) == ("100", 3000, "dmg"), b
        assert (b["tree_range_bytes"], b["dmg_chunks_range_bytes"], b["tree_want_wire"]) == (50, 500, 49), b
        assert b["meets_target"] is True and b["behind"] == 2, b
        one = s["one_behind"]
        assert (one["from"], one["today_bytes"], one["today_kind"]) == ("200", 42, "delta"), one
        assert one["tree_range_bytes"] == 20 and one["dmg_chunks_range_bytes"] == 200, one
        # A rerun reuses the unpacked trees; the gate trips above 0.00001 MB (10 bytes).
        gated = subprocess.run(base + ["--max-mb", "0.00001"], capture_output=True, text=True, env=env)
        assert gated.returncode == 1, gated
        ok = subprocess.run(base + ["--max-mb", "70"], capture_output=True, text=True, env=env)
        assert ok.returncode == 0, ok
    print("ok test_cas_mac_update_replay")


if __name__ == "__main__":
    main()
