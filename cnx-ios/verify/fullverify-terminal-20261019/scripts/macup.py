import fv, tq, time, json, subprocess
s, m, j = tq.ctx()
log = {}
v, t0 = fv.rec2("life13-mac-relaunch"); log["t0"] = t0
time.sleep(2)
t_launch = time.time()
r = tq.rsh("cd ~/cnx-ios-e2e/fvterm && python3 rmac.py launch", timeout=300)
t_ret = time.time(); log["launch_out"] = r.stdout.strip(); log["t_launch_cmd"] = t_launch; log["t_launch_ret"] = t_ret
# hostd listening time from its log (first 'signaling connected' after launch), read later
polls = []
while time.time() - t_ret < 40:
    pill = [e.label for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1,")]
    polls.append((round(time.time() - t0, 2), pill[0] if pill else None))
    if pill and "Reattach" not in pill[0] and "ffline" not in pill[0] and "onnect" not in pill[0]:
        break
    time.sleep(0.3)
log["pill_polls"] = polls
time.sleep(3)
tok = "echo FVAFTER%d" % (int(time.time()) % 100000)
tq.composer_send(tok); fv.touch("tap", what="send-after-relaunch"); time.sleep(3)
log["after_tok_arrived"] = tok.split()[1] in tq.mac_screen()
fv.stop()
log["hostd_log_tail"] = tq.rsh('tail -40 "$HOME/Library/Application Support/com.cmuxterm.app.debug.cnx.e2e.90375ce5/cnx-host/cnx-hostd.log" | grep -E "signaling connected|link up|registered" | tail -4').stdout
json.dump(log, open(fv.EV + "/life13-mac-relaunch.json", "w"), indent=1)
print(json.dumps({k: log[k] for k in ("launch_out", "after_tok_arrived")}), log["pill_polls"][:3], log["pill_polls"][-3:], round(t_ret - t_launch, 2), round(t_ret - t0, 2))
print(log["hostd_log_tail"])
