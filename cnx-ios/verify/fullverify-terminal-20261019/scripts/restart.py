import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
j.hide_keyboard(); time.sleep(0.5)
s.tap_q(label="Tabs", kind="Button"); time.sleep(1.3)
c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t2,")]; s.tap_el(c[0]); time.sleep(2)
v, t0 = fv.rec2("restart-shell")
t = time.time(); tq.composer_send("exit"); fv.touch("tap", what="send-exit"); j.hide_keyboard()
btn = s.wait(label="Restart Shell Here", kind="Button", timeout=20)
L["overlay_s"] = round(time.time() - t, 2) if btn else None
L["overlay_texts"] = [e.label for e in s.tree() if e.label and ("ended" in e.label or "Restart" in e.label)]
tq.shot("restart-overlay")
if btn:
    t2 = time.time(); s.tap_el(btn); fv.touch("tap", what="restart")
    ok = None
    while time.time() - t2 < 20:
        if not s.find(label="Restart Shell Here", kind="Button") and any("%" in o[4] for o in s.ocr() if o[1] < 740):
            ok = round(time.time() - t2, 2); break
        time.sleep(0.3)
    L["restart_to_prompt_s"] = ok
    time.sleep(1)
    tok = "echo RESTARTED$((6*7))"
    tq.composer_send(tok); fv.touch("tap", what="send-after-restart"); time.sleep(2.5); j.hide_keyboard()
    L["works_after"] = "RESTARTED42" in tq.mac_screen(tq.load()["seed"]["term2"])
    tq.shot("restart-after")
fv.stop()
json.dump(L, open(fv.EV + "/restart-shell.json", "w"), indent=1); print(L)
