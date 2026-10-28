"""The `--modes profiles` row of chromium-host-bench.py (p01-process-080): one Chromium Host serves the Chromium tabs
of two browser profiles, as Chrome runs one GPU process for every profile (content/browser/gpu/gpu_process_host.cc).

In a Debug build with `browserHost.helper` and `browserHost.tabs` on (the bench's TUNABLES with --modes profiles), the
app builds `ChromiumHostSupervisor` at launch and every Chromium tab runs in its one host (`debug.cef` backend `host`).
The row makes two profiles with the app's own CLI, opens the probe page in a Chromium tab of each (`browser profile
open --engine chromium`), and checks:

  backend   `debug.cef` backend is `host`
  loaded    both tabs load the page (`browser.page.eval` in each tab)
  one_host  the supervisor's host (`debug.cef` host_supervisor) is the same pid after both tabs, it started one host
            only, and that pid is a running Chromium Host. Other Chromium Hosts of the app (debug.chromium_host's
            session host, from the helper rows) are not the supervisor's: they are listed as `other_hosts`, never
            counted.
  isolated  a localStorage value the first profile's tab writes is not in the second's (two profiles, not one)

Pass: all four. A build whose backend is not the host says not_run and the mode fails: it could not run.
"""

ORIGIN_KEY = "cmux-profiles-row"


def run(rpc, wait, page_eval, url, cli, host_pids, run_id):
    """The row; returns (row, ok). `cli(*args)` runs the app's bundled CLI with --json and returns (code, reply);
    `host_pids()` lists the pids of the app's Chromium Host processes; `run_id` names this run's profiles."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release or bench build, "
                           "or browserHost.helper or browserHost.tabs off)", "pass": False}, False
    row = {"backend": backend, "tabs": []}
    for name in (f"Host A {run_id}", f"Host B {run_id}"):
        code, created = cli("browser", "profile", "create", "--name", name)
        profile = find(created, "id")
        if code != 0 or not profile:
            row["error"] = f"profile {name!r} was not created: {str(created)[:200]}"
            row["pass"] = False
            return row, False
        code, opened = cli("browser", "profile", "open", url, "--profile", name, "--engine", "chromium")
        tab = find(opened, "tab_id")
        loaded = bool(tab) and code == 0 and bool(wait(lambda: page_eval("document.readyState === 'complete'", tab), 60, 0.5))
        row["tabs"].append({"profile": profile, "tab": tab, "loaded": loaded, "supervisor": supervisor(rpc),
                            "host_pids": host_pids()})
    row["loaded"] = all(entry["loaded"] for entry in row["tabs"])
    row["one_host"] = one_host(row["tabs"])
    last = row["tabs"][-1]
    row["other_hosts"] = [pid for pid in last["host_pids"] if pid != last["supervisor"].get("pid")]
    if row["loaded"]:
        a, b = (entry["tab"] for entry in row["tabs"])
        page_eval(f"localStorage.setItem({ORIGIN_KEY!r}, 'a'), true", a)
        row["isolated"] = page_eval(f"localStorage.getItem({ORIGIN_KEY!r}) === null", b) is True
    else:
        row["isolated"] = False
    row["pass"] = row["loaded"] and row["one_host"] and row["isolated"]
    return row, True


def supervisor(rpc):
    """`debug.cef` host_supervisor: the supervisor's host pid and the hosts it started ({} when it reports none)."""
    return (rpc("debug.cef") or {}).get("host_supervisor") or {}


def one_host(tabs):
    """Whether one supervisor host served every tab: the same pid after each, one host started, and it runs."""
    first, last = tabs[0]["supervisor"], tabs[-1]["supervisor"]
    pid = last.get("pid")
    return (pid is not None and first.get("pid") == pid and last.get("hosts_started") == 1
            and pid in tabs[-1]["host_pids"])


def find(value, key):
    """The first `key` in a CLI reply, searched depth first through its objects and lists."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            found = find(item, key)
            if found is not None:
                return found
    return None
