"""Page-capture steps for the journeys (journeys/p1/capture-storm-renderer-exit.json): the P0 #1 repro.

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

P0 #1 (2026-10-28, handoff/cef-snapshot-crash-result.md): optimized builds crashed in Chromium (SIGSEGV at 0 in
RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived, render_widget_host_impl.cc:3941) when a renderer exited while
a page picture (DevTools Page.captureScreenshot) of its page was in flight: the failed copy retried through the
view the renderer exit had removed. 19 of 21 reports came when a lease ended a heavy session (SIGTERM, then the
quit closes every renderer). These steps put page pictures in flight and end the renderers under them.

Steps (`do`):
  capture_storm {seconds?, as?}     starts a thread that asks for `debug.window_snapshot` (a Chromium page's
                                    picture is its `Page.captureScreenshot`, DebugWindowSnapshot) again and again,
                                    each on its own connection, for SECONDS (default 4); the step returns at once.
                                    AS (default "storm") names it for capture_storm_end.
  capture_storm_end {as?}           waits for the storm AS to end; its reply counts the pictures asked and answered.
  kill_renderers {signal?}          sends SIGNAL (default KILL) to every Chromium renderer of the app under test
                                    (its own processes with --type=renderer, by pid; never by pattern) and replies
                                    with their pids: each renderer exits as a crashed or closed tab's does.
A lease end is `relaunch` with how "term" (driver.py): SIGTERM to the app's pid, its quit path runs, then it opens.
"""

import os
import signal
import socket
import json
import threading
import time

driver = None


def install(module):
    global driver
    driver = module


def _ask(sock_path, method, params, timeout):
    """One request on its own connection; True when an answer line came."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock_path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 16)
                if not chunk:
                    break
                buf += chunk
            return bool(buf)
    except OSError:
        return False


def capture_storm(journey, step):
    name = step.get("as", "storm")
    seconds = float(step.get("seconds", 4))
    counts = {"asked": 0, "answered": 0}
    end = time.time() + seconds
    sock_path = journey.app.sock
    path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-capture-storm.png")

    def run():
        workers = []

        def one():
            if _ask(sock_path, "debug.window_snapshot", {"path": path}, timeout=6):
                counts["answered"] += 1

        while time.time() < end:
            counts["asked"] += 1
            worker = threading.Thread(target=one, daemon=True)
            worker.start()
            workers.append(worker)
            time.sleep(0.05)
        for worker in workers:
            worker.join(timeout=7)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    storms = getattr(journey, "capture_storms", {})
    storms[name] = (thread, counts)
    journey.capture_storms = storms
    return {"storm": name, "seconds": seconds}


def capture_storm_end(journey, step):
    name = step.get("as", "storm")
    thread, counts = getattr(journey, "capture_storms", {}).get(name, (None, None))
    if thread is None:
        raise driver.StepError(f"capture_storm_end: no storm {name!r}")
    thread.join(timeout=30)
    return dict(counts)


def kill_renderers(journey, step):
    sig = getattr(signal, "SIG" + str(step.get("signal", "KILL")).upper())
    renderers = [row["pid"] for row in journey.app.bundle_processes(journey.app.pid) if "--type=renderer" in row["command"]]
    killed = []
    if step.get("mark"):
        journey.marks[step["mark"]] = time.time() if not hasattr(driver, "now") else driver.now()
    for pid in renderers:
        try:
            os.kill(pid, sig)
            killed.append(pid)
        except OSError:
            pass
    return {"renderers": renderers, "killed": killed}


STEPS = {
    "capture_storm": capture_storm,
    "capture_storm_end": capture_storm_end,
    "kill_renderers": kill_renderers,
}
