#!/usr/bin/env python3
"""RFD 0166 row U2 by replay: the bytes a Mac 20 NIGHTLYs behind downloads to update, today and under cas/1.

Today Sparkle reads the NIGHTLY appcast (files-next.cmux.com/nightly-next/appcast-arm64.xml). A client
whose build has a BinaryDelta in it downloads the delta (40-60 MB); every other client, which
includes everyone 20 builds behind, downloads the whole DMG (about 250 MB). Under cas/1 the client
holding build N-k fetches only the FastCDC chunks of N's archive that it lacks. This script
replays that over real published NIGHTLYs:

  1. discover: nightly.yml runs on nightly-next, newest first. A build number is the run id
     followed by the attempt in two digits (nightly_version.py), and a build counts as published
     when its DMG is on the feed (one HEAD request each, no token). Runs that GitHub marks failed
     or cancelled publish DMGs too, so the conclusion is not a filter.
  2. fetch N, N-1 and N-BEHIND's DMGs, and unpack each .app with 7-Zip (7zz 24+ reads the
     DMG's XZ blocks and the APFS volume in one pass, on Linux).
  3. run `cas-replay` (cmux-tui/crates/cmux-cas) twice, oldest first: over the unpacked .app trees
     with each DMG's size as --archive-bytes (the "after"), and over the DMG files themselves
     (chunking the compressed archive: the "before" a CDN without unpacking would get).
  4. print the U2 summary as JSON, plus a table under GitHub Actions. U2's RFD numbers are
     243 MB today, with <= 70 MB as the target.

Usage:
  mac_update_replay.py --cas-replay BIN [--seven-zip 7zz] [--behind 20] [--work DIR]
                       [--builds OLD,MID,NEW] [--from-dir DIR] [--appcast-file F] [--max-mb MB]

--builds skips discovery (they are fetched from the feed). --from-dir reads DIR/<build>.dmg
instead of the network (a test, or a rerun). --max-mb exits 1 when the N-BEHIND -> N Range GET
bytes are above MB (the target is 70); unset, the script only reports. Discovery needs
GH_TOKEN (actions: read) and GITHUB_REPOSITORY.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from web_ota_replay import WAIT_BUDGET, RateLimited, api  # noqa: E402

FEED = "https://files-next.cmux.com/nightly-next"
DMG = "cmux-nightly-next-macos-{arch}-{build}.dmg"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# The RFD's U2 row (cmuxterm-hq docs/rfd/0166-own-cdn.md, "Scoreboard rows").
U2_TODAY = 243e6
U2_TARGET = 70e6
# The CDN answers urllib's default User-Agent with 403 (as derived_data_replay.py notes).
USER_AGENT = "cmux-cas-replay-u2"


def head_ok(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except urllib.error.HTTPError:
        return False


def discover(repo, token, need, feed, arch, pages=4):
    """The newest `need` published builds, newest first."""
    budget = [WAIT_BUDGET]
    found = []
    for page in range(1, pages + 1):
        runs = api(f"repos/{repo}/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=100&page={page}",
                   token, budget=budget)["workflow_runs"]
        if not runs:
            break
        for run in runs:
            for attempt in range(run["run_attempt"], 0, -1):
                build = f"{run['id']}{attempt:02d}"
                if head_ok(f"{feed}/{DMG.format(arch=arch, build=build)}"):
                    found.append(build)
                    break
            if len(found) >= need:
                return found
    return found


def download(url, path):
    if os.path.isfile(path):
        return
    tmp = path + ".part"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=600) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(tmp, path)


def unpack(seven_zip, dmg, out):
    """The .app trees inside the DMG, under out/. 7-Zip opens the DMG, then its APFS (or HFS+)
    volume; -snld keeps the /Applications drop link a link, which the manifest skips."""
    if os.path.isdir(out):
        return out
    tmp = out + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    subprocess.run([seven_zip, "x", "-y", "-snld", dmg, f"-o{tmp}"], check=True, stdout=subprocess.DEVNULL)
    apps = [n for n in os.listdir(tmp) if n.endswith(".app")]
    if not apps:
        raise SystemExit(f"{dmg}: no .app in the volume ({sorted(os.listdir(tmp))})")
    os.replace(tmp, out)
    return out


def sparkle_today(appcast_xml, newest, sizes):
    """What Sparkle downloads today to reach `newest`, from each build: {build: (bytes, kind)}.
    A delta when the feed's item for `newest` lists one from that build, else the whole DMG."""
    deltas = {}
    if appcast_xml:
        root = ET.fromstring(appcast_xml)
        for item in root.iter("item"):
            version = item.findtext(f"{{{SPARKLE}}}version") or ""
            enc = item.find("enclosure")
            version = version or (enc.get(f"{{{SPARKLE}}}version", "") if enc is not None else "")
            if version != newest:
                continue
            for d in item.iter("enclosure"):
                frm = d.get(f"{{{SPARKLE}}}deltaFrom")
                if frm and d.get("length"):
                    deltas[frm] = int(d.get("length"))
    return {b: ((deltas[b], "delta") if b in deltas else (sizes[newest], "dmg")) for b in sizes}


