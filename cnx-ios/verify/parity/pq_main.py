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


def term_type(s, line):
    """Types `line` into the terminal page's composer and sends it (Return)."""
    f = s.find(kind="TextArea") or [e for e in s.find() if (e.label or "").startswith("Send to")]
    check(f, "no terminal composer")
    s.tap_el(f[0])
    time.sleep(0.6)
    pq.type_text(line)
    time.sleep(0.4)
    r = s.find(label="Return", kind="Button")
    check(r, "no Return button")
    s.tap_el(r[0])
    time.sleep(0.5)


def _tab(t, name, surface):
    return next((tab for _, tab in t.ws_tabs(t.mac_workspace(name=name)) if tab["surface"] == surface), None)


def _shell_pid(t, surface):
    try:
        return t.mac_raw({"cmd": "process-info", "surface": surface}).get("pid")
    except Exception:
        return None


def restart_shell():
    """Restart Shell Here, live (SECURITY.md rule 4). The rig Mac runs a shell whose tab
    stays after the shell ends (`run --on-exit keep`, as a person can on the Mac); the
    phone types `exit` into it, sees the ended shell and restarts it; the Mac lists a NEW
    shell process for the same tab, running on the Mac (pid and parent on the rig Mac)."""
    import pq_tabs as t
    ws = t.seed("restart", terminals=1)
    name = ws.get("name") or ws.get("title")
    pane = t.ws_tabs(ws)[0][0]
    surface = t.mac_raw({"cmd": "run", "argv": ["/bin/zsh", "-l"], "pane": pane, "name": "p2-keep",
                         "on_exit": "keep"})["surface"]
    s, m, j = pq.ctx()
    pq.rec_start("restart-shell")
    try:
        t.open_ws(j, name)
        t.open_tab(j, "p2-keep")
        before = _shell_pid(t, surface)
        term_type(s, "exit")
        t.until(lambda: (lambda x: x if x and x.get("dead") else None)(_tab(t, name, surface)),
                timeout=30, what="the shell to end on the Mac")
        btn = s.wait(label="Restart Shell Here", kind="Button", timeout=30)
        check(btn, "no Restart Shell Here on the phone")
        time.sleep(1)
        pq.shot("restart-overlay")
        s.tap_el(btn)
        _, took = t.until(lambda: (lambda x: x if x and not x.get("dead") else None)(_tab(t, name, surface)),
                          timeout=40, what="the Mac to restart the shell")
        pid = None
        for _ in range(20):
            pid = _shell_pid(t, surface)
            if pid and pid != before:
                break
            time.sleep(1)
        on_mac = pq.rsh(f"ps -o pid,ppid,command -p {pid}").stdout.strip() if pid else ""
        time.sleep(2)
        term_type(s, "echo restarted-$((6*7))")
        time.sleep(3)
        pq.shot("restart-after")
        return {"restarted_s": round(took, 1), "before_pid": before, "after_pid": pid, "shell_on_mac": on_mac[-200:]}
    finally:
        pq.rec_stop()
