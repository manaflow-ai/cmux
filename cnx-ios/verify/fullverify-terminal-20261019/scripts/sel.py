import fv, tq, time, json, subprocess
s, m, j = tq.ctx()
L = {}
j.hide_keyboard(); time.sleep(0.5)
s.tap_q(label="Tabs", kind="Button"); time.sleep(1.3)
c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1,")]; s.tap_el(c[0]); time.sleep(2)
subprocess.run(["xcrun", "simctl", "pbcopy", s.udid], input="EMPTY", text=True)
res = []
ocr = [o for o in s.ocr() if 100 < o[1] < 700 and o[4].strip().isdigit()]
for o in ocr[:5]:
    x, y, w, h, t = o
    s.long_press(x + w / 2, y + h / 2, 0.8); fv.touch("tap", dur=0.8, what="longpress"); time.sleep(1.0)
    menu = [e.label for e in s.tree() if e.label in ("Copy", "Select All", "Paste")]
    cp = s.find(label="Copy")
    got = None
    if cp:
        s.tap_el(cp[0]); time.sleep(0.6)
        got = subprocess.run(["xcrun", "simctl", "pbpaste", s.udid], capture_output=True, text=True).stdout
    res.append({"word": t.strip(), "menu": menu, "copied": got, "exact": (got or "").strip() == t.strip()})
    print(res[-1], flush=True)
    s.tap(201, 400); time.sleep(0.5)
L["selections"] = res
json.dump(L, open(fv.EV + "/selection.json", "w"), indent=1)
