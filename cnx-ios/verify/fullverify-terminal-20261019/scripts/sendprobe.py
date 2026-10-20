import fv, tq, time, json, sys
s, m, j = tq.ctx()
res = []
v, t0 = fv.rec2("probe-send")
for i in range(int(sys.argv[1]) if len(sys.argv) > 1 else 4):
    tok = f"echo FVP{i}x{int(time.time())%100000}"
    before = s.find(ident="terminal.composer.field")
    t = time.time(); tq.composer_send(tok); fv.touch("tap", what="send-probe")
    fld = s.find(ident="terminal.composer.field")
    time.sleep(2.0)
    scr = tq.mac_screen()
    res.append({"i": i, "t": round(t - t0, 2), "tok": tok, "arrived": tok.split()[1] in scr, "field_after": fld[0].value if fld else None})
    print(res[-1], flush=True)
fv.stop()
json.dump(res, open(fv.EV + "/probe-send.json", "w"), indent=1)