def read_appcast(a):
    if a.appcast_file:
        with open(a.appcast_file, "rb") as f:
            return f.read()
    with urllib.request.urlopen(urllib.request.Request(f"{a.feed}/appcast-{a.arch}.xml",
                                                       headers={"User-Agent": USER_AGENT}), timeout=60) as r:
        return r.read()


def feed_newest(appcast_xml):
    """The build the feed offers now (its first item's sparkle:version)."""
    for item in ET.fromstring(appcast_xml).iter("item"):
        v = item.findtext(f"{{{SPARKLE}}}version")
        if v:
            return v
    raise SystemExit("the appcast names no build")


def replay(cas_replay, dirs, sizes=None):
    cmd = [cas_replay]
    for s in sizes or []:
        cmd += ["--archive-bytes", str(s)]
    out = subprocess.run(cmd + dirs, check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def summarize(builds, behind, sizes, today, tree_rows, dmg_rows):
    """builds is oldest first: [N-behind, N-1, N]. cas-replay's rows are 0->1, 1->2, 0->2."""
    old, mid, new = builds

    def col(frm, t, d):
        return {
            "from": frm,
            "today_bytes": today[frm][0],
            "today_kind": today[frm][1],
            "dmg_chunks_range_bytes": d["range_bytes"],
            "tree_want_wire": t["want_wire"],
            "tree_range_bytes": t["range_bytes"],
            "tree_pct_of_dmg": round(t["range_bytes"] * 100.0 / sizes[new], 1),
            "dmg_chunks_pct_of_dmg": round(d["range_bytes"] * 100.0 / sizes[new], 1),
        }

    span = col(old, tree_rows[2], dmg_rows[2])
    span["behind"] = behind
    span["meets_target"] = span["tree_range_bytes"] <= U2_TARGET
    return {
        "row": "U2",
        "to": new,
        "dmg_bytes": sizes[new],
        "tree_bytes": tree_rows[2]["tree"],
        "rfd_today": U2_TODAY,
        "target": U2_TARGET,
        "behind": span,
        "one_behind": col(mid, tree_rows[1], dmg_rows[1]),
    }


def step_summary(s):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    mb = lambda b: f"{b / 1e6:.1f} MB"  # noqa: E731
    with open(path, "a") as f:
        f.write(f"### RFD 0166 U2: Mac update bytes to NIGHTLY {s['to']} (replay)\n\n"
                "| from | today (Sparkle) | cas/1, DMG chunks | cas/1, .app tree chunks (Range GETs) | target |\n"
                "| --- | --- | --- | --- | --- |\n")
        for key, label in (("behind", f"{s['behind']['behind']} behind"), ("one_behind", "1 behind")):
            c = s[key]
            f.write(f"| {label} ({c['from']}) | {mb(c['today_bytes'])} ({c['today_kind']})"
                    f" | {mb(c['dmg_chunks_range_bytes'])} ({c['dmg_chunks_pct_of_dmg']}%)"
                    f" | **{mb(c['tree_range_bytes'])}** ({c['tree_pct_of_dmg']}%)"
                    f" | {'<= 70 MB' if key == 'behind' else ''} |\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cas-replay", required=True)
    ap.add_argument("--seven-zip", default="7zz")
    ap.add_argument("--behind", type=int, default=20)
    ap.add_argument("--arch", default="arm64")
    ap.add_argument("--feed", default=FEED)
    ap.add_argument("--work", default="cas-replay-u2")
    ap.add_argument("--builds", help="OLD,MID,NEW: skip discovery")
    ap.add_argument("--from-dir", help="read DIR/<build>.dmg instead of the feed")
    ap.add_argument("--appcast-file", help="the appcast to price today's update from, instead of the feed's")
    ap.add_argument("--max-mb", type=float)
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)

    appcast = None
    if a.builds:
        builds = a.builds.split(",")
        if len(builds) != 3:
            raise SystemExit("--builds needs OLD,MID,NEW")
    elif a.from_dir:
        have = sorted(re.sub(r"\.dmg$", "", n) for n in os.listdir(a.from_dir) if n.endswith(".dmg"))
        if len(have) < 3:
            raise SystemExit(f"need three DMGs in {a.from_dir}, found {len(have)}")
        builds = [have[0], have[-2], have[-1]]
    else:
        appcast = read_appcast(a)
        top = feed_newest(appcast)
        try:
            # Two spare: a build uploaded but not yet in the appcast is dropped, so N is the build
            # a client is offered now.
            newest = discover(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"], a.behind + 3, a.feed, a.arch)
        except RateLimited as e:
            print(f"::warning::U2 replay skipped: {e}", file=sys.stderr)
            print(json.dumps({"row": "U2", "skipped": str(e)}))
            return 0
        if top in newest:
            newest = newest[newest.index(top):]
        if len(newest) < a.behind + 1:
            raise SystemExit(f"found {len(newest)} published NIGHTLYs from {top}, need {a.behind + 1}")
        builds = [newest[a.behind], newest[1], newest[0]]
    old, mid, new = builds

    dmgs, trees, sizes = {}, [], {}
    for b in builds:
        if a.from_dir:
            dmgs[b] = os.path.join(a.from_dir, f"{b}.dmg")
        else:
            dmgs[b] = os.path.join(a.work, "dmg", f"{b}.dmg")
            os.makedirs(os.path.dirname(dmgs[b]), exist_ok=True)
            download(f"{a.feed}/{DMG.format(arch=a.arch, build=b)}", dmgs[b])
        sizes[b] = os.path.getsize(dmgs[b])
        trees.append(unpack(a.seven_zip, dmgs[b], os.path.join(a.work, "tree", b)))
    # The DMG-chunk column: each DMG alone in a dir (a hard link, no copy).
    dmg_dirs = []
    for b in builds:
        d = os.path.join(a.work, "dmg-only", b)
        os.makedirs(d, exist_ok=True)
        link = os.path.join(d, "archive.dmg")
        if not os.path.exists(link):
            try:
                os.link(dmgs[b], link)
            except OSError:
                shutil.copyfile(dmgs[b], link)
        dmg_dirs.append(d)

    tree_rows = replay(a.cas_replay, trees, [sizes[b] for b in builds])
    dmg_rows = replay(a.cas_replay, dmg_dirs)
    with open(os.path.join(a.work, "rows.jsonl"), "w") as f:
        for kind, rows in (("tree", tree_rows), ("dmg", dmg_rows)):
            for r in rows:
                f.write(json.dumps({"kind": kind, **r}) + "\n")

    if appcast is None:
        appcast = b"" if a.from_dir and not a.appcast_file else read_appcast(a)
    s = summarize(builds, a.behind, sizes, sparkle_today(appcast, new, sizes), tree_rows, dmg_rows)
    print(json.dumps(s))
    step_summary(s)
    if a.max_mb is not None and s["behind"]["tree_range_bytes"] > a.max_mb * 1e6:
        print(f"U2 {s['behind']['tree_range_bytes'] / 1e6:.1f} MB is above {a.max_mb} MB", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
