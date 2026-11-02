"""RESIZE VIDEOS suite steps (handoff resize-videos/FINDINGS.md, agent resize-suite).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only).

Steps (`do`):
  try_action    {action, args?}  action.run of a set-up action that may already hold (a width preset on a column that
                has that width): an "unavailable" answer is recorded, not a failure. Any other error fails the step.
  sample_start  {name, seconds?: 1.0, interval_ms?: 1}  starts /usr/bin/sample on the app's pid in the background and
                returns once it samples (its "Sampling process" line), so the next step's action is inside the sample.
                The report goes to <journey out>/diag-<name>.txt (run.py fetches diag-*.txt).
  sample_stop   {name}  waits for that sample to end (its seconds + 30 s at most) and records its size.
"""
import os
import subprocess
import time

D = None


def install(driver):
    global D
    D = driver


def step_try_action(j, step):
    params = {"action": step["action"], "args": j.sub(step.get("args") or {}), "focus": True}
    try:
        return {"reply": j.app.rpc("action.run", params), "ran": True}
    except D.StepError as error:
        if "unavailable" in str(error):
            return {"ran": False, "unavailable": str(error)[:300]}
        raise


def _samples(j):
    if not hasattr(j, "rv_samples"):
        j.rv_samples = {}
    return j.rv_samples


def step_sample_start(j, step):
    name = step["name"]
    if not name.isalpha() or not name.islower():
        raise D.StepError(f"sample_start: name {name!r} must be lowercase letters (diag-<name>.txt)")
    path = j.out / f"diag-{name}.txt"
    seconds = float(step.get("seconds", 1.0))
    interval = int(step.get("interval_ms", 1))
    proc = subprocess.Popen(["/usr/bin/sample", str(j.app.pid), str(seconds), str(interval), "-mayDie", "-file", str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    end = D.now() + 10
    seen = []
    while D.now() < end:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                break
            continue
        seen.append(line.strip())
        if line.startswith("Sampling process"):
            t = D.now()
            _samples(j)[name] = {"proc": proc, "path": path, "seconds": seconds, "t_sampling": t}
            if step.get("mark"):
                j.marks[step["mark"]] = t
            return {"path": str(path), "seconds": seconds, "interval_ms": interval, "t_sampling": round(t, 6),
                    "said": seen[-3:]}
    proc.kill()
    raise D.StepError(f"sample did not start on pid {j.app.pid}: {seen[-5:]}")


def step_sample_stop(j, step):
    rec = _samples(j).pop(step["name"], None)
    if not rec:
        raise D.StepError(f"sample_stop: no sample {step['name']!r} runs")
    try:
        rest = rec["proc"].communicate(timeout=rec["seconds"] + 30)[0] or ""
    except subprocess.TimeoutExpired:
        rec["proc"].kill()
        raise D.StepError("sample_stop: sample did not end")
    size = os.path.getsize(rec["path"]) if os.path.exists(rec["path"]) else 0
    if not size:
        raise D.StepError(f"sample wrote no report: {rest.strip()[-300:]}")
    return {"path": str(rec["path"]), "bytes": size, "exit": rec["proc"].returncode, "ended_after_s": round(D.now() - rec["t_sampling"], 3)}


STEPS = {"try_action": step_try_action, "sample_start": step_sample_start, "sample_stop": step_sample_stop}
CONDITIONS = {}
