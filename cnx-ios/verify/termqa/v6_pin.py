"""VERIFY-round6 bottom pin: last row flush with the composer (0 gap, 0 overlap, within 1 pt),
every composer height, keyboard up and down, at rest and while following.

    python3 v6_pin.py rest|follow TAG

rest: types (on the phone) a 50-row block ending in a reverse-video bar with the cursor in it,
then a sleep; follow: a loop that keeps a bar as the newest row. Then for each composer state
(keyboard down 1 line, keyboard up 1/3/6 lines, keyboard down with the 6-line draft) it takes a
screenshot (rest) or records 6 s (follow) and measures the bar's bottom against the first
non-background pixel row below it (v6pin.analyze) and against the AX composer card top.
"""
import json
import os
import subprocess
import sys
import time

from PIL import Image

import tq
import v6
import v6pin
from v6 import ev, shot, ctx

REST = "clear; for i in $(seq 1 50); do echo ROW-$i; done; printf '\\e[7m%*s\\e[0m' $COLUMNS ''; sleep 240"
FOLLOW = ("clear; i=0; while [ $i -lt 6000 ]; do i=$((i+1)); printf '\\nL%d\\n\\e[7m%*s\\e[0m' $i $COLUMNS ''; "
          "sleep 0.05; done")
DRAFT3 = "three lines of composer draft text that wrap onto a second line and then onto a third line"
DRAFT6 = " plus more words so that the draft keeps growing until it reaches about six lines in the composer card"


def card_top(j):
    return j.composer_card_top()


def set_draft(s, text):
    """Pastes `text` into the composer draft (not sent)."""
    subprocess.run(["xcrun", "simctl", "pbcopy", s.udid], input=text, text=True, check=True)
    f = s.find(ident="terminal.composer.field")[0]
    s.tap_el(f); time.sleep(0.6)
    p = s.wait(label="Paste", timeout=3)
    if not p:
        s.long_press(*f.center, seconds=0.8); time.sleep(0.4)
        p = s.wait(label="Paste", timeout=3)
    if p:
        s.tap_el(p); time.sleep(0.5)
        allow = s.find(label="Allow Paste", kind="Button")
        if allow:
            s.tap_el(allow[0]); time.sleep(0.5)
    return bool(p)


def measure_png(path, top):
    r = v6pin.analyze(Image.open(path), top)
    return r


def measure_video(video, top, n=40, start=1.0, dur=5.0):
    out = []
    d = f"/tmp/v6pin-{os.path.basename(video)}"
    os.makedirs(d, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(start), "-t", str(dur), "-i", video,
                    "-vf", f"fps={n / dur}", os.path.join(d, "f%03d.png")], check=True)
    for f in sorted(os.listdir(d)):
        r = v6pin.analyze(Image.open(os.path.join(d, f)), top)
        r["frame"] = f
        out.append(r)
    return out


def states(s, j, tag, mode):
    res = []

    def take(name):
        time.sleep(1.2)  # stimulus pacing: the composer/keyboard animation settles
        top = card_top(j)
        kb = bool(s.keyboard())
        if mode == "rest":
            p = shot(f"{tag}-{name}")
            r = measure_png(p, top)
        else:
            v = tq.rec_start(f"{tag}-{name}")
            time.sleep(6)
            tq.rec_stop()
            fr = measure_video(v, top)
            gaps = [x.get("gap_pt") for x in fr if "gap_pt" in x]
            hs = [x.get("bar_h") for x in fr if "bar_h" in x]
            r = {"frames": len(fr), "gap_pt": sorted(set(gaps)), "bar_h": sorted(set(hs)),
                 "ax_gap_pt": sorted(set(x.get("ax_gap_pt") for x in fr if "ax_gap_pt" in x)),
                 "errors": sum(1 for x in fr if "error" in x)}
            shot(f"{tag}-{name}")
        r.update({"state": name, "keyboard": kb, "card_top_ax": top})
        ev("pin", tag=tag, **r)
        res.append(r)

    j.hide_keyboard()
    take("kbdown-1line")
    f = s.find(ident="terminal.composer.field")[0]
    s.tap_el(f)
    take("kbup-1line")
    set_draft(s, DRAFT3)
    take("kbup-3line")
    v6.clear_composer()
    set_draft(s, DRAFT3 + DRAFT6 + " and a final clause to be sure it wraps to six lines or more")
    take("kbup-6line")
    j.hide_keyboard()
    take("kbdown-6line")
    v6.clear_composer()
    j.hide_keyboard()
    take("kbdown-cleared")
    return res


def main():
    mode, tag = sys.argv[1], sys.argv[2]
    s, m, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    v6.clear_composer()
    s.tap_el(s.find(ident="terminal.composer.field")[0]); time.sleep(0.8)
    j.keybar("Control C"); time.sleep(0.8)
    tq.paste_composer(REST if mode == "rest" else FOLLOW)
    j.hide_keyboard()
    time.sleep(3)  # stimulus pacing: output starts
    res = states(s, j, tag, mode)
    v6.applog(t0, os.path.join(v6.V6, f"{tag}.log"),
              'subsystem == "dev.cmux.cnx" AND category == "terminal-sizing" AND eventMessage CONTAINS "pin:"')
    json.dump(res, open(os.path.join(v6.V6, f"{tag}.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
