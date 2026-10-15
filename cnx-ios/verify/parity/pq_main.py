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
