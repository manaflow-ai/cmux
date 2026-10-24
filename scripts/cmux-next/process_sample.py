"""Resource samples of a running app and the host, for crash-cause benches (best effort, no root).

Lifted from PL-verify's batch2-verify-bench.py crash part (scratch commit f23d729efde) so the Chromium tab-count
bench and the batch2-verify crash runs record the same fields and their samples compare:

  resources(pid)   open descriptors by type (lsof), threads, child processes, resident MB, Mach ports (top),
                   system memory, memory_pressure free percentage, vm_stat free/compressor/swapouts, CEF helpers,
                   plus the GUI session (the console user, the screen lock, the account's gui/UID launchd domain
                   and the WindowServer pid): a session that ends kills every app in it.
  report_cap()     whether this host's crash reporter refuses reports (osanalyticshelper's 25-log limit), so a
                   death with no .ips is not read as "no crash".
  exit_signal(rc)  the signal name of a Popen return code below 0.
"""
import glob, os, re, signal, subprocess, time

from bench_launch import account_home, gui_session


def _run(argv, timeout):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def session_state():
    """The GUI session an app of this account lives in: console user, screen lock, gui/UID domain, WindowServer."""
    out = {}
    try:
        session = gui_session()
        out["console_user"], out["screen_locked"], out["gui_ok"] = session["console_user"], session["screen_locked"], session["ok"]
    except Exception as error:  # noqa: BLE001 - a sample records what it could read
        out["gui_error"] = repr(error)[:120]
    try:
        out["gui_domain"] = _run(["/bin/launchctl", "print", f"gui/{os.getuid()}"], 20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        out["windowserver"] = (_run(["/usr/bin/pgrep", "-x", "WindowServer"], 10).stdout.split() or [None])[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


def resources(pid):
    """Open file descriptors, threads, child processes, resident MB and Mach ports of `pid`, the host's memory and
    the GUI session (best effort: a field it could not read is missing)."""
    out = {"t": time.strftime("%H:%M:%S"), "epoch": round(time.time(), 1)}
    try:
        lsof = _run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(pid), "-d", "0-1000000", "-F", "ft"], 30).stdout.splitlines()
        types = {}
        for line in lsof:
            if line.startswith("t"):
                types[line[1:]] = types.get(line[1:], 0) + 1
        out["fds"] = sum(1 for line in lsof if line.startswith("f"))
        out["fd_types"] = dict(sorted(types.items(), key=lambda kv: -kv[1])[:6])
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        out["threads"] = max(0, len(_run(["ps", "-M", "-p", str(pid)], 10).stdout.splitlines()) - 1)
        out["rss_mb"] = round(int(_run(["ps", "-o", "rss=", "-p", str(pid)], 10).stdout.strip() or 0) / 1024)
        out["children"] = len(_run(["pgrep", "-P", str(pid)], 10).stdout.split())
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    try:
        # `top` reads the app's Mach port count without root (lsmp needs it).
        top = _run(["/usr/bin/top", "-l", "1", "-pid", str(pid), "-stats", "pid,ports,mem,threads"], 20).stdout.splitlines()
        row = next((l.split() for l in top if l.strip().startswith(str(pid))), None)
        if row and len(row) >= 4:
            out["ports"] = int(re.sub(r"\D", "", row[1]) or 0)
            out["top_mem"] = row[2]
        out["system_mem"] = next((l.split(":", 1)[1].strip() for l in top if l.startswith("PhysMem")), None)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    try:
        pressure = _run(["/usr/bin/memory_pressure", "-Q"], 20).stdout
        match = re.search(r"free percentage:\s*(\d+)%", pressure)
        out["mem_free_pct"] = int(match.group(1)) if match else None
        vm = _run(["/usr/bin/vm_stat"], 10).stdout
        page = int(re.search(r"page size of (\d+)", vm).group(1))

        def pages(name):
            m = re.search(rf"{name}:\s+(\d+)", vm)
            return round(int(m.group(1)) * page / 2**20) if m else None
        out["vm_mb"] = {"free": pages("Pages free"), "compressor": pages("Pages occupied by compressor"),
                        "swapouts": pages("Swapouts")}
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError):
        pass
    try:
        out["cef_helpers"] = len(_run(["pgrep", "-P", str(pid), "-f", "Helper"], 10).stdout.split())
    except (OSError, subprocess.TimeoutExpired):
        pass
    out["session"] = session_state()
    return out


def report_dirs():
    dirs = [os.path.join(os.environ.get("HOME", ""), "Library/Logs/DiagnosticReports"),
            os.path.join(account_home(), "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
    return list(dict.fromkeys(d for d in dirs if d))


def report_cap(window="1d"):
    """Whether the host's crash reporter refused reports in `window` (osanalyticshelper's 25-log limit)."""
    try:
        text = _run(["/usr/bin/log", "show", "--last", window, "--style", "compact", "--predicate",
                     'process == "osanalyticshelper" AND eventMessage CONTAINS "limit of 25"'], 600).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    hits = [l for l in text.splitlines() if "limit of 25" in l]
    # Reports of the crash type (309) written in the last day: at 24 or more the next crash may be the one dropped.
    recent, cutoff = 0, time.time() - 86400
    for folder in report_dirs():
        for path in glob.glob(os.path.join(folder, "*.ips")):
            try:
                if os.path.getmtime(path) >= cutoff:
                    with open(path, errors="replace") as f:
                        recent += '"bug_type":"309"' in f.readline()
            except OSError:
                pass
    return {"refusals": len(hits), "last": hits[-1][:200] if hits else None, "reports_309_last_day": recent,
            "at_cap": bool(hits) or recent >= 24}


def exit_signal(code):
    """The signal name of a Popen return code (-N: killed by signal N), else None."""
    if isinstance(code, int) and code < 0:
        try:
            return signal.Signals(-code).name
        except ValueError:
            return f"signal {-code}"
    return None
