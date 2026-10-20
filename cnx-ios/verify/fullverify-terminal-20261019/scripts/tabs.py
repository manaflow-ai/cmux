import fv, tq, time, json, re, subprocess
s, m, j = tq.ctx()
L = {"ev": []}
def ev(n, **kw):
    L["ev"].append(dict(n=n, t=time.time(), **kw)); print(n, kw, flush=True)
def card(name):
    c = [e for e in s.find(kind="Button") if (e.label or "").startswith(name + ",")]
    return c[0] if c else None
def ocr_ids(y0, y1, x0=0, x1=402):
    ids = []
    for x, y, w, h, t in s.ocr():
        if y0 <= y <= y1 and x0 <= x <= x1:
            ids += [int(v) for v in re.findall(r"#?0{2,}(\d{3,5})", t)]
    return ids
def mac_last_id():
    ids = re.findall(r"#(\d{7})", tq.mac_screen())
    return int(ids[-1]) if ids else None
def grid():
    s.tap_q(label="Tabs", kind="Button"); fv.touch("tap", what="grid")
def zoom(name):
    c = card(name); fv.touch("tap", what="card"); s.tap_el(c)

# --- A: shrink/expand while streaming, card content current ---
(grid() if s.find(label="Tabs", kind="Button") else None); time.sleep(1.2); zoom("e2e-t1"); time.sleep(1.5)
fv.run_cmd("python3 cnx-ios-e2e/fvterm/fx/stream20.py 240 20")
time.sleep(4)
v, t0 = fv.rec2("tabs-a-grid"); L["a"] = {"video": v, "t0": t0}
cards = []
for k in range(6):
    time.sleep(1.0)
    ta = time.time(); grid(); ev("shrink", k=k)
    time.sleep(1.3)
    c = card("e2e-t1")
    if c:
        x, y, w, h = c.frame
        for rep in range(2):
            t_o = time.time(); ph = ocr_ids(y + 30, y + h, x, x + w); mac = mac_last_id(); t_m = time.time()
            cards.append({"k": k, "rep": rep, "card_max": max(ph) if ph else None, "mac_last": mac, "t": t_o, "dt_mac": round(t_m - t_o, 2)})
            print(cards[-1], flush=True); time.sleep(1.0)
    zoom("e2e-t1"); ev("expand", k=k)
    time.sleep(1.5)
fv.stop(); L["cards"] = cards
# --- B: close asks while a program runs (3x Cancel) ---
closes = []
for k in range(3):
    grid(); time.sleep(1.3)
    btn = [e for e in s.find(kind="Button") if e.label == "Close e2e-t1"] or [e for e in s.find(label="Close", kind="Button")][:1]
    t = time.time(); s.tap_el(btn[0]); fv.touch("tap", what="close")
    alert = None
    while time.time() - t < 5:
        texts = [e.label for e in s.tree() if e.label and ("Close" in e.label or "running" in e.label.lower() or "Still" in e.label)]
        canc = s.find(label="Cancel", kind="Button")
        if canc:
            alert = texts; break
        time.sleep(0.2)
    closes.append({"k": k, "asked": bool(alert), "s": round(time.time() - t, 2), "texts": alert})
    print(closes[-1], flush=True)
    if alert:
        s.tap_el(s.find(label="Cancel", kind="Button")[0]); time.sleep(1)
    kept = bool(card("e2e-t1")); closes[-1]["kept"] = kept
    zoom("e2e-t1"); time.sleep(1.5)
L["closes"] = closes
json.dump(L, open(fv.EV + "/tabs-ab.json", "w"), indent=1, default=str)
