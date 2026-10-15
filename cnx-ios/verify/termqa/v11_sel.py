"""Round-11 verifier, T-SEL-01 samples typed on the phone (hist.py rows), plus the clear case.

    TQ_BUNDLE=... python3 v11.py v11_sel words [K=5]     long press a word on K rows; Copy; the copy is one word of that row
    TQ_BUNDLE=... python3 v11.py v11_sel rows [K=2]      long press, drag the end handle 3 rows down; Copy; exact contiguous rows
    TQ_BUNDLE=... python3 v11.py v11_sel clear           300 rows, `clear`, pull into the history, select across 3 rows; Copy exact
    TQ_BUNDLE=... python3 v11.py v11_sel htop            htop; a long press selects; Copy; the copy is on the Mac's screen
"""
import json
import re
import sys
import time

import g14
import tq
import v8
from v8 import ev


def setup(n=200, clear_after=False):
    s, m, j = tq.ctx()
    cmd = f"clear; python3 ~/tqf/hist.py {n}" + ("; printf '\\033[H\\033[2J'" if clear_after else "")
    tq.paste_composer(cmd)
    time.sleep(3); j.hide_keyboard(); time.sleep(1.5)
    return s, m, j


def dismiss(s):
    s.tap(380, 300); time.sleep(0.6)
    _, _, j = tq.ctx()
    if s.keyboard():
        j.hide_keyboard(); time.sleep(0.8)


def words(k):
    s, m, j = setup()
    vis = g14.visible_ids(s)
    picks = vis[2:-2][:: max(1, len(vis[2:-2]) // k)][:k]
    out = []
    for y, rid in picks:
        kb = bool(s.keyboard())
        g14.pbclear(s)
        s.long_press(150, y + 6, seconds=0.9); time.sleep(0.6)
        v8.shot(f"sel-word-{rid}")
        ok = g14.tap_copy(s); time.sleep(0.6)
        t = g14.pbpaste(s)
        full = g14.row(rid, stamp=False, color=False)
        good = bool(t) and " " not in t.strip() and t.strip() in full.split()
        out.append(ev("sel", case="word", row=rid, keyboard_up=bool(s.keyboard()), copied=ok, text=t[:80], row_text=full[:90], exact=good))
        dismiss(s)
    return out


def rows(k):
    s, m, j = setup()
    out = []
    for i in range(k):
        vis = g14.visible_ids(s)
        y0, id0 = vis[3 + 4 * i]
        g14.pbclear(s)
        s.long_press(60, y0 + 6, seconds=0.9); time.sleep(0.6)
        e = g14.handle(s, "end")
        if not e:
            out.append(ev("sel", case="rows", row=id0, note="no handles")); continue
        x, y = e.center
        s.drag(x, y, 380, y + 3 * 34, duration=0.6, steps=30, hold=0.4); time.sleep(0.6)
        v8.shot(f"sel-rows-{id0}")
        ok = g14.tap_copy(s); time.sleep(0.6)
        t = g14.pbpaste(s)
        ids = [int(m_.group(1)) for m_ in re.finditer(r"^#(\d{7})", t, re.M)]
        out.append(ev("sel", case="rows", row=id0, copied=ok, ids=ids, text=t[:300], exact=g14.exact_text(t, 200) and bool(ids) and ids[0] == id0 and len(ids) >= 2))
        dismiss(s)
    return out


def clear_case():
    s, m, j = setup(300, clear_after=True)
    v8.shot("sel-clear-0")
    for _ in range(2):
        s.swipe(200, 250, 200, 650, duration=0.4); time.sleep(1.2)
    vis = g14.visible_ids(s)
    v8.shot("sel-clear-pulled")
    if len(vis) < 6:
        return [ev("sel", case="clear", note=f"history rows not visible after the pull: {vis}", exact=False)]
    y0, id0 = vis[len(vis) // 2]
    g14.pbclear(s)
    s.long_press(60, y0 + 6, seconds=0.9); time.sleep(0.6)
    e = g14.handle(s, "end")
    if not e:
        return [ev("sel", case="clear", row=id0, note="no handles", exact=False)]
    x, y = e.center
    s.drag(x, y, 380, y + 3 * 34, duration=0.6, steps=30, hold=0.4); time.sleep(0.6)
    v8.shot("sel-clear-selected")
    ok = g14.tap_copy(s); time.sleep(0.6)
    t = g14.pbpaste(s)
    ids = [int(m_.group(1)) for m_ in re.finditer(r"^#(\d{7})", t, re.M)]
    dismiss(s)
    return [ev("sel", case="clear", row=id0, copied=ok, ids=ids, text=t[:300], exact=g14.exact_text(t, 300) and bool(ids) and ids[0] == id0)]


def htop_case():
    s, m, j = tq.ctx()
    tq.paste_composer("clear; /opt/homebrew/bin/htop")
    time.sleep(4); j.hide_keyboard(); time.sleep(2)
    v8.shot("sel-htop-0")
    g14.pbclear(s)
    # the process list's command column, mid-screen
    s.long_press(300, 420, seconds=0.9); time.sleep(0.6)
    hs = g14.handle(s, "start"); he = g14.handle(s, "end")
    v8.shot("sel-htop-selected")
    ok = g14.tap_copy(s); time.sleep(0.6)
    t = g14.pbpaste(s)
    mac = tq.mac_screen(tq.load()["seed"]["term2"])
    line_ok = bool(t.strip()) and all(w in mac for w in t.split()[:6])
    out = ev("sel", case="htop", handles=bool(hs and he), copied=ok, text=t[:200], words_on_mac_screen=line_ok)
    # leave htop: q from the key bar
    if not s.keyboard():
        s.tap_el(s.find(ident="terminal.composer.field")[0]); time.sleep(1.2)
    tq.direct_type("q"); time.sleep(1.5)
    v8.shot("sel-htop-after-q")
    return [out]


def main():
    case = sys.argv[1]
    k = int(sys.argv[2]) if len(sys.argv) > 2 else None
    res = {"words": lambda: words(k or 5), "rows": lambda: rows(k or 2), "clear": clear_case, "htop": htop_case}[case]()
    print(json.dumps(res, indent=1)[:3000])


if __name__ == "__main__":
    main()
