"""CLOSE VARIANTS 4 step 2 (the long frame after the key frame): os_signpost + Time Profiler around REAL closes. Local kit only.

  cp_sp_start {tag, cap_seconds?: 240}
      Starts ONE `xcrun xctrace record --template "Time Profiler" --instrument os_signpost --attach <app pid>` and keeps
      it on the journey. The steps after it (set-up, focus, cp_close with the real HID Cmd-W) run under it.
  cp_sp_stop {}
      Stops the recording and exports two tables: the time profile (every thread of the app, its stacks) and the
      os_signpost intervals and events. Each goes gzipped into the video folder (run.py fetches it whole):
      video/cvsp-<tag>.time-profile.xml.gz and video/cvsp-<tag>.os-signpost.xml.gz, with the app's input journal
      since the start (video/cvsp-<tag>.journal.json). The cut per close (frame after the key frame) is done off the
      Mac by close-perf-tools/cv4/spframe.py.
"""
import gzip
import json
import shutil
import signal
import subprocess
import threading
import time

D = None
R = None


def install(driver):
    global D, R
    D = driver
    import ext_realkey
    R = ext_realkey


def _xcrun():
    return shutil.which("xcrun") or "/usr/bin/xcrun"


def step_cp_sp_start(j, step):
    if getattr(j, "cvsp", None):
        raise D.StepError("cp_sp_start: a recording already runs")
    tag = step.get("tag", "p")
    trace = j.out / f"sp-{tag}.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([_xcrun(), "xctrace", "record", "--template", "Time Profiler", "--instrument", "os_signpost",
                            "--attach", str(j.app.pid), "--time-limit", f"{int(step.get('cap_seconds', 240))}s",
                            "--output", str(trace), "--no-prompt"],
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
    j.cvsp = {"rec": rec, "trace": trace, "log": log, "tag": tag, "journal_seq": R._journal_last_seq(j)}
    return {"trace": trace.name, "log": log[-3:]}


def _export(trace, schema, out, timeout):
    xml = out.with_suffix("")  # .xml
    done = subprocess.run([_xcrun(), "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                           f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                          capture_output=True, text=True, timeout=timeout)
    if done.returncode != 0:
        return f"export {schema} exit {done.returncode}: {(done.stderr or done.stdout)[-300:]}"
    with open(xml, "rb") as src, gzip.open(out, "wb", compresslevel=6) as dst:
        shutil.copyfileobj(src, dst)
    size = xml.stat().st_size
    xml.unlink(missing_ok=True)
    return size


def step_cp_sp_stop(j, step):
    prof = getattr(j, "cvsp", None)
    if not prof:
        raise D.StepError("cp_sp_stop: no recording runs")
    j.cvsp = None
    journal = [e for e in R._journal_entries(j, 600) if int(e.get("seq") or 0) > int(prof["journal_seq"])]
    rec, trace, log, tag = prof["rec"], prof["trace"], prof["log"], prof["tag"]
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 200)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    import ext_video  # the video folder is fetched whole (run.py fetches only diag-<letters>.json from out/)
    vdir = ext_video._vdir(j)
    result = {"bench": "xctrace-sp-close", "tag": tag, "pid": j.app.pid, "log": log[-8:]}
    timeout = float(step.get("export_timeout", 200))
    for schema in ("time-profile", "os-signpost"):
        got = _export(trace, schema, vdir / f"cvsp-{tag}.{schema}.xml.gz", timeout)
        result[schema] = got
    (vdir / f"cvsp-{tag}.journal.json").write_text(json.dumps(dict(result, journal=journal), default=str))
    shutil.rmtree(trace, ignore_errors=True)
    return {"tag": tag, "time_profile": result["time-profile"], "os_signpost": result["os-signpost"],
            "journal_entries": len(journal)}


STEPS = {"cp_sp_start": step_cp_sp_start, "cp_sp_stop": step_cp_sp_stop}
CONDITIONS = {}
