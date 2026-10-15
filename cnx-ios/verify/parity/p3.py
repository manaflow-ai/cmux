"""Parity round 3, orchestrator flows: the round-2 items that were only unit-tested, driven
live (the Mac's last pick, queued prompts, a Mac-started Codex chat in Agent mode), then the
round-3 lanes. Same rig as pq.py (env PQ_SIM, PQ_STATE, PQ_RAW, PQ_RBASE, PQ_HOST).

Mac-side picks go through the rig Mac's own New Tab page (its real UI), driven in the
background with cua-driver on the rig mini (`cuax.py`, accessibility actions only).
"""
import json
import shlex
import time

import pq
from journey import Fail, check


def acp(method, params, timeout=60):
    """One acpmux call on the rig Mac's own socket (the Mac side, never the phone's lane)."""
    tag = pq.rsh(f"cd {pq.RBASE} && python3 -c 'import sys; sys.path[:0]=[\"e2e\",\".\"]; import rmac; print(rmac.mac().tag)'").stdout.strip()
    sock = f"~/.acpmux/tags/{tag}/acpmux.sock"
    r = pq.rsh(f"python3 {pq.RBASE}/acpcall.py {sock} {shlex.quote(method)} {shlex.quote(json.dumps(params))}", timeout=timeout)
    out = (r.stdout or "").strip().splitlines()
    return json.loads(out[-1]) if out else {"error": r.stderr[-300:]}


def sessions():
    """The rig Mac's acpmux sessions (`_acpmux/sessions`)."""
    r = acp("_acpmux/sessions", {})
    res = r.get("result") or {}
    return res.get("sessions", res if isinstance(res, list) else [])


def proj():
    return pq.rsh(f"cd {pq.RBASE}/proj && pwd").stdout.strip()


def trust(folder):
    return acp("acp.trust.set", {"cwd": folder, "level": "trusted"})


def last_picks():
    return (acp("_acpmux/harnesses", {}).get("result") or {}).get("lastPicks")


