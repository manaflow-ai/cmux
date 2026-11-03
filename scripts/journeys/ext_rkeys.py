"""RESIZE KEYS steps (agent resize-keys; P0 cmux-ad 2026-11-02: "still dont have pixel perfect ctrl shift hjkl for
resizing"). Keyboard pane resize is key.resizePaneLeft/Right/Up/Down: Ctrl-Shift-H/L/K/J and Ctrl-Cmd-arrows.
The cases are video-cases/gen_keys.py; the judge is video-cases/judge_keys.py (per press, from the trace).

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  rk_press   {key, modifiers? | keys: [{key, modifiers}, ...], count?, gap_ms?, mark?}
             COUNT (default 1) REAL HID presses of one shortcut (or of KEYS in turn: H, L, H, L ...) (CuaDriver desktop-scope events in ext_realkey's one
             session, as hid_key sends them), each started GAP_MS (default 0) after the one before (a late press is
             sent at once and its delay is logged). Each press goes into the recording's events.json (`hid`, kind
             "key", with t_sent / t_returned) and marks MARK.<i>. The app's input journal has what the app got.
  rk_hold    {key, modifiers?, seconds?, delay?, interval?, mark?}
             A held key through the app's key path (debug.key with the auto-repeat flag, ext_spam hold_key: one
             press, a repeat every INTERVAL s from DELAY s until SECONDS, then the key up). NOT a HID key: a real
             HID auto-repeat needs hid_inject's PostEvent grant (KIT.md 2c), not done on the minis. Logged in
             events.json as kind "hold" with the schedule and the replies' counts.
  rk_focus   {pane, timeout?}
             Focuses a named pane through the app (`cmux pane <id> focus`, the CLI's focus: the strip reveals it), waits
             until debug.surfaces reports it focused, and makes it the journey's pane (as use_pane). A click cannot
             reach a pane the strip scrolled out of view, or one whose program takes the mouse.
  rk_panes   {panes: [NAME...], as}
             For each named pane: focused or not, its daemon screen's tuikit `sigwinch` header ("SIGWINCH CxR
             winch=N reflow=M") when it runs that program, and the app's grid. Kept in the recording's meta notes
             under AS (judge_keys.py counts the SIGWINCH and reflows each press made).
"""
import json
import re
import time

D = None
R = None  # ext_realkey: the CuaDriver session (press)
V = None  # ext_video: the recording's hid log and notes
W = None  # ext_window: named panes
S = None  # ext_spam: hold_key

WINCH = re.compile(r"SIGWINCH (\d+)x(\d+) winch=(\d+) reflow=(\d+)")


def install(driver):
    global D, R, V, W, S
    D = driver
    import ext_realkey
    import ext_spam
    import ext_video
    import ext_window
    R, V, W, S = ext_realkey, ext_video, ext_window, ext_spam


def step_rk_press(j, step):
    count, gap = int(step.get("count", 1)), float(step.get("gap_ms", 0)) / 1000.0
    keys = step.get("keys") or [{"key": step["key"], "modifiers": step.get("modifiers", [])}]
    mark = step.get("mark")
    start = D.now()
    sent_log = []
    for i in range(count):
        due = start + i * gap
        wait = due - D.now()
        if wait > 0:
            time.sleep(wait)
        if mark:
            j.marks[f"{mark}.{i}"] = D.now()
        key = keys[i % len(keys)]
        mods = list(key.get("modifiers", []))
        sent = D.now()
        answer = R.press(j, key["key"], mods)
        returned = D.now()
        V._hid_log(j, "key", {"key": key["key"], "modifiers": mods, "press": i, "of": count, "due": round(due, 6)},
                   sent, returned, answer)
        sent_log.append({"i": i, "late_ms": round((sent - due) * 1000, 1), "took_ms": round((returned - sent) * 1000, 1)})
    if mark:
        j.marks[mark] = start
    late = max((s["late_ms"] for s in sent_log), default=0)
    return {"keys": keys, "count": count, "gap_ms": gap * 1000, "late_ms_max": late,
            "presses": sent_log}


def step_rk_hold(j, step):
    name = step.get("mark") or "hold"
    sent = D.now()
    reply = S.step_hold_key(j, dict(step, **{"as": name, "mark": name}))
    returned = D.now()
    args = {k: step.get(k) for k in ("key", "modifiers", "seconds", "delay", "interval")}
    rec = getattr(j, "video", None)
    if rec is not None:
        rec["hid"].append({"kind": "hold", "path": "debug.key repeat (not HID)", "args": args, "t_sent": round(sent, 6),
                           "t_returned": round(returned, 6), "answer": {k: reply.get(k) for k in ("sent", "ran", "refused", "repeats_dropped")},
                           "host_offset_s": round(V._host_offset_s(), 6)})  # driver clock -> host (video_judge)
    return reply


def step_rk_focus(j, step):
    rec = W.named(j, step["pane"])
    reply = j.app.cmux("pane", rec["pane"], "focus")
    end = D.now() + float(step.get("timeout", 5))
    while D.now() < end:
        row = W.pane_row(j, rec["pane"])
        if row and row.get("focused"):
            j.pane, j.term, j.host_pid, j.ext_window = rec["pane"], rec["term"], rec["host_pid"], rec["window"]
            j.key_window = rec["window"]
            j.app.snapshot_window = rec["window"]
            return {"focused": rec["pane"], "reply": reply}
        time.sleep(0.05)  # orchestration poll of the app's own report
    raise D.StepError(f"rk_focus: pane {step['pane']} is not focused after `pane focus`: {json.dumps(reply)[:200]}")


def step_rk_panes(j, step):
    out = {}
    for name in step["panes"]:
        rec = W.named(j, name)
        row = W.pane_row(j, rec["pane"]) or {}
        entry = {"pane": rec["pane"], "focused": bool(row.get("focused")), "kind": row.get("kind"),
                 "grid": (row.get("surface") or {}).get("grid")}
        try:
            text = j.app.screen(rec["term"])["text"]
            found = WINCH.search(text)
            if found:
                entry["winch"] = {"cols": int(found.group(1)), "rows": int(found.group(2)),
                                  "winch": int(found.group(3)), "reflow": int(found.group(4))}
        except Exception as error:  # a page or chat pane has no terminal screen
            entry["screen_error"] = str(error)[:200]
        out[name] = entry
    rec = getattr(j, "video", None)
    if rec is not None:
        rec["notes"][step["as"]] = {"t": D.now(), "panes": out}
    else:
        notes = getattr(j, "rk_notes", {})
        notes[step["as"]] = {"t": D.now(), "panes": out}
        j.rk_notes = notes
    return out


STEPS = {"rk_focus": step_rk_focus, "rk_press": step_rk_press, "rk_hold": step_rk_hold, "rk_panes": step_rk_panes}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
