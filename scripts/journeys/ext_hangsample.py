"""One-off steps for the FRAME OWNER S4 hang sample (agent pixel-perfect, scratch branch, never merged).

  bg_sample_start {name, seconds}  starts /usr/bin/sample on the app's pid in the background and returns at once (no wait
                                   for its first sample: the next step may block the app's main thread, and the sample must
                                   be running when it does). The report goes to <journey out>/diag-<name>.txt.
  bg_sample_wait  {name}           waits for that sample to end (its seconds + 30 s at most); never fails the journey.
Standard library only (the driver runs on the mini's /usr/bin/python3)."""
import os
import subprocess
import time

D = None


def install(driver):
    global D
    D = driver


def _bg(j):
    if not hasattr(j, "hang_samples"):
        j.hang_samples = {}
    return j.hang_samples


def step_bg_sample_start(j, step):
    name = step["name"]
    if not name.isalpha() or not name.islower():
        raise D.StepError(f"bg_sample_start: name {name!r} must be lowercase letters (diag-<name>.txt)")
    path = j.out / f"diag-{name}.txt"
    seconds = float(step.get("seconds", 20.0))
    proc = subprocess.Popen(["/usr/bin/sample", str(j.app.pid), str(seconds), "1", "-mayDie", "-file", str(path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)  # orchestration: let sample attach before the next step (no app signal exists for an external sampler)
    _bg(j)[name] = {"proc": proc, "path": path, "seconds": seconds, "t": D.now()}
    return {"path": str(path), "seconds": seconds, "pid": j.app.pid, "running": proc.poll() is None}


def step_bg_sample_wait(j, step):
    rec = _bg(j).pop(step["name"], None)
    if not rec:
        return {"missing": step["name"]}
    try:
        rec["proc"].wait(timeout=rec["seconds"] + 30)
    except subprocess.TimeoutExpired:
        rec["proc"].kill()
    size = os.path.getsize(rec["path"]) if os.path.exists(rec["path"]) else 0
    return {"path": str(rec["path"]), "bytes": size, "exit": rec["proc"].returncode, "after_s": round(D.now() - rec["t"], 3)}


STEPS = {"bg_sample_start": step_bg_sample_start, "bg_sample_wait": step_bg_sample_wait}
CONDITIONS = {}
