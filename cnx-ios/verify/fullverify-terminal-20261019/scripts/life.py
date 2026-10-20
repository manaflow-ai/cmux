import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
def card(prefix):
    return [e for e in s.find(kind="Button") if (e.label or "").startswith(prefix)]
def mac_tabs():
    r = m.cmux("workspace", "list", json_out=True)
    return r
# --- C: new tab from + (grid New Tab), prompt timing; then idle close ---
(s.tap_q(label="Tabs", kind="Button") if s.find(label="Tabs", kind="Button") else None); time.sleep(1.3)
before = [e.label for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]
v, t0 = fv.rec2("life-c-newtab")
L["plus_ax"] = [repr(e) for e in s.find(kind="Button") if 780 < e.frame[1] < 840]
t = time.time(); s.tap(60, 812); fv.touch("tap", what="newtab")
time.sleep(0.8); L["plus_menu"] = [e.label for e in s.tree() if e.label and e.kind in ("Button","MenuItem")]; menu = s.wait(contains="Terminal", timeout=3)
if menu and "Tab" not in (menu.label or "x"):
    s.tap_el(menu)
L["newtab_menu"] = menu.label if menu else None
prompt_t = None
while time.time() - t < 10:
    if any("%" in o[4] and "cmux" in o[4] for o in s.ocr() if o[1] < 400):
        prompt_t = time.time() - t; break
L["newtab_prompt_s"] = round(prompt_t, 2) if prompt_t else None
tq.shot("newtab")
s.tap_q(label="Tabs", kind="Button"); time.sleep(1.3)
after = [e.label for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]
L["cards_before"], L["cards_after"] = before, after
new = [a for a in after if a not in before]
L["new"] = new
if new:
    name = new[0].split(",")[0]
    btn = [e for e in s.find(kind="Button") if e.label == f"Close {name}"]
    t = time.time(); s.tap_el(btn[0]); fv.touch("tap", what="close-idle")
    asked = bool(s.wait(label="Cancel", kind="Button", timeout=2.5))
    gone = None
    while time.time() - t < 6:
        if not [e for e in s.find(kind="Button") if (e.label or "").startswith(name + ",")]:
            gone = round(time.time() - t, 2); break
        time.sleep(0.2)
    L["idle_close"] = {"asked": asked, "card_gone_s": gone}
    time.sleep(1.5)
    ws = [w for w in (m.cmux("workspace", "list", json_out=True) or {}).get("workspaces", [])] if False else None
fv.stop()
# back to t1
c = card("e2e-t1,"); s.tap_el(c[0]); time.sleep(2)
json.dump(L, open(fv.EV + "/life-c.json", "w"), indent=1, default=str); print(L, flush=True)
