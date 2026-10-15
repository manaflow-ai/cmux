"""G-14 on the simulator (T-SEL-01/02): edge autoscroll and copy across the scrollback,
and selection in a full-screen app. Every command is typed on the phone.

    python3 g14.py scroll [N=600]   hist.py N; long press a row near the bottom; drag the
                                    start handle past the top edge and hold 3 s; Copy;
                                    the pasteboard must be rows #a..#b exactly, a well above
                                    the first visible row (the page scrolled under the handle)
    python3 g14.py tui              vim on a file of known rows; a long press selects; drag
                                    the end handle down; Copy; the pasteboard holds those rows

Writes design/terminal/g14/<name>-<time>.json and screenshots in artifacts/shots.
"""
import json
import os
import re
import subprocess
import sys
import time

import tq
from tq import ctx, log

sys.path.insert(0, os.path.join(tq.HERE, "fixtures"))
from _rows import row  # noqa: E402

OUT = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/g14"))


def pbpaste(sim):
    return subprocess.run(["xcrun", "simctl", "pbpaste", sim.udid], capture_output=True, text=True).stdout


def pbclear(sim):
    subprocess.run(["xcrun", "simctl", "pbcopy", sim.udid], input="", text=True)


def visible_ids(sim):
    ids = []
    for x, y, w, h, t in sim.ocr():
        m = re.match(r"#(\d{7})", t)
        if m and 90 < y < 760:
            ids.append((y, int(m.group(1))))
    return sorted(ids)


def handle(sim, which):
    h = sim.find(label="Selection start" if which == "start" else "Selection end")
    return h[0] if h else None


def tap_copy(sim):
    c = sim.wait(label="Copy", timeout=4)
    if not c:
        return False
    sim.tap_el(c)
    return True


def expected(a, b):
    return "\n".join(row(i, stamp=False, color=False) for i in range(a, b + 1))


def scroll_case(n=600):
    sim, mac, j = ctx()
    tq.paste_composer(f"clear; python3 ~/tqf/hist.py {n}")
    time.sleep(3)
    j.hide_keyboard()
    time.sleep(1.5)
    vis = visible_ids(sim)
    if len(vis) < 5:
        raise RuntimeError(f"rows not visible: {vis}")
    top_id = vis[0][1]
    y_press, id_press = vis[-3]
    pbclear(sim)
    sim.long_press(120, y_press + 6, seconds=0.9)
    time.sleep(0.6)
    s = handle(sim, "start")
    if not s:
        raise RuntimeError("no selection handles after the long press")
    tq.shot("g14-scroll-selected")
    x, y = s.center
    # Past the top edge of the visible rows, held still for 3 s: the page scrolls up under the finger.
    sim.drag(x, y, x, 40, duration=0.6, steps=30, hold=3.0)
    time.sleep(0.8)
    tq.shot("g14-scroll-after-hold")
    copied = tap_copy(sim)
    time.sleep(0.8)
    text = pbpaste(sim)
    ids = [int(m.group(1)) for m in re.finditer(r"^#(\d{7})", text, re.M)]
    first, last = (ids[0], ids[-1]) if ids else (None, None)
    exact = bool(ids) and text.strip("\n") == expected(first, last)
    res = {"case": "scroll", "n": n, "first_visible_before": top_id, "pressed_row": id_press,
           "copied": copied, "first": first, "last": last, "rows": len(ids),
           "scrolled_rows_above_visible": (top_id - first) if first else None,
           "exact_match": exact, "chars": len(text),
           "pass": bool(copied and exact and first is not None and first < top_id - 20 and last == id_press)}
    return res


def tui_case(n=200):
    sim, mac, j = ctx()
    tq.paste_composer(f"clear; python3 ~/tqf/hist.py {n} > /tmp/g14-rows.txt; vim -u NONE -c 'set mouse=a' +40 /tmp/g14-rows.txt")
    time.sleep(3)
    j.hide_keyboard()
    time.sleep(1.5)
    vis = visible_ids(sim)
    if len(vis) < 5:
        raise RuntimeError(f"vim rows not visible: {vis}")
    y0, id0 = vis[2]
    pbclear(sim)
    sim.long_press(40, y0 + 6, seconds=0.9)
    time.sleep(0.6)
    e = handle(sim, "end")
    if not e:
        tq.shot("g14-tui-no-handles")
        return {"case": "tui", "pass": False, "note": "no selection handles after the long press in vim"}
    x, y = e.center
    sim.drag(x, y, 380, y + 5 * 16, duration=0.6, steps=30, hold=0.4)
    time.sleep(0.6)
    tq.shot("g14-tui-selected")
    copied = tap_copy(sim)
    time.sleep(0.8)
    text = pbpaste(sim)
    ids = [int(m.group(1)) for m in re.finditer(r"^#(\d{7})", text, re.M)]
    exact = bool(ids) and text.strip("\n") == expected(ids[0], ids[-1])
    # Leave vim from the phone.
    j.keybar("Escape")
    tq.paste_composer(":q!")
    return {"case": "tui", "pressed_row": id0, "copied": copied, "rows": ids[:1] + ids[-1:], "count": len(ids),
            "exact_match": exact, "pass": bool(copied and exact and ids and ids[0] == id0 and len(ids) >= 4)}


def main():
    case = sys.argv[1]
    res = scroll_case(int(sys.argv[2]) if len(sys.argv) > 2 else 600) if case == "scroll" else tui_case()
    res["time"] = time.strftime("%Y-%m-%d %H:%M:%S")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"{case}-{time.strftime('%m%d-%H%M%S')}.json")
    json.dump(res, open(path, "w"), indent=1)
    log(f"g14 {case}: {'PASS' if res['pass'] else 'FAIL'} -> {path}")
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
