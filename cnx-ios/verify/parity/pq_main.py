"""Parity round 2, orchestrator flows (agents: Codex, harnesses behind a local model
proxy, the Mac's last pick; Restart Shell). Same rig helpers as pq.py; each flow records
a video in PQ_RAW and proves the Mac side with the rig Mac's CLI."""
import json
import time

import pq
from journey import Fail, check


def start_with(j, harness_label, model_label=None):
    """+ > New Agent Chat With… > Harness row > (Model row) > Start Chat."""
    s = j.sim
    pq.plus_menu(j, "New Agent Chat With…")
    row = s.wait(prefix=harness_label, kind="Button", timeout=15)
    check(row, f"no harness row {harness_label!r}")
    s.tap_el(row)
    time.sleep(0.8)
    if model_label:
        m = s.wait(prefix=model_label, kind="Button", timeout=8)
        check(m, f"no model row {model_label!r}")
        s.tap_el(m)
        time.sleep(0.5)
    s.tap_el(s.wait(label="Start Chat", kind="Button", timeout=5))
    return pq.wait_opened(j, timeout=120)


def agent(harness_label, name, prompt="Reply with exactly the word PONG and nothing else.", expect="PONG",
          timeout=240):
    """A phone-started chat on `harness_label` answers `prompt` with `expect`."""
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    pq.rec_start(name)
    try:
        opened, toast = start_with(j, harness_label)
        check(not toast, f"start refused: {toast}")
        took, text = pq.chat_prompt(j, prompt, expect, timeout=timeout)
        pq.shot(name)
        return {"opened_s": round(opened, 1), "reply_s": round(took, 1), "reply": text[:120]}
    finally:
        pq.rec_stop()


def acpmux_sessions():
    """The rig Mac's acpmux sessions (harness, mode, policy, cwd), newest last."""
    r = pq.rsh("cd ~/cnx-ios-e2e && ls >/dev/null; true")
    return r.stdout


def restart_shell():
    """Restart Shell Here, live (SECURITY.md rule 4): a terminal the Mac keeps after its
    shell ends (`set-terminal-keep`, the Mac's Keep Running), the shell exits, the phone
    shows the ended shell and restarts it; the Mac lists a NEW shell process for the same
    tab, on the Mac (its pid on the rig Mac, a new incarnation)."""
    import pq_tabs as t
    ws = t.seed("restart", terminals=1)
    name = ws.get("name") or ws.get("title")
    surface = t.ws_tabs(ws)[0][1]["surface"]
    t.mac_raw({"cmd": "set-terminal-keep", "surface": surface, "keep": True})
    s, m, j = pq.ctx()
    pq.rec_start("restart-shell")
    try:
        t.open_ws(j, name)
        t.open_tab(j, "p2tabs-t1")
        before = t.mac_raw({"cmd": "process-info", "surface": surface})
        # The shell exits (typed on the phone, as the person would).
        pq.type_text("exit\n")
        dead, took = t.until(lambda: next((tab for _, tab in t.ws_tabs(t.mac_workspace(name=name))
                                           if tab["surface"] == surface and tab.get("dead")), None),
                             timeout=30, what="the shell to end on the Mac")
        btn = s.wait(label="Restart Shell Here", kind="Button", timeout=20)
        check(btn, "no Restart Shell Here on the phone")
        pq.shot("restart-overlay")
        s.tap_el(btn)
        live, took2 = t.until(lambda: next((tab for _, tab in t.ws_tabs(t.mac_workspace(name=name))
                                            if tab["surface"] == surface and not tab.get("dead")), None),
                              timeout=30, what="the Mac to restart the shell")
        after = t.mac_raw({"cmd": "process-info", "surface": surface})
        time.sleep(2)
        pq.type_text("echo restarted-$((6*7)) $$\n")
        time.sleep(3)
        pq.shot("restart-after")
        return {"ended_s": round(took, 1), "restarted_s": round(took2, 1),
                "before": json.dumps(before)[:300], "after": json.dumps(after)[:300]}
    finally:
        pq.rec_stop()
