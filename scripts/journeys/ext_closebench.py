"""CLOSE PERF bench steps (task close-perf, cmux-ad m56 2026-11-07: "the way we close panes and resulting movement is not
back"): a person's Cmd-W, timed by the app itself, for the DOGFOOD BENCH round (journeys/perf/cp-close-bench.json).
Not a CI job, step or gate.

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  close_bench {case: A|B|C, runs, label, settle?: 0.6, rest?: 1.0}
      RUNS closes of one case, each from a fresh set-up made by the app's own actions on the focused pane:
        A  newSurface (a 2nd terminal tab in the pane), then Cmd-W: a tab closes, the pane keeps its tab
        B  splitRight (a new pane at the right), then Cmd-W: the pane's last tab closes, its neighbour grows
        C  workspace.newAtBottom (a workspace of one pane), then Cmd-W: the last tab of the last pane closes the workspace
      Per close: debug.frames start, the key through debug.key, REST s, debug.frames stop, and the close's run in
      debug.action_budget: key_to_commit_ms = its input age + its commit_ms (the key's turn to its committed frame; the
      frame shows at the next refresh), missed = display refreshes missed in the REST window (the motion), main_max_ms =
      the busiest main-thread frame in it.
"""
import time

D = None
SETUP = {"A": "newSurface", "B": "splitRight", "C": "workspace.newAtBottom"}


def install(driver):
    global D
    D = driver


def _rpc(j, method, params):
    try:
        return j.app.rpc(method, params)
    except D.StepError as error:
        return {"error": str(error)[:200]}


def _last_seq(j):
    reply = _rpc(j, "debug.action_budget", {"limit": 1})
    recent = (reply or {}).get("recent") if isinstance(reply, dict) else None
    return recent[-1].get("sequence") if recent else None


def close_run(j, case, settle, rest):
    setup = _rpc(j, "action.run", {"action": SETUP[case], "focus": True})
    time.sleep(settle)
    seq0 = _last_seq(j)
    _rpc(j, "debug.frames", {"action": "start"})
    j.key("w", ["cmd"])
    time.sleep(rest)
    frames = _rpc(j, "debug.frames", {"action": "stop", "raw": True})
    reply = _rpc(j, "debug.action_budget", {"limit": 24})
    runs = [r for r in ((reply or {}).get("recent") or []) if seq0 is None or (r.get("sequence") or 0) > seq0]
    close = next((r for r in runs if "close" in str(r.get("id", "")).lower()), None)
    row = {"case": case, "setup_error": setup.get("error") if isinstance(setup, dict) else None}
    if close:
        row.update(action=close.get("id"), entrypoint=close.get("entrypoint"), commit_ms=round(close.get("commit_ms") or 0, 2),
                   input_age_ms=round(close.get("input_age_ms") or 0, 2),
                   key_to_commit_ms=round((close.get("input_age_ms") or 0) + (close.get("commit_ms") or 0), 2))
    if isinstance(frames, dict) and "error" not in frames:
        main = frames.get("main_ms") or []
        row.update(missed=frames.get("missed"), frames=frames.get("frames"), refresh_ms=round(frames.get("refresh_ms") or 0, 2),
                   main_max_ms=round(max(main), 2) if main else None,
                   main_over_8_3=sum(1 for m in main if m > 1000.0 / 120.0))
    return row


def step_close_bench(j, step):
    case, runs = step["case"], int(step.get("runs", 10))
    if case not in SETUP:
        raise D.StepError(f"close_bench: case {case!r} is not one of {sorted(SETUP)}")
    settle, rest = float(step.get("settle", 0.6)), float(step.get("rest", 1.0))
    rows = [close_run(j, case, settle, rest) for _ in range(runs)]
    if not any(r.get("key_to_commit_ms") is not None for r in rows):
        raise D.StepError(f"close_bench {case}: no close run in debug.action_budget for any of {runs} presses: {rows[:2]}")
    return {"bench": "close", "case": case, "label": step.get("label", ""), "rows": rows}


STEPS = {"close_bench": step_close_bench}
CONDITIONS = {}
