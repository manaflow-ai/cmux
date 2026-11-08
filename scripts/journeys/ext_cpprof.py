"""CLOSE PERF profile (lead 2026-11-08: prove or disprove the B undo/redo finding with a time profile). Local kit only.

  cp_xctrace_closes {case: B|C, runs: 10, gap: 1.2, window_ms: 120, top: 40}
      RUNS closes under ONE `xctrace record --template "Time Profiler" --all-processes` (ext_cmdn's recorder and
      reader). B: splitRight on the focused pane, then Cmd-W (debug.key) on the new pane. C: workspace.newAtBottom,
      then Cmd-W. Each close's main-thread samples go on its own clock by the first sample inside the close handler
      (TabLifecycle / HiddenTabClose / CloseUndoToasts / closeWorkspace), in 5 ms bins with the deepest frames of
      ours, plus the heaviest inclusive and self frames over the window.
"""
import re
import time

D = None
C = None


def install(driver):
    global D, C
    D = driver
    import ext_cmdn
    C = ext_cmdn


SETUP = {"B": "splitRight", "C": "workspace.newAtBottom"}


def step_cp_xctrace_closes(j, step):
    case = step.get("case", "B")
    C._HANDLER = re.compile(r"TabLifecycle|HiddenTabClose|CloseUndoToasts|showPaneClose|closeWorkspace|closeTab")
    runs, gap = int(step.get("runs", 10)), float(step.get("gap", 1.2))

    class _J:  # ext_cmdn.xctrace_presses drives Cmd-N; here the same recorder around our own presses
        pass
    import shutil, signal, subprocess, threading
    xcrun = shutil.which("xcrun") or "/usr/bin/xcrun"
    trace = j.out / "closes.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([xcrun, "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                            "--time-limit", f"{int(step.get('cap_seconds', 90))}s", "--output", str(trace), "--no-prompt"],
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
    replies = []
    for _ in range(runs):
        j.app.rpc("action.run", {"action": SETUP[case], "focus": True})
        time.sleep(0.7)
        j.key("w", ["cmd"])
        replies.append({})
        time.sleep(gap)
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 150)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    result = {"bench": "xctrace-close", "case": case, "log": log[-8:]}
    xml = j.out / "close-profile.xml"
    done = subprocess.run([xcrun, "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                          capture_output=True, text=True, timeout=float(step.get("export_timeout", 150)))
    if done.returncode != 0:
        result["error"] = f"export exit {done.returncode}: {(done.stderr or done.stdout)[-300:]}"
    else:
        result.update(C.xctrace_press_profiles(xml, j.app.pid, replies, float(step.get("window_ms", 120)), int(step.get("top", 40))))
    xml.unlink(missing_ok=True)
    shutil.rmtree(trace, ignore_errors=True)
    for row in result.get("rows") or []:  # the raw samples stay on the mini; phases and bins go to result.json
        row.pop("raw", None)
        row.pop("strings", None)
        row.pop("table", None)
    (j.out / f"diag-closeprofile{case.lower()}.json").write_text(__import__("json").dumps(result))
    return result


STEPS = {"cp_xctrace_closes": step_cp_xctrace_closes}
CONDITIONS = {}
