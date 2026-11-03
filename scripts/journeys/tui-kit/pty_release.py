#!/usr/bin/env python3
"""Does a closed terminal tab release its PTY at once? (lead 2026-11-03 00:3xZ, after the L6 'PTY capacity exhausted'
refusals of STATUS 7860.)

    pty_release.py --app-socket SOCK --home HOME --out DIR [--tabs 50] [--threads 16] [--seed 7]

Makes one workspace with TABS terminal tabs (one after the other), then closes them all at once (a burst on THREADS
threads) and counts the open PTY masters (/dev/ptmx file descriptors) on the host: before the burst, as soon as the
last close answered, and 0.25, 0.5, 1, 2, 5 and 10 s after; then closes the workspace and counts once more 5 s later.
A count is `lsof -n -P -F pcf /dev/ptmx` (every process of this user that holds a PTY master, with its command), and
the daemon's own share is the processes in the cmux-tui owner's process tree (identify's pid and its descendants).

Writes OUT/pty-release.json: samples [{at, t_s (after the burst), total, daemon_tree, by_command}], the closes
(ms, ok, error per tab), kern.tty.ptmx_max and the verdict line. Prints `PTY-RELEASE {json}`. Read only on the app
except the workspace and tabs it makes and closes. Exit 0 when it measured, 2 when it could not reach the app.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import heavy_profile  # noqa: E402
import load_profiles  # noqa: E402


def daemon_pid(app):
    """The cmux-tui owner's pid from its own identify answer, or None."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        try:
            conn.connect(app.daemon_sock)
            conn.sendall((json.dumps({"id": 1, "cmd": "identify"}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        finally:
            conn.close()
        reply = json.loads(buf)
        body = (reply.get("data") or reply.get("result") or reply) if isinstance(reply, dict) else {}
        return int(body["pid"]) if isinstance(body, dict) and body.get("pid") else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def tree(root):
    """ROOT and every descendant pid (ps -ax ppid table)."""
    if not root:
        return set()
    out = subprocess.run(["ps", "-ax", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    kids = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            kids.setdefault(int(parts[1]), []).append(int(parts[0]))
    seen, todo = set(), [root]
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        todo.extend(kids.get(pid, []))
    return seen


def ptmx_holders():
    """{pid: (command, fd count)} of every process holding /dev/ptmx (lsof field output)."""
    done = subprocess.run(["lsof", "-n", "-P", "-F", "pcf", "/dev/ptmx"], capture_output=True, text=True, timeout=60)
    held, pid, cmd = {}, None, ""
    for line in done.stdout.splitlines():
        if line.startswith("p"):
            pid, cmd = int(line[1:]), ""
        elif line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("f") and pid is not None:
            c, n = held.get(pid, (cmd, 0))
            held[pid] = (cmd or c, n + 1)
    return held


def pids_fds(pids):
    """/dev/ptmx fds held by the processes PIDS (lsof -a -p a,b,c: only those, fast), or None for no pids. A pid
    that has exited counts 0 (lsof skips it)."""
    if not pids:
        return None
    done = subprocess.run(["lsof", "-a", "-n", "-P", "-p", ",".join(str(p) for p in sorted(pids)), "-F", "f",
                           "/dev/ptmx"], capture_output=True, text=True, timeout=30)
    # lsof exits 1 with no output when none of PIDS holds /dev/ptmx (a true 0); an error message on stderr is a
    # failed scan: no count (0 would read as all released).
    if done.stderr.strip():
        return None
    return sum(1 for line in done.stdout.splitlines() if line.startswith("f"))


def fast(at, t0, pids):
    """A quick sample of the daemon tree's /dev/ptmx count (the tree as it was before the burst), timed; the
    host-wide scan takes 0.5-2 s, too slow for the 0.1-1 s samples (review FIX at 48bd6dc87f9)."""
    start = time.monotonic()
    n = pids_fds(pids)
    return {"at": at, "t_s": None if t0 is None else round(start - t0, 3), "lsof_ms": round((time.monotonic() - start) * 1000, 1),
            "daemon_tree": n}


def sample(at, t0, root):
    start = time.monotonic()
    held = ptmx_holders()
    mine = tree(root)
    by_command = {}
    for pid, (cmd, n) in held.items():
        by_command[cmd] = by_command.get(cmd, 0) + n
    return {"at": at, "t_s": None if t0 is None else round(start - t0, 3), "lsof_ms": round((time.monotonic() - start) * 1000, 1),
            "total": sum(n for _, n in held.values()),
            "daemon_tree": sum(n for pid, (_, n) in held.items() if pid in mine),
            "by_command": dict(sorted(by_command.items(), key=lambda kv: -kv[1]))}


def close_workspace(app, wid):
    """True when the workspace closed (a confirm, as L1's teardown does, when the plain close is refused)."""
    try:
        app.cmux("workspace", wid, "close", timeout=30)
        return True
    except heavy_profile.Refused as error:
        try:
            reply = app.rpc("action.run", {"action": "closeWorkspace", "target": "workspace:%s" % wid,
                                           "args": {"confirm": True}}, timeout=30)
        except (OSError, ValueError, heavy_profile.Refused) as second:
            return ("%s; then closeWorkspace: %s" % (error, second))[:400]
        if isinstance(reply, dict) and reply.get("error"):  # App.rpc returns an app error, it does not raise
            return ("%s; then closeWorkspace: %s" % (error, reply["error"]))[:400]
        return True


def measure(app, a, result, root, wid, pane):
    tabs = []
    for _ in range(a.tabs):
        try:
            v = app.cmux("tab", "create", "terminal", "--workspace", wid, "--pane", pane, timeout=30)
            if isinstance(v, dict) and v.get("tab_id"):
                tabs.append(v["tab_id"])
        except heavy_profile.Refused as error:
            result.setdefault("create_errors", []).append(str(error)[:400])
    result["made"] = len(tabs)
    time.sleep(2.0)  # every new terminal's shell has started
    result["samples"].append(sample("before burst (%d tabs open)" % len(tabs), None, root))
    pids = tree(root)  # the daemon and its terminal hosts as they are now (a host that exits then counts 0)
    result["tree_pids"] = len(pids)

    lock, queue = threading.Lock(), list(tabs)

    def closer():
        while True:
            with lock:
                if not queue:
                    return
                tab = queue.pop()
            start = time.monotonic()
            try:
                app.cmux("tab", tab, "close", timeout=30)
                ok, err = True, None
            except heavy_profile.Refused as error:
                ok, err = False, str(error)[:400]
            with lock:
                result["closes"].append({"tab": tab, "ms": round((time.monotonic() - start) * 1000, 1), "ok": ok,
                                         "error": err})

    burst_start = time.monotonic()
    threads = [threading.Thread(target=closer) for _ in range(max(1, a.threads))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    t0 = time.monotonic()
    result["burst_s"] = round(t0 - burst_start, 3)
    # Fast samples (the daemon process only) at their real times; the slow host-wide scan only at 10 s.
    result["fast"] = [fast("as soon as the last close answered", t0, pids)]
    for wait in (0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0):
        left = t0 + wait - time.monotonic()
        if left > 0:
            time.sleep(left)
        result["fast"].append(fast("%g s after the burst" % wait, t0, pids))
    left = t0 + 10.0 - time.monotonic()
    if left > 0:
        time.sleep(left)
    result["samples"].append(sample("10 s after the burst", t0, root))
    result["workspace_closed"] = close_workspace(app, result["workspace"])
    time.sleep(5.0)


def verdict(result):
    """Released PTYs against what the tabs added (not one per tab by assumption: review FIX at 48bd6dc87f9)."""
    by = {s_["at"]: s_ for s_ in result["samples"]}
    start = result["samples"][0]
    before = next((s_ for s_ in result["samples"] if s_["at"].startswith("before burst")), None)
    closed_ok = sum(1 for c in result["closes"] if c["ok"])
    made = result.get("made") or 0
    v = {"made": made, "closed_ok": closed_ok}
    if before is None or not made or not closed_ok:
        v["not_measured"] = "no tabs made or no close worked"
        return v
    # The daemon tree when the tabs' PTYs show there (it is what a leak would hold), else the whole user's count.
    key = "daemon_tree" if (before.get("daemon_tree") or 0) - (start.get("daemon_tree") or 0) >= 0.9 * made else "total"
    v["count"] = key
    v["start"], v["before"] = start[key], before[key]
    v["rise"] = before[key] - start[key]
    if v["rise"] < 0.9 * made:
        v["not_measured"] = "the %s /dev/ptmx count rose %d for %d tabs: a tab does not hold one countable PTY" % (key, v["rise"], made)
        return v
    per_tab = v["rise"] / made
    expect = closed_ok * per_tab
    fast_ = [f for f in result.get("fast", []) if f.get("daemon_tree") is not None] if key == "daemon_tree" else []
    at1 = next((f for f in fast_ if f["t_s"] >= 1.0), None)
    if at1 is not None:
        v["at_1s"] = {"t_s": at1["t_s"], "count": at1["daemon_tree"], "released": before[key] - at1["daemon_tree"]}
    ten = by.get("10 s after the burst")
    if ten is not None:
        v["at_10s"] = {"t_s": ten["t_s"], "count": ten[key], "released": before[key] - ten[key]}
    v["first_full_release_s"] = next((f["t_s"] for f in fast_ if before[key] - f["daemon_tree"] >= 0.9 * expect), None)
    released_1s = (v.get("at_1s") or {}).get("released")
    if released_1s is None and ten is not None:  # no fast samples (the tabs' PTYs are outside the daemon tree)
        v["leak_suspect_10s"] = (before[key] - ten[key]) < 0.9 * expect
    v["leak_suspect"] = None if released_1s is None else released_1s < 0.9 * expect
    v["expected_release"] = round(expect, 1)
    return v


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--app-socket", required=True)
    p.add_argument("--home")
    p.add_argument("--app")
    p.add_argument("--cli")
    p.add_argument("--socket")
    p.add_argument("--out", required=True)
    p.add_argument("--tabs", type=int, default=50)
    p.add_argument("--threads", type=int, default=16)
    p.add_argument("--seed", type=int, default=7)
    a = p.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    result = {"tabs": a.tabs, "threads": a.threads, "samples": [], "closes": [], "made": 0}
    path = os.path.join(a.out, "pty-release.json")

    def save():
        with open(path + ".tmp", "w") as f:
            json.dump(result, f, indent=1)
        os.replace(path + ".tmp", path)

    try:
        app = load_profiles.reach_app(argparse.Namespace(home=a.home, app_socket=a.app_socket, app=a.app, cli=a.cli,
                                                         socket=a.socket))
    except (heavy_profile.Refused, OSError, ValueError) as error:
        result["error"] = "could not reach the app: %s" % error
        save()
        print("PTY-RELEASE %s" % json.dumps({"error": result["error"]}), flush=True)
        return 2
    root = daemon_pid(app)
    result["daemon_pid"] = root
    try:
        result["ptmx_max"] = int(subprocess.run(["sysctl", "-n", "kern.tty.ptmx_max"], capture_output=True,
                                                text=True).stdout.strip())
    except ValueError:
        result["ptmx_max"] = None
    result["samples"].append(sample("start", None, root))
    ws = app.cmux("workspace", "create", "--name", "tk-pty-release-%d" % a.seed)
    wid, pane = (ws or {}).get("workspace_id"), (ws or {}).get("pane_id")
    result["workspace"] = wid
    try:
        measure(app, a, result, root, wid, pane)
    finally:  # never leave the tabs behind, whatever failed
        if wid and result.get("workspace_closed") is not True:
            result["workspace_closed"] = close_workspace(app, wid)
        save()
    result["samples"].append(sample("5 s after the workspace close", None, root))
    result["verdict"] = verdict(result)
    save()
    print("PTY-RELEASE %s" % json.dumps(result["verdict"]), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
