import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
known = {"93649"}
v, t0 = fv.rec2("restart-shell")
kills = []; t = time.time(); btn = None
while time.time() - t < 240:
    btn = s.find(label="Restart Shell Here", kind="Button")
    if btn: break
    hosts = tq.rsh("for h in $(pgrep -f '__terminal-host.*90375ce5'); do pgrep -P $h >/dev/null && echo $h; done").stdout.split()
    for p in hosts:
        if p in known: continue
        tq.rsh(f"pkill -9 -P {p}; kill -9 {p}"); kills.append((round(time.time() - t, 1), p))
    time.sleep(1.0)
L["kills"] = kills; L["dead_after_s"] = round(time.time() - t, 1) if btn else None
L["overlay_texts"] = [e.label for e in s.tree() if e.label and ("ended" in e.label or "Restart" in e.label or "stopped" in e.label)]
tq.shot("restart-overlay")
if btn:
    t2 = time.time(); s.tap_el(btn[0]); fv.touch("tap", what="restart")
    ok = None
    while time.time() - t2 < 30:
        if not s.find(label="Restart Shell Here", kind="Button"):
            ok = round(time.time() - t2, 2); break
        time.sleep(0.3)
    L["overlay_gone_s"] = ok
    time.sleep(2)
    tq.composer_send("echo RESTARTED$((6*7))"); time.sleep(3); j.hide_keyboard()
    L["works_after"] = "RESTARTED42" in tq.rsh("cd ~/cnx-ios-e2e/fvterm && for t in $(python3 rmac.py cli terminal list | awk 'NR>1{print $1}'); do python3 rmac.py cli terminal $t screen read; done").stdout
    tq.shot("restart-after")
fv.stop()
json.dump(L, open(fv.EV + "/restart-shell.json", "w"), indent=1); print(L)