def flow_last_pick(expect_model="claude-haiku-5-5"):
    """The Mac's New Tab page picked Haiku (its real UI); the phone's New Agent Chat in a
    workspace folder the Mac never picked in starts on the Mac's global pick."""
    picks = last_picks()
    check(picks and (picks.get("global") or {}).get("model") == expect_model, f"Mac pick not in acpmux: {picks}")
    folder = proj()
    trust(folder)
    before = {s.get("sessionId") or s.get("id") for s in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    pq.rec_start("last-pick")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        took, text = pq.chat_prompt(j, "Reply with exactly the word PONG and nothing else.", "PONG", timeout=180)
        pq.shot("last-pick")
    finally:
        pq.rec_stop()
    new = [x for x in sessions() if (x.get("sessionId") or x.get("id")) not in before]
    check(new, "no new acpmux session on the Mac")
    sess = new[-1]
    return {"picks": picks, "session": {k: sess.get(k) for k in ("harness", "model", "modelId", "cwd", "policy", "mode", "currentModeId")},
            "opened_s": round(opened, 1), "reply_s": round(took, 1)}


def session(sid):
    return next((x for x in sessions() if x.get("sessionId") == sid), None)


def face_id(match=True):
    udid = pq.load()["udid"]
    sp = ["xcrun", "simctl", "spawn", udid, "notifyutil"]
    pq.subprocess.run(sp + ["-s", "com.apple.BiometricKit.enrollmentChanged", "1"], capture_output=True)
    pq.subprocess.run(sp + ["-p", "com.apple.BiometricKit.enrollmentChanged"], capture_output=True)
    if match is not None:
        time.sleep(1.5)
        pq.subprocess.run(sp + ["-p", "com.apple.BiometricKit_Sim.pearl." + ("match" if match else "nomatch")], capture_output=True)


def type_send(j, text):
    """The chat composer (also while a turn runs), then Send."""
    s = j.sim
    f = (s.wait(kind="TextView", timeout=4) or s.wait(kind="TextField", timeout=2)
         or s.wait(contains="Reply to", kind="Button", timeout=8))
    # While a reply streams the accessibility tree can come back empty: the composer is
    # where it always is (above the toolbar).
    # Never a blind tap: the permission bar takes the composer's place (its Deny is there).
    check(f, "no composer (a permission bar in its place?)")
    s.tap_el(f)
    time.sleep(0.8)
    pq.type_text(text)
    time.sleep(0.6)
    send = s.wait(label="Send", kind="Button", timeout=5)
    check(send, "no Send button after typing")
    s.tap_el(send)
    time.sleep(1.5)


def queued_row(j, word):
    """A queued prompt's row: its text beside a "Remove queued message" button (the
    workspace page's identifier covers the row's own `chat.queued`)."""
    s = j.sim
    els = s.find()
    xs = [e for e in els if e.label == "Remove queued message"]
    for e in els:
        if word in (e.label or "") and e.kind == "StaticText" and \
                any(abs(x.center[1] - e.center[1]) < 16 for x in xs):
            return e
    return None


def wait_for(fn, what, timeout=30, every=0.5):
    t = time.time()
    while time.time() - t < timeout:
        v = fn()
        if v:
            return v, time.time() - t
        time.sleep(every)
    raise Fail(f"timed out waiting for {what}")


def hold_menu(j, el, item):
    import pq_ws
    j.sim.long_press(*el.center, 1.2)
    time.sleep(1.2)
    pq_ws.menu_item(j, item)


def flow_queue():
    """A long turn (an approved 90 s perl wait; this mini's Claude hooks block `sleep`), two prompts sent meanwhile queue on the Mac;
    Move up, Edit queued prompt and Send now from the phone, each read back on the Mac."""
    folder = proj()
    trust(folder)
    before = {x.get("sessionId") for x in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    out = {}
    pq.rec_start("queue")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        face_id(match=None)
        type_send(j, "Use your Bash tool in the foreground to run ./wait90.sh then reply DONE-WAIT")
        sid = wait_for(lambda: next((x["sessionId"] for x in sessions() if x.get("sessionId") not in before), None),
                       "the new session on the Mac", 30)[0]
        # Allow each permission the agent asks for (Face ID), until the command runs.
        t0 = time.time()
        while time.time() - t0 < 120:
            x = session(sid) or {}
            if x.get("pendingPermissions"):
                allow = s.find(label="Allow once", kind="Button") or s.find(label="Allow Once", kind="Button")
                if allow:
                    pq.shot("queue-permission")
                    s.tap_el(allow[0])
                    time.sleep(1.5)
                    face_id(True)
                    time.sleep(2)
                    continue
            elif x.get("turn") and s.find(label="Running, ./wait90.sh") and s.find(contains="Reply to", kind="Button"):
                break
            time.sleep(1)
        check((session(sid) or {}).get("turn"), "the turn ended before the second prompt (the command did not wait)")
        check(not (session(sid) or {}).get("pendingPermissions"), "a permission still waits")
        type_send(j, "Reply with exactly QUEUED-ALPHA")
        type_send(j, "Reply with exactly QUEUED-CHARLIE")
        q, _ = wait_for(lambda: (lambda x: x and len(x.get("queue") or []) == 2 and x["queue"])(session(sid)),
                        "two prompts queued on the Mac", 20)
        out["queued_on_mac"] = [json.dumps(e)[:160] for e in q]
        wait_for(lambda: queued_row(j, "QUEUED-CHARLIE"), "the queued rows on the phone", 15)
        pq.shot("queue-two")
        hold_menu(j, queued_row(j, "QUEUED-CHARLIE"), "Move up")
        q, took = wait_for(lambda: (lambda x: x and "CHARLIE" in json.dumps((x.get("queue") or [{}])[0]) and x["queue"])(session(sid)),
                           "CHARLIE first on the Mac", 15)
        out["move_up_s"] = round(took, 1)
        hold_menu(j, queued_row(j, "QUEUED-ALPHA"), "Edit queued prompt")
        field = s.wait(kind="TextField", timeout=5) or s.wait(kind="TextView", timeout=3)
        check(field, "no edit field")
        # The caret at the end of the old text (a tap in the middle puts it there).
        fx, fy, fw, fh = field.frame
        s.tap(fx + fw - 6, fy + fh / 2)
        time.sleep(0.5)
        pq.subprocess.run(["axe", "key", "77", "--udid", pq.load()["udid"]], capture_output=True, timeout=20)
        for _ in range(len("ALPHA")):
            pq.subprocess.run(["axe", "key", "42", "--udid", pq.load()["udid"]], capture_output=True, timeout=20)
        pq.type_text("BRAVO")
        time.sleep(0.5)
        import pq_ws
        pq_ws.menu_item(j, "Save")
        q, took = wait_for(lambda: (lambda x: x and "QUEUED-BRAVO" in json.dumps(x.get("queue") or []) and x["queue"])(session(sid)),
                           "the edited prompt on the Mac", 15)
        out["edit_s"] = round(took, 1)
        out["queue_after_edit"] = [json.dumps(e)[:160] for e in q]
        wait_for(lambda: queued_row(j, "QUEUED-BRAVO"), "BRAVO on the phone", 10)
        pq.shot("queue-edited")
        hold_menu(j, queued_row(j, "QUEUED-BRAVO"), "Send now")
        q, took = wait_for(lambda: (lambda x: x is not None and "QUEUED-BRAVO" not in json.dumps(x.get("queue") or []) and (x.get("queue") or [None]))(session(sid)),
                           "BRAVO to leave the Mac's queue", 20)
        out["send_now_s"] = round(took, 1)
        out["queue_after_send_now"] = [json.dumps(e)[:160] for e in (q if isinstance(q, list) else [])]
        wait_for(lambda: [e for e in s.find(contains="QUEUED-BRAVO") if "Reply with" not in (e.label or "")
                          and e.ident != "chat.queued"], "the BRAVO answer", 200, 2)
        wait_for(lambda: [e for e in s.find(contains="QUEUED-CHARLIE") if "Reply with" not in (e.label or "")
                          and e.ident != "chat.queued"], "the CHARLIE answer", 200, 2)
        pq.shot("queue-done")
        out["session"] = sid
        return out
    finally:
        pq.rec_stop()
