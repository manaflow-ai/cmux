"""One-off steps for the FRAME OWNER S4 hang sample (agent pixel-perfect, scratch branch, never merged).

  bg_sample_start {name, seconds}  starts /usr/bin/sample on the app's pid in the background and returns at once (no wait
                                   for its first sample: the next step may block the app's main thread, and the sample must
                                   be running when it does). The report goes to <journey out>/diag-<name>.txt.
                  {attach_wait}    returns only when the sampler prints that it samples (fails after attach_wait s);
                                   for steps that do not block the main thread (a window drag profile).
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
    attach_wait = float(step.get("attach_wait", 0.0))
    if not attach_wait:
        proc = subprocess.Popen(["/usr/bin/sample", str(j.app.pid), str(seconds), "1", "-mayDie", "-file", str(path)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)  # orchestration: let sample attach before the next step (no app signal exists for an external sampler)
        _bg(j)[name] = {"proc": proc, "path": path, "seconds": seconds, "t": D.now()}
        return {"path": str(path), "seconds": seconds, "pid": j.app.pid, "running": proc.poll() is None}
    # attach_wait: return only when the sampler says it samples ("Sampling process <pid> for ..."). With Chromium
    # loaded, /usr/bin/sample needs about 3 s to attach, and a 0.3 s start missed a whole 2.2 s drag pair
    # (s7-profile-on-24, 2026-11-04). No line within attach_wait fails the step: an empty profile must not pass.
    log = j.out / f"diag-{name}.log"
    with open(log, "wb") as sink:
        proc = subprocess.Popen(["/usr/bin/sample", str(j.app.pid), str(seconds), "1", "-mayDie", "-file", str(path)],
                                stdout=sink, stderr=subprocess.STDOUT)
    t0 = D.now()
    while True:
        text = log.read_bytes() if log.exists() else b""
        if b"Sampling process" in text:
            break
        if proc.poll() is not None or D.now() - t0 > attach_wait:
            if proc.poll() is None:
                proc.kill()
            raise D.StepError(f"bg_sample_start: the sampler did not start within {attach_wait} s: {text[-300:]!r}")
        time.sleep(0.05)  # orchestration: poll the external sampler's own output (no app signal exists for it)
    attached = round(D.now() - t0, 3)
    _bg(j)[name] = {"proc": proc, "path": path, "seconds": seconds, "t": D.now()}
    return {"path": str(path), "seconds": seconds, "pid": j.app.pid, "running": proc.poll() is None,
            "attached_after_s": attached, "sampler_says": text.decode("utf-8", "replace").strip()[-200:]}


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
