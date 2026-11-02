"""Host facts for one moment of a journey (RESIZE VIDEOS F1: the app's main thread ran on E/S cores, STATUS 7642).

`host_facts` reads, on the mini, read-only and with no privacy grant: the frontmost app and the bench app's type and
frontmost flag (lsappinfo), its process role (taskpolicy -G), its priority and nice (ps), Low Power Mode and the power
source (pmset -g, pmset -g ps), the thermal state (pmset -g therm), and the app's own view (debug.focus: isActive, key
window). Nothing changes on the host."""
import subprocess

STEPS = {}


def install(driver):
    global D
    D = driver


def _run(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        return (done.stdout + done.stderr).strip()[-1500:]
    except (OSError, subprocess.SubprocessError) as error:
        return f"error: {error}"


def step_host_facts(j, step):
    pid = str(j.app.pid)
    asn = _run(["/usr/bin/lsappinfo", "front"])
    facts = {
        "label": step.get("label", ""),
        "app_pid": pid,
        "front_asn": asn,
        "front": _run(["/usr/bin/lsappinfo", "info", "-only", "name,bundleID,pid", asn]) if asn else "",
        "app_info": _run(["/usr/bin/lsappinfo", "info", "-only", "applicationtype,frontmost,name", "-app", "pid=" + pid]),
        "taskpolicy": _run(["/usr/sbin/taskpolicy", "-G", "-p", pid]),
        "ps": _run(["/bin/ps", "-o", "pid,pri,nice,stat,command", "-p", pid]),
        "pmset": _run(["/usr/bin/pmset", "-g"]),
        "pmset_ps": _run(["/usr/bin/pmset", "-g", "ps"]),
        "pmset_therm": _run(["/usr/bin/pmset", "-g", "therm"]),
    }
    try:
        facts["app_focus"] = j.app.rpc("debug.focus", {})
    except Exception as error:  # noqa: BLE001 - a fact, not a step failure
        facts["app_focus"] = f"error: {error}"
    return facts


STEPS["host_facts"] = step_host_facts
