"""CLOSE VARIANTS 3 step 1 (P0 late start, R3/G4): a time profile around REAL closes in a layout. Local kit only.

  cp_xctrace_start {cap_seconds?: 240}
      Starts ONE `xcrun xctrace record --template "Time Profiler" --all-processes` (as ext_cpprof) and keeps it on the
      journey. The steps after it (set-up, focus, cp_close with the real HID Cmd-W) run under it.
  cp_xctrace_stop {window_ms?: 320, top?: 40, closes?: 40}
      Stops the recording, exports the time-profile table and cuts it per close with ext_cmdn.xctrace_press_profiles:
      each close's main-thread samples on its own clock (0 = the first sample in the close handler, TabLifecycle /
      prepareClose / showPaneClose), 5 ms bins with the deepest frames of ours, the heaviest inclusive and self
      frames. video/cvprof-<tag>.trace.json (a name run.py fetches) keeps the raw samples; it also keeps the app's input journal (the last 400
      entries: show / reveal / conceal / attach per close).
"""
import json
import re
import shutil
import signal
import subprocess
import threading
import time

D = None
C = None
R = None

HANDLER = re.compile(r"TabLifecycle|prepareClose|showPaneClose|HiddenTabClose|closeWorkspace")


def install(driver):
    global D, C, R
    D = driver
    import ext_cmdn
    import ext_realkey
    C, R = ext_cmdn, ext_realkey


def _xcrun():
    return shutil.which("xcrun") or "/usr/bin/xcrun"


def step_cp_xctrace_start(j, step):
    if getattr(j, "cvprof", None):
        raise D.StepError("cp_xctrace_start: a recording already runs")
    trace = j.out / f"closes-{step.get('tag', 'p')}.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([_xcrun(), "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                            "--time-limit", f"{int(step.get('cap_seconds', 240))}s", "--output", str(trace), "--no-prompt"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    started = threading.Event()

    def read():
        for line in rec.stdout:
            log.append(line.rstrip()[:200])
            if "Starting recording" in line or "Ctrl-C to stop" in line:
                started.set()
        started.set()
    threading.Thread(target=read, daemon=True).start()
    started.wait(float(step.get("start_timeout", 90)))
    if rec.poll() is not None:
        raise D.StepError(f"xctrace record ended: {log[-6:]}")
    time.sleep(1.0)
    j.cvprof = {"rec": rec, "trace": trace, "log": log, "tag": step.get("tag", "p"),
                "journal_seq": R._journal_last_seq(j)}
    return {"trace": trace.name, "log": log[-3:]}


def step_cp_xctrace_stop(j, step):
    prof = getattr(j, "cvprof", None)
    if not prof:
        raise D.StepError("cp_xctrace_stop: no recording runs")
    j.cvprof = None
    journal = [e for e in R._journal_entries(j, 400) if int(e.get("seq") or 0) > int(prof["journal_seq"])]
    rec, trace, log = prof["rec"], prof["trace"], prof["log"]
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 200)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    result = {"bench": "xctrace-close-layout", "tag": prof["tag"], "log": log[-8:]}
    xml = j.out / f"close-profile-{prof['tag']}.xml"
    done = subprocess.run([_xcrun(), "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                          capture_output=True, text=True, timeout=float(step.get("export_timeout", 200)))
    if done.returncode != 0:
        result["error"] = f"export exit {done.returncode}: {(done.stderr or done.stdout)[-300:]}"
    else:
        old = C._HANDLER
        C._HANDLER = HANDLER
        try:
            result.update(C.xctrace_press_profiles(xml, j.app.pid, [{}] * int(step.get("closes", 40)),
                                                   float(step.get("window_ms", 320)), int(step.get("top", 40))))
        finally:
            C._HANDLER = old
    xml.unlink(missing_ok=True)
    shutil.rmtree(trace, ignore_errors=True)
    import ext_video  # the video folder is fetched whole (run.py fetches only diag-<letters>.json from out/)
    (ext_video._vdir(j) / f"cvprof-{prof['tag']}.trace.json").write_text(json.dumps(dict(result, journal=journal), default=str))
    for row in result.get("rows") or []:
        row.pop("raw", None)
    return {"tag": prof["tag"], "presses_found": result.get("presses_found"), "main_samples": result.get("main_samples"),
            "error": result.get("error"), "journal_entries": len(journal)}


STEPS = {"cp_xctrace_start": step_cp_xctrace_start, "cp_xctrace_stop": step_cp_xctrace_stop}
CONDITIONS = {}
