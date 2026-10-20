import fv, tq, time, json, sys
s, m, j = tq.ctx()
TERM = "term_edb313a21774f41fe41ccd71b8f8275d"
loops = int(sys.argv[1]); base = int(sys.argv[2])
log = fv.EV + "/agent-session.jsonl"
def ev(n, **kw):
    fv.jl(log, dict(n=n, t=time.time(), **kw)); print(n, kw, flush=True)
def jump():
    jb = [e for e in s.find(kind="Button") if e.label in ("Scroll to bottom", "Jump to bottom")]
    if jb: s.tap_el(jb[0]); fv.touch("tap", what="jump")
    return bool(jb)
P = ["Without using any tools, write a numbered list of 160 short lines (N. then 6-10 words) about terminal emulators, scrollback and PTYs.",
     "Without tools, print a unified diff (about 120 lines) that adds a ring buffer to a hypothetical Swift scrollback class, with context lines.",
     "Without tools, write 140 numbered lines describing keyboard shortcuts in vim, each on its own line.",
     "Without tools, write a markdown table with 80 rows comparing fictional terminal fonts (name, size, ligatures, notes)."]
for k in range(loops):
    i = base + k
    fv.mem(f"agent-loop{i}-start")
    s.tap_q(ident="terminal.composer.field"); time.sleep(0.6)
    tq.paste_composer(P[i % len(P)]); fv.touch("tap", what="send-prompt"); ev("prompt", i=i)
    time.sleep(1); j.hide_keyboard(); time.sleep(4)
    v, t0 = fv.rec2(f"agent-follow-{i}"); ev("rec-follow", i=i, t0=t0)
    for _ in range(6): time.sleep(10); fv.mem(f"agent-follow{i}")
    fv.stop()
    # read while streaming (or idle) for 30 s
    v, t0 = fv.rec2(f"agent-read-{i}"); ev("rec-read", i=i, t0=t0)
    time.sleep(1); fv.touch("drag", dur=0.9, what="read"); s.drag(201, 250, 201, 600, 0.6, 30, 0.3)
    for _ in range(3): time.sleep(10); fv.mem(f"agent-read{i}")
    ev("jump", i=i, found=jump()); time.sleep(3)
    fv.stop()
    # grid round trips x2
    for _ in range(2):
        s.tap_q(label="Tabs", kind="Button"); time.sleep(1.5)
        c = [e for e in s.find(kind="Button") if (e.label or "").endswith(", tab") and not e.label.startswith("e2e-t1")]
        if c: s.tap_el(c[0])
        time.sleep(2)
    scr = tq.rsh(f"cd ~/cnx-ios-e2e/fvterm && python3 rmac.py cli terminal {TERM} screen read").stdout
    ev("loop-end", i=i, mac_tail=scr[-300:])
