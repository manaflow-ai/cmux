"""Restart to Update (VIDEO EXTRA item 4, lead 2026-11-02 00:29Z).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Steps (`do`):
  update_relaunch {mark?, stage?: true}
                  the app's own Restart to Update path, then the reopen a person sees: with STAGE, `debug.updater
                  {action: "simulate"}` first (a pending update with published notes, as Debug Settings' "Simulate
                  pending update"); then `debug.updater {action: "relaunch"}` (DEV and bench builds: the updater's
                  relaunch hook as Sparkle runs it before it installs, which quits and keeps every session, then
                  NSApp.terminate). When the old process has ended, the driver's own relaunch reopens the same bundle
                  through LaunchServices with the lease's launch variables and finds every named terminal again
                  (its Cmd-Q to the ended process does nothing; its record says so). Limit: no new binary is installed
                  (no signed update feed in a lease): this proves the relaunch path and what comes back, not the
                  install.
"""
import json
import time

D = None


def install(driver):
    global D
    D = driver


def step_update_relaunch(j, step):
    app, old = j.app, j.app.pid
    record = {"old_pid": old}
    if step.get("stage", True):
        try:
            record["simulate"] = app.rpc("debug.updater", {"action": "simulate"}, timeout=10)
        except D.StepError as error:
            raise D.NotRun(f"update_relaunch: this build has no debug.updater simulate: {str(error)[:200]}")
    t = D.now()
    try:
        record["relaunch"] = app.rpc("debug.updater", {"action": "relaunch"}, timeout=10)
    except (D.StepError, OSError, ValueError) as error:
        # The app may end before it answers: that is the path working.
        record["relaunch"] = f"no answer: {str(error)[-160:]}"
    end = D.now() + 30
    while D.now() < end and app.alive(old):
        time.sleep(0.1)
    if app.alive(old):
        raise D.StepError(f"update_relaunch: pid {old} still runs 30 s after debug.updater relaunch: {json.dumps(record)[:300]}")
    record["ended_after_s"] = round(D.now() - t, 3)
    reopened = j.step_relaunch({"how": "quit", "mark": step.get("mark")})
    return dict(record, reopen=reopened, path="debug.updater relaunch (updaterWillRelaunchApplication + terminate)")


STEPS = {"update_relaunch": step_update_relaunch}
CONDITIONS = {}
