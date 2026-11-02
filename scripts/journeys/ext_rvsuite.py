"""RESIZE VIDEOS suite steps (handoff resize-videos/FINDINGS.md, agent resize-suite).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only).

Steps (`do`):
  try_action    {action, args?}  action.run of a set-up action that may already hold (a width preset on a column that
                has that width): an "unavailable" answer is recorded, not a failure. Any other error fails the step.
  sample_start  {name, seconds?: 1.0, interval_ms?: 1, wait_first_sample?}  starts /usr/bin/sample on the app's pid in
                the background and returns once it samples (its "Sampling process" line comes after the first sample),
                so the next step's action is inside the sample.
                The report goes to <journey out>/diag-<name>.txt (run.py fetches diag-*.txt).
  sample_stop   {name}  waits for that sample to end (its seconds + 30 s at most) and records its size.
  xtp_start     {name, seconds?: 2, wait_first_sample?}  starts `xcrun xctrace record --template "Time Profiler" --attach <app pid>` for
                `seconds` and returns once it records; the bundle goes to <journey out>/xtp-<name>.trace.
  xtp_stop      {name}  waits for the recording to end, then exports its time-profile table (time-stamped stacks,
                every thread) as XML to <journey out>/diag-<name>.txt (run.py fetches diag-*.txt).
  trace_only_start {name} / trace_only_stop {name}  debug.motion trace_start / trace_stop without the recorder
                (a build whose recorder is broken); the samples go to <journey out>/diag-<name>trace.json.
"""
import json
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


def _xtp(j):
    if not hasattr(j, "rv_xtp"):
        j.rv_xtp = {}
    return j.rv_xtp


def step_xtp_start(j, step):
    name = step["name"]
    if not name.isalpha() or not name.islower():
        raise D.StepError(f"xtp_start: name {name!r} must be lowercase letters")
    bundle = j.out / f"xtp-{name}.trace"
    seconds = float(step.get("seconds", 2.0))
    proc = subprocess.Popen(["/usr/bin/xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(j.app.pid),
                             "--time-limit", f"{int(seconds * 1000)}ms", "--output", str(bundle), "--no-prompt"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    end = D.now() + 60
    seen = []
    while D.now() < end:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                break
            continue
        seen.append(line.strip())
        if "Starting recording" in line or "Ctrl-C to stop" in line:
            # Its first sample comes about 280 ms after this line (run rv-suite-xtp-before, 2 of 2): the step returns
            # only after the first sample can have come, so the next step (the key) is inside the profile.
            if step.get("wait_first_sample"):
                time.sleep(float(step.get("first_sample_wait", 0.8)))
            t = D.now()
            _xtp(j)[name] = {"proc": proc, "bundle": bundle, "seconds": seconds, "t": t, "said": seen}
            if step.get("mark"):
                j.marks[step["mark"]] = t
            return {"bundle": str(bundle), "seconds": seconds, "t_recording": round(t, 6), "said": seen[-4:]}
    proc.kill()
    raise D.StepError(f"xctrace did not start on pid {j.app.pid}: {seen[-6:]}")


def step_xtp_stop(j, step):
    rec = _xtp(j).pop(step["name"], None)
    if not rec:
        raise D.StepError(f"xtp_stop: no recording {step['name']!r}")
    try:
        rest = rec["proc"].communicate(timeout=rec["seconds"] + 120)[0] or ""
    except subprocess.TimeoutExpired:
        rec["proc"].kill()
        raise D.StepError("xtp_stop: xctrace did not end")
    out = j.out / f"diag-{step['name']}.txt"
    with open(out, "w") as f:
        done = subprocess.run(["/usr/bin/xcrun", "xctrace", "export", "--input", str(rec["bundle"]), "--xpath",
                               '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                              stdout=f, stderr=subprocess.PIPE, text=True, timeout=300)
    size = os.path.getsize(out)
    if done.returncode != 0 or not size:
        raise D.StepError(f"xctrace export failed ({done.returncode}): {done.stderr.strip()[-300:]} record: {rest.strip()[-300:]}")
    return {"export": str(out), "bytes": size, "record_exit": rec["proc"].returncode, "record_said": rest.strip()[-200:]}


def step_trace_only_start(j, step):
    reply = j.app.rpc("debug.motion", {"action": "trace_start", "window": 0}) or {}
    if isinstance(reply, dict) and reply.get("error"):
        raise D.StepError(f"trace_start: {reply['error']}")
    return {"reply": reply}


def step_trace_only_stop(j, step):
    reply = j.app.rpc("debug.motion", {"action": "trace_stop"}) or {}
    path = j.out / f"diag-{step['name']}trace.json"
    path.write_text(json.dumps(reply))
    return {"path": str(path), "samples": len(reply.get("samples") or []), "refresh_ms": reply.get("refresh_ms")}


STEPS = {"try_action": step_try_action, "sample_start": step_sample_start, "sample_stop": step_sample_stop,
         "xtp_start": step_xtp_start, "xtp_stop": step_xtp_stop,
         "trace_only_start": step_trace_only_start, "trace_only_stop": step_trace_only_stop}
CONDITIONS = {}
