"""P0 CANDIDATE new tab first keys late (agent a539d1ff2011e6d9e): the probe step `newtab_first_keys_probe`.

Each cycle plays what a person does: Cmd-N (a new workspace on the New Tab page), wait until the page reports its
field ready (debug.focus new_tab_key_log: "ready incoming" after this cycle's "begin incoming"), then type at once,
with no Ctrl-`. A key that waits in Cmd-N's New Tab hold shows as "hold key #N +Tms"; the hold ends with
"drained to field +Tms" (to the page) or "release: <why> ... +Tms" (to whatever has focus). A cycle is LATE when a
typed key was held; its delay is the end's age minus the first held key's age. At the readiness and at the end the
step keeps a compact focus snapshot (model pane and target, first responder, key window), for the cause.
It must not import driver.py (that runs as __main__ on the mini)."""
import re
import time

D = None  # the driver module (install)
AGE = re.compile(r"\+(\d+)ms$")


def install(driver):
    global D
    D = driver


def _log(j):
    reply = j.app.rpc("debug.focus", {}) or {}
    return reply, list(reply.get("new_tab_key_log") or [])


def _cycle(log):
    """The entries of the newest hold (from its last "begin incoming" on)."""
    begins = [i for i, e in enumerate(log) if e.startswith("begin incoming")]
    return log[begins[-1]:] if begins else []


def _age(entry):
    m = AGE.search(entry)
    return int(m.group(1)) if m else None


def _snap(reply):
    win = next((w for w in reply.get("windows") or [] if w.get("is_key")), None) or (reply.get("windows") or [None])[0] or {}
    model, appkit = win.get("model") or {}, win.get("appkit") or {}
    return {"key_window": reply.get("key_window"), "app_active": reply.get("app_active"),
            "pane": model.get("pane"), "target": model.get("target"), "resolved": model.get("resolved"),
            "expectation": model.get("expectation"), "first_responder": appkit.get("first_responder"),
            "classified": appkit.get("classified"), "child_window_page": appkit.get("child_window_page"),
            "layout_focused_pane": win.get("layout_focused_pane"), "recent": (win.get("recent_events") or [])[-4:]}


def step_newtab_first_keys_probe(j, step):
    cycles, text = int(step.get("cycles", 30)), str(step.get("text", "zq"))
    ready_timeout, end_timeout = float(step.get("ready_timeout", 6)), float(step.get("end_timeout", 6))
    rows = []
    for n in range(1, cycles + 1):
        row = {"cycle": n}
        j.key("n", ["cmd"])
        t0 = D.now()
        cyc, reply = [], {}
        while D.now() - t0 < ready_timeout:
            reply, log = _log(j)
            cyc = _cycle(log)
            if any(e.startswith("ready incoming") for e in cyc) or any(e.startswith(("drained", "release")) for e in cyc[1:]):
                break
            time.sleep(0.02)
        ready = next((e for e in cyc if e.startswith("ready incoming")), None)
        row["ready_age_ms"] = _age(ready) if ready else None
        row["ended_before_typing"] = next((e for e in cyc if e.startswith(("drained", "release"))), None)
        row["at_ready"] = _snap(reply)
        if ready is None:
            row["result"] = "no readiness within %.0f s" % ready_timeout
            rows.append(row)
            continue
        replies = [j.key(ch, []) for ch in text]
        row["handled_by"] = sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})
        t1 = D.now()
        while D.now() - t1 < end_timeout:
            reply, log = _log(j)
            cyc = _cycle(log)
            held = [e for e in cyc if e.startswith("hold key")]
            ends = [e for e in cyc if e.startswith(("drained", "release"))]
            if not held or ends:
                break
            time.sleep(0.05)
        held = [e for e in cyc if e.startswith("hold key")]
        end = next((e for e in cyc if e.startswith(("drained", "release"))), None)
        row["held"] = len(held)
        row["end"] = end
        row["late"] = bool(held)
        if held and end and _age(end) is not None and _age(held[0]) is not None:
            row["delay_ms"] = _age(end) - _age(held[0])
        row["at_end"] = _snap(reply)
        row["log"] = cyc[-8:]
        rows.append(row)
        time.sleep(float(step.get("gap", 0.5)))
    late = [r for r in rows if r.get("late")]
    delays = sorted(r["delay_ms"] for r in late if "delay_ms" in r)
    summary = {"cycles": len(rows), "late": len(late), "no_ready": sum(1 for r in rows if "result" in r),
               "delay_ms": delays, "ended_by": sorted({(r.get("end") or "").split(" +")[0] for r in late})}
    out = j.out / "newtab-first-keys.json"
    import json
    out.write_text(json.dumps({"summary": summary, "rows": rows}, indent=1))
    # The out folder's extra files do not come back from the mini: the rows ride in the step result, compact.
    compact = [{k: r.get(k) for k in ("cycle", "ready_age_ms", "ended_before_typing", "held", "end", "delay_ms", "result", "handled_by")}
               | {"at_ready": r.get("at_ready"), "log": r.get("log") if (r.get("late") or "result" in r or not r.get("ended_before_typing")) else None}
               for r in rows]
    return {"summary": summary, "rows": compact}


STEPS = {"newtab_first_keys_probe": step_newtab_first_keys_probe}
