import fv, tq, time, json, re
s, m, j = tq.ctx()
L = {}
fv.run_cmd("python3 cnx-ios-e2e/fvterm/fx/stream20.py 600 20")
time.sleep(4)
# D: app terminate + relaunch mid-stream
v, t0 = fv.rec2("life-d-relaunch"); L["d_t0"] = t0
time.sleep(2)
t_kill = time.time(); s.terminate(tq.BUNDLE); fv.touch("tap", what="terminate"); time.sleep(1.5)
t_launch = time.time(); s.launch(tq.BUNDLE, terminate=False); fv.touch("tap", what="launch")
f = s.wait(ident="terminal.composer.field", timeout=15)
L["d"] = {"t_kill": t_kill - t0, "t_launch": t_launch - t0, "composer_s": round(time.time() - t_launch, 2) if f else None}
live = None
while time.time() - t_launch < 15:
    pill = [e.label for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1,")]
    if pill and pill[0] == "e2e-t1, ~" and not s.find(ident="terminal.connecting"):
        live = round(time.time() - t_launch, 2); break
    time.sleep(0.25)
L["d"]["live_pill_s"] = live
time.sleep(6)
fv.stop()
# E: kill -9 cnx-hostd mid-stream (fault injection)
v, t0 = fv.rec2("life-e-hostd-kill"); L["e_t0"] = t0
time.sleep(3)
tk = time.time(); r = tq.rsh('pkill -9 -f "cnx-e2e-90375ce5.app/Contents/Resources/bin/cnx-hostd"'); L["e_kill"] = tk - t0
pills = []
while time.time() - tk < 20:
    pill = [e.label for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1,")]
    pills.append((round(time.time() - tk, 2), pill[0] if pill else None)); time.sleep(0.3)
L["e_pills"] = pills
time.sleep(3)
fv.stop()
L["hostd_log"] = tq.rsh('tail -60 "$HOME/Library/Application Support/com.cmuxterm.app.debug.cnx.e2e.90375ce5/cnx-host/cnx-hostd.log" | grep -E "listening|signaling connected|link up" | tail -4 | cut -c1-140').stdout
json.dump(L, open(fv.EV + "/life-de.json", "w"), indent=1, default=str)
print(json.dumps({k: L[k] for k in ("d", "e_kill")}), [p for i, p in enumerate(pills) if i == 0 or p[1] != pills[i - 1][1]], L["hostd_log"])
