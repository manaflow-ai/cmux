import fv, tq, time, json, sys
s, m, j = tq.ctx()
log = {"events": []}
def ev(n, **kw):
    log["events"].append(dict(n=n, t=time.time(), **kw)); print(n, kw, flush=True)
def jumpbtn():
    return [e for e in s.find(kind="Button") if (e.label or "") in ("Scroll to bottom", "Jump to bottom")]
fv.mem("pre-s2")
log["clock"] = fv.clock_offset()
fv.run_cmd("python3 cnx-ios-e2e/fvterm/fx/stream20.py 420 20", hide=False)
ev("stream-start")
time.sleep(2)
# S2: keyboard up, following
v, t0 = fv.rec2("s2-follow-kbup"); log["s2"] = {"video": v, "t0": t0}
kb = s.keyboard(); ev("kb-up", has_kb=bool(kb))
time.sleep(75)
tq.shot("s2-kbup")
ev("ax-kbup", composer=[e.frame for e in s.find(ident="terminal.composer.field")], jump=[e.frame for e in jumpbtn()])
fv.stop(); fv.mem("s2-end")
j.hide_keyboard(); fv.touch("tap", what="hide-kb"); time.sleep(2)
# S3: read while streaming
v, t0 = fv.rec2("s3-read-stream"); log["s3"] = {"video": v, "t0": t0}
time.sleep(1.5)
fv.touch("drag", dur=0.9, what="read-drag"); ev("drag1")
s.drag(201, 250, 201, 650, 0.6, 30, 0.3)
time.sleep(2)
polls = []
for i in range(22):  # ~60 s hold, polling the jump button
    polls.append((time.time(), bool(jumpbtn()))); time.sleep(2)
ev("hold-end", jump_polls_true=sum(p[1] for p in polls), polls=len(polls))
log["hold_polls"] = polls
# fling up into history twice, then tap jump while decelerating
for k in range(3):
    fv.touch("swipe", dur=0.15, what="fling-up"); s.swipe(201, 200, 201, 760, 0.12); ev("fling", k=k)
    time.sleep(1.2)
time.sleep(3)
fv.touch("swipe", dur=0.15, what="fling-up-then-jump"); s.swipe(201, 200, 201, 760, 0.12); ev("fling-before-jump")
jb = jumpbtn(); ev("jump-found", count=len(jb), frame=jb[0].frame if jb else None)
if jb:
    fv.touch("tap", what="jump"); s.tap_el(jb[0]); ev("jump-tap")
time.sleep(4)
ev("after-jump", jump_visible=bool(jumpbtn()))
# second jump attempt: fling and tap at a pre-read location immediately (no AX lookup delay)
if jb:
    x, y = jb[0].center
    fv.touch("swipe", dur=0.15, what="fling2"); s.swipe(201, 200, 201, 760, 0.12); ev("fling2")
    time.sleep(0.25); fv.touch("tap", what="jump2"); s.tap(x, y); ev("jump2-tap")
    time.sleep(4); ev("after-jump2", jump_visible=bool(jumpbtn()))
fv.stop(); fv.mem("s3-end")
tq.shot("s3-end")
json.dump(log, open(fv.EV + "/s23-log.json", "w"), indent=1)
