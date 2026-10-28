"""The `--helper-kill` rows of chromium-host-bench.py (p01-process-225): the Chromium helpers of a Chromium Host page
(`debug.cef` backend `host`: the bench's tunables turn `browserHost.helper` on) are the host's children, not cmux's.
The host watches them (kqueue NOTE_EXIT, HOST/src/host_helper_exits.h) and sends each end as HELPER_EXIT; cmux records
an abnormal one in `debug.crashes` as it records a helper of its own in process. The tab's process list reads the
host's children.

  tab_processes  a Chromium tab's renderer pids (`debug.webui` browser_tabs renderer_pids, matched to helpers by
                 their --renderer-client-id) are children of the host, and the census lists the host's helpers
  utility        SIGKILL to the network service (--type=utility --utility-sub-type=network.mojom.NetworkService;
                 another utility when none runs): one `debug.crashes` record with its pid, type `utility`, reason
                 `killed` and code 9 (SIGKILL), from the `process` source
  gpu            the same for the GPU process (--type=gpu-process)
  renderer       the same for the tab's renderer (--type=renderer, not an extension's): one `process` record for its
                 pid (the tab's sad tab adds an `engine` record of its own, with no pid)

Every pid signalled is a child of the host the bench found (`ps` ppid), never another process. A kill row waits
DEADLINE_S for its record, then SETTLE_S more and counts again: a second record for the pid fails it. Without the host
backend every row says so and the mode fails: it could not run.
"""
import signal
import time

ROWS = ("tab_processes", "utility", "gpu", "renderer")
KILL_ROWS = ROWS[1:]
NETWORK_SERVICE = "network.mojom.NetworkService"
DEADLINE_S = 20.0
SETTLE_S = 1.0
POLL_S = 0.1


def helper_identity(command):
    """(type, sub_type, extension) of a Chromium helper's command line, or None without a --type."""
    fields = {"type": None, "sub_type": "", "extension": False}
    for argument in command.split():
        if argument.startswith("--type="):
            fields["type"] = argument[len("--type="):]
        elif argument.startswith("--utility-sub-type="):
            fields["sub_type"] = argument[len("--utility-sub-type="):]
        elif argument == "--extension-process":
            fields["extension"] = True
    return (fields["type"], fields["sub_type"], fields["extension"]) if fields["type"] else None


def host_children(ps_rows, host_pid):
    """{pid: (type, sub_type, extension)} of the host's helper children, from `ps_rows` ([(pid, ppid, command)])."""
    return {pid: identity for pid, ppid, command in ps_rows
            if ppid == host_pid and (identity := helper_identity(command)) is not None}


def pick(children, row, tab_renderers):
    """The pid row `row` kills: the network service (else another utility), the GPU process, or the tab's renderer
    (else another page renderer); None when the host has none."""
    def first(match):
        return next((pid for pid, identity in sorted(children.items()) if match(*identity)), None)
    if row == "utility":
        return first(lambda t, sub, _: t == "utility" and sub == NETWORK_SERVICE) or first(lambda t, _s, _e: t == "utility")
    if row == "gpu":
        return first(lambda t, _s, _e: t == "gpu-process")
    renderers = [pid for pid in tab_renderers if children.get(pid, (None,))[0] == "renderer"]
    return renderers[0] if renderers else first(lambda t, _s, ext: t == "renderer" and not ext)


def process_records(crashes, pid):
    """`debug.crashes` chromium records of the child monitor (or the host's HELPER_EXIT) for `pid`."""
    return [r for r in (crashes or {}).get("chromium") or [] if r.get("source") == "process" and r.get("pid") == pid]


def run(rpc, wait, ps_rows, host_pid, kill, url, sleep=time.sleep):
    """Every row; returns (rows, ok). `ps_rows()` lists [(pid, ppid, command)], `host_pid()` the host's pid or None,
    `kill(pid, sig)` signals one process."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        reason = f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or browserHost.helper off)"
        return {name: {"ok": False, "not_run": reason} for name in ROWS}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    host = wait(host_pid, 60, 0.5)
    if not host:
        return {"error": f"no Chromium Host runs: {str(opened)[:200]}"}, False
    rows = {}

    def tab_renderers():
        """The first Chromium tab's renderer pids once the census maps one, else None."""
        for tab in ((rpc("debug.webui") or {}).get("browser_tabs") or []):
            pids = [pid for pid in tab.get("renderer_pids") or [] if isinstance(pid, int)]
            if pids:
                return pids
        return None

    renderers = wait(tab_renderers, 60, 0.5) or []
    children = host_children(ps_rows(), host)
    listed = {p.get("pid") for p in (rpc("debug.webui") or {}).get("processes") or []}
    rows["tab_processes"] = {
        "ok": bool(renderers) and all(pid in children and pid in listed for pid in renderers),
        "host_pid": host, "renderer_pids": renderers, "host_children": sorted(children),
        "census_helpers": sorted(p for p in listed if isinstance(p, int)),
    }

    for row in KILL_ROWS:
        children = host_children(ps_rows(), host)
        pid = pick(children, row, renderers)
        if pid is None:
            rows[row] = {"ok": False, "not_run": f"the host has no {row} helper", "host_children": children}
            continue
        process_type = children[pid][0]
        kill(pid, signal.SIGKILL)
        sent = time.time()
        recorded = wait(lambda: process_records(rpc("debug.crashes"), pid) or None, DEADLINE_S, POLL_S)
        record_ms = round((time.time() - sent) * 1000, 1) if recorded else None
        sleep(SETTLE_S)  # test harness: a second record for the same end would come in this time
        records = process_records(rpc("debug.crashes"), pid)
        one = records[0] if len(records) == 1 else {}
        rows[row] = {
            "ok": len(records) == 1 and one.get("process_type") == process_type and one.get("reason") == "killed"
            and one.get("code") == int(signal.SIGKILL),
            "pid": pid, "process_type": process_type, "records": records, "record_ms": record_ms,
        }
    return rows, all(row.get("ok") for row in rows.values())
