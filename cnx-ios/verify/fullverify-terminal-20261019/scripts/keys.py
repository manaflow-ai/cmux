import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
# stop the running stream from the key bar (^C) and measure the stop
s.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
t = time.time(); j.keybar("Control C"); fv.touch("key", what="^C")
time.sleep(1.5); scr = tq.mac_screen(); L["ctrlc_stopped"] = "^C" in scr[-400:] or "KeyboardInterrupt" in scr[-800:]
# key bar + softkeys: the rig's own term_keys step (phone-only input)
try:
    L["term_keys"] = j._term_keys()
except Exception as e:
    L["term_keys"] = f"FAIL: {e}"[:900]
# joystick: flick = 1 arrow, hold = repeat
j.focus_terminal(); s.softtype("echo abcdefghijklmnopqrstuvwxyz0123456789"); time.sleep(1)
js = s.find(label="Cursor joystick")
res = {}
if js:
    cx, cy = js[0].center
    col = lambda: m.cmux("terminal", tq.term(), "screen", "read", json_out=True).get("cursor_col")
    b = col(); fl = []
    for k in range(5):
        s.drag(cx, cy, cx - 22, cy, duration=0.12, hold=0.0); fv.touch("drag", dur=0.12, what="joy-flick"); time.sleep(0.6)
        a = col(); fl.append(None if None in (a, b) else b - a); b = a
    s.drag(cx, cy, cx - 30, cy, duration=0.2, hold=2.0); fv.touch("drag", dur=2.2, what="joy-hold"); time.sleep(0.8)
    a = col(); res = {"flicks": fl, "hold_2s_cols": None if None in (a, b) else b - a}
    time.sleep(1.0); c = col(); res["after_release_cols"] = None if None in (a, c) else a - c
L["joystick"] = res
j.keybar("Control C"); time.sleep(0.5)
json.dump(L, open(fv.EV + "/keys.json", "w"), indent=1, default=str); print(json.dumps(L, default=str)[:2500])
