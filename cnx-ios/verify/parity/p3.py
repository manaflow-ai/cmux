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
