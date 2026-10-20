import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
tq.composer_send("clear; seq 1 300; top -s 1"); fv.touch("tap", what="send-top")
time.sleep(2); j.hide_keyboard(); time.sleep(2)
v, t0 = fv.rec2("tui-top"); L["t0"] = t0
time.sleep(2)
ev = []
for k in range(10):
    y1, y2 = (250, 550) if k % 2 == 0 else (550, 250)
    ev.append(time.time() - t0); s.drag(201, y1, 201, y2, 0.5, 30, 0.2); fv.touch("drag", dur=0.7, what="tui-drag"); time.sleep(0.8)
L["drags"] = ev
tq.shot("tui-after-drags")
L["mac_top_bottom"] = [l for l in tq.mac_screen().splitlines() if l.strip()][-2:]
# keyboard show/hide x4 over top
kb = []
for k in range(4):
    kb.append(("show", time.time() - t0)); s.tap_q(ident="terminal.composer.field"); time.sleep(2.5)
    kb.append(("hide", time.time() - t0)); j.hide_keyboard(); time.sleep(2.5)
L["kb"] = kb
# quit with q via the soft keyboard, check prompt and scrollback
s.tap_q(ident="terminal.composer.field"); time.sleep(1)
tq_t = time.time(); j.focus_terminal() if not s.keyboard() else None
s.softtype("q"); L["q_t"] = time.time() - t0
time.sleep(2)
fv.stop()
tq.shot("tui-after-q")
ocr = s.ocr()
L["prompt_after_q"] = [o[4] for o in ocr if "%" in o[4] and "cmux" in o[4]]
j.hide_keyboard()
json.dump(L, open(fv.EV + "/tui-top.json", "w"), indent=1, default=str); print(json.dumps(L, default=str)[:1500])
