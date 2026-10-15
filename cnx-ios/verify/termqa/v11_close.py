"""Round-11 verifier, T-TABS-08 / V5-5: + -> New Terminal on the phone; optionally start a
program in it from the phone's composer; then close its card (x) in the grid. Records whether
the close question appeared, confirms it, and reads the Mac (oracle only): the terminal list
every 0.25 s until the new terminal is gone, the program's process, and that the seed tabs'
terminals are still listed (no wrong-tab close).

    TQ_BUNDLE=... python3 v11.py v11_close MODE [RUNS]
MODE: idle | sleep (a foreground `sleep 6NNN`) | yes (`yes > /dev/null`) | codex (`codex "V11MARK-N ..."`)
"""
import json
import sys
import time

import tq
import v8
from v8 import ev


def mac_terms():
    out = tq._mac().cmux("terminal", "list", json_out=True)
    rows = out if isinstance(out, list) else out.get("terminals", [])
    return {t.get("id") or t.get("terminal_id"): t for t in rows}


def cards(s):
    return [e for e in s.find(kind="Button") if (e.label or "").endswith(", tab")]


def grid(s):
    if not cards(s):
        s.tap_q(label="Tabs", kind="Button"); time.sleep(2.5)


def proc(pattern):
    r = tq.rsh(f"pgrep -fl {json.dumps(pattern)} | grep -v pgrep | head -3")
    return r.stdout.strip()


def one(i, mode):
    s, m, j = tq.ctx()
    st = tq.load()["seed"]
    grid(s)
    before = mac_terms()
    for _ in range(3):
        s.tap(62, 812)
        if s.wait(label="New Terminal", kind="Button", timeout=4):
            break
    s.tap_q(label="New Terminal", kind="Button")
    t = time.time(); new = None
    while time.time() - t < 20 and not new:
        new = [k for k in mac_terms() if k not in before]
        time.sleep(0.5)
    if not s.find(ident="terminal.composer.field"):
        s.wait(ident="terminal.composer.field", timeout=10)
    mark = f"{6000 + int(time.time()) % 1000}"
    cmd = {"idle": None, "sleep": f"sleep {mark}", "yes": f"yes V11YES{mark} > /dev/null",
           "codex": f'codex "V11MARK-{mark} reply with one word"'}[mode]
    pat = {"idle": None, "sleep": f"sleep {mark}", "yes": f"yes V11YES{mark}", "codex": f"V11MARK-{mark}"}[mode]
    p_before = ""
    if cmd:
        time.sleep(1.5)
        tq.paste_composer(cmd)
        time.sleep(6 if mode == "codex" else 3)
        j.hide_keyboard(); time.sleep(1)
        p_before = proc(pat)
    title_before = [e.label for e in s.find(kind="Button") if e.ident is None and ", " in (e.label or "") and e.frame[1] > 780]
    grid(s)
    cs = cards(s)
    closes = s.find(label="Close", kind="Button")
    card = cs[-1]
    x = [c for c in closes if abs(c.frame[1] - card.frame[1]) < 2 and card.frame[0] < c.frame[0] < card.frame[0] + card.frame[2]]
    tc = time.time()
    s.tap_el(x[0])
    time.sleep(1.2)
    alert = s.find(kind="Alert") or s.find(kind="Sheet")
    texts = [e.label for e in s.tree() if e.kind in ("StaticText", "Button") and e.label and e.frame[1] > 300][:12] if alert else []
    confirm_shown = bool(alert)
    tconf = None
    if alert:
        btn = [e for e in s.find(kind="Button") if e.label in ("Close", "Close Tab", "End", "Close Anyway", "Stop and Close")]
        btn = [b for b in btn if b.frame[1] > 300] or btn
        if btn:
            tconf = time.time()
            s.tap_el(btn[-1])
    t_ref = tconf or tc
    gone_at = None; prev = t_ref
    while time.time() - t_ref < 30:
        q0 = time.time()
        if new and new[0] not in mac_terms():
            gone_at = (round(prev - t_ref, 2), round(time.time() - t_ref, 2))
            break
        prev = q0
        time.sleep(0.25)
    p_after = proc(pat) if pat else ""
    terms = mac_terms()
    seeds_kept = all(st[k] in terms for k in ("term1", "term2"))
    cards_after = [e.label for e in cards(s)]
    return ev("v11_close", run=i, mode=mode, new=new, card=card.label, title_bar=title_before, confirm_shown=confirm_shown,
              alert_texts=texts, confirmed=bool(tconf), mac_gone_s_bounds=gone_at,
              proc_before=p_before[:160], proc_after=p_after[:160], seed_terminals_kept=seeds_kept, cards_after=cards_after)


def main():
    mode = sys.argv[1]
    for i in range(int(sys.argv[2]) if len(sys.argv) > 2 else 1):
        one(i, mode)


if __name__ == "__main__":
    main()
