"""Full STRESS set-up for CLOSE PERF (lead 2026-11-08: "run the real STRESS for terminals once"). Local kit only.

  stress_full {settle?: 2.0}   builds perf-stress-session.py's STRESS (60 workspaces, the measured 4x3 workspace of 14
                               panes x 6 tabs, 10 Chromium workspaces, 10 busy terminals, the 1600x1000 window) through
                               the app's debug socket, with its shape check. The measured workspace is shown at the end.
"""
import importlib.util
import os
import time

D = None


def install(driver):
    global D
    D = driver


def _load():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_stress_session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def step_stress_full(j, step):
    module = _load()
    lines = []

    def rpc(method, params=None, timeout=60):
        try:
            return j.app.rpc(method, params or {}, timeout=timeout)
        except D.StepError as error:
            return {"error": str(error)[:300]}

    stress = module.Stress(rpc, log=lines.append)
    try:
        summary = stress.build()
    except module.StressShapeError as error:
        raise D.StepError(f"STRESS shape: {error}; log tail {lines[-6:]}")
    time.sleep(float(step.get("settle", 2.0)))
    return {"stress": {k: summary.get(k) for k in ("workspaces", "build_s", "panes", "busy", "dock_overlap_pt", "window_on_screen")},
            "log_tail": lines[-4:]}


STEPS = {"stress_full": step_stress_full}
CONDITIONS = {}
