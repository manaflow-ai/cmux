#!/usr/bin/env python3
"""SCRATCH MEASUREMENT (never lands): what Chromium does at idle on the first launch of a build, and on later ones.

The seqmgr idle benches saw the in-process CEF pump wake the main thread about 32 times/s, and the Chromium helpers
plus the daemon at about 7 % CPU, through the 60 s idle window of the first launch of a newly fetched bundle on a host,
against about 1.5/s and 0.2-0.3 % on later launches. This runs cef-idle-probe.py (Chromium's own trace: tasks per
second by posting location in every process, and the pump counters) in rounds that tell the causes apart:

  fresh    the bundle's Chromium root (<Application Support>/<bundle id>/Chromium) moved aside: Chromium's first run
           (profile creation, component and Safe Browsing downloads, caches made from nothing)
  warm     the root the fresh round made (a later launch)
  upgrade  that root with its `Last Version` set older, as after an app update that changes Chromium's version
  warm2    the root again

Around each round's idle window it reads the CPU time of every process of the bundle (the app, its Chromium helpers,
the daemon) and, after the window, samples the busiest helper for 5 s. The original root is put back at the end.

  first-run-idle.py --apps-sha256 HEX [--rounds fresh,warm,upgrade,warm2] [--settle 20] [--window 60]
"""
import argparse, glob, json, os, plistlib, re, shutil, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.getcwd(), "artifacts", "split-spring")


def note(text):
    print(text, flush=True)


def bundle_id(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def processes(app):
    """{pid: (cpu seconds, command)} of every process whose executable is inside `app` or is the tag's daemon."""
    out = subprocess.run(["ps", "-axo", "pid=,time=,command="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\S+)\s+(.*)", line)
        if not m or (app not in m.group(3) and "cmuxd" not in m.group(3) and "cmux-tui" not in m.group(3)):
            continue
        mm = re.match(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)", m.group(2))
        if not mm:
            continue
        secs = int(mm.group(1) or 0) * 86400 + int(mm.group(2) or 0) * 3600 + int(mm.group(3)) * 60 + float(mm.group(4))
        found[int(m.group(1))] = (secs, m.group(3)[-200:])
    return found


def short(command):
    kind = re.search(r"--type=(\S+)", command)
    if kind:
        sub = re.search(r"--utility-sub-type=(\S+)", command)
        return kind.group(1) + (f":{sub.group(1).split('.')[-1]}" if sub else "")
    if re.search(r"/Contents/MacOS/[^/]+$", command.split(" --")[0]) and "Helper" not in command:
        return "app"
    return "other:" + os.path.basename(command.split(" ")[0])[:30]


def cpu_window(app, stop, result):
    """CPU seconds per process from the window's start to `stop` (the probe prints CEF-IDLE-PUMP at its end)."""
    start = processes(app)
    t0 = time.monotonic()
    stop.wait()
    end = processes(app)
    seconds = time.monotonic() - t0
    rows = []
    for pid, (cpu, command) in end.items():
        before = start.get(pid, (0.0, command))[0]
        rows.append({"pid": pid, "kind": short(command), "cpu_pct": round(100 * (cpu - before) / seconds, 2), "new": pid not in start})
    rows.sort(key=lambda r: -r["cpu_pct"])
    result.update({"seconds": round(seconds, 1), "processes": rows,
                   "helpers_daemon_pct": round(sum(r["cpu_pct"] for r in rows if r["kind"] != "app"), 2),
                   "app_pct": round(sum(r["cpu_pct"] for r in rows if r["kind"] == "app"), 2)})


def run_round(name, app, opts):
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)
    cmd = [sys.executable, os.path.join(HERE, "cef-idle-probe.py"), "--app", app, "--out", out, "--queue",
           "--settle", str(opts.settle), "--window", str(opts.window)]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    stopped, cpu = threading.Event(), {}
    lines = []
    # The probe launches, settles `settle` s, probes the pages, pauses 3 s, then traces its window: the CPU window
    # starts about then (launch takes a few seconds) and ends at the probe's CEF-IDLE-PUMP line.
    def delayed():
        time.sleep(opts.settle + 8)
        cpu_window(app, stopped, cpu)
    watcher = threading.Thread(target=delayed, daemon=True)
    watcher.start()
    for line in proc.stdout:
        lines.append(line.rstrip())
        if line.startswith(("CEF-IDLE-PUMP", "CEF-IDLE-POSTED", "CEF-IDLE-TASK", "CEF-IDLE-ERROR", "CEF-IDLE-WINDOW")):
            note(f"   [{name}] {line.rstrip()[:400]}")
        if line.startswith("CEF-IDLE-PUMP"):
            stopped.set()
            watcher.join(timeout=30)
            busiest = next((r for r in cpu.get("processes", []) if r["kind"] != "app"), None) if cpu else None
            if busiest and busiest["cpu_pct"] > 1:
                path = os.path.join(out, f"sample-{busiest['kind'].replace(':', '_')}.txt")
                subprocess.run(["/usr/bin/sample", str(busiest["pid"]), "5", "1", "-mayDie", "-file", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                cpu["sample"] = path
    proc.wait()
    stopped.set()
    watcher.join(timeout=30)
    try:
        report = json.load(open(os.path.join(out, "cef-idle.json")))
    except (OSError, ValueError):
        report = {"error": "no cef-idle.json", "tail": lines[-30:]}
    report["cpu"] = cpu
    note(f"FIRSTRUN {name}: pump {json.dumps(report.get('pump_per_s'))[:300]}")
    note(f"FIRSTRUN {name}: CPU app {cpu.get('app_pct')} %, helpers+daemon {cpu.get('helpers_daemon_pct')} % over {cpu.get('seconds')} s; "
         + ", ".join(f"{r['kind']} {r['cpu_pct']}" for r in cpu.get("processes", [])[:8]))
    if cpu.get("sample"):
        try:
            text = open(cpu["sample"]).read().splitlines()
            heavy = [l for l in text if re.match(r"\s*[+!:| ]*\d+ ", l)]
            report["sample_head"] = heavy[:80]
            for l in heavy[:60]:
                note(f"   [{name}] S {l[:220]}")
        except OSError:
            pass
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="the fetched app (split-spring.sh passes it); else --apps-sha256 is fetched")
    parser.add_argument("--apps-sha256")
    parser.add_argument("--rounds", default="fresh,warm,upgrade,warm2")
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--window", type=float, default=60)
    opts, _ = parser.parse_known_args()
    os.makedirs(OUT, exist_ok=True)
    if opts.app:
        app, fetched = os.path.abspath(opts.app), "split-spring.sh (see its reload stub line: worker cache or download)"
    else:
        sha = opts.apps_sha256.split(",")[0]
        got = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha,
                              "--dest", os.path.join(OUT, "apps", sha[:12])], capture_output=True, text=True)
        note(got.stderr.strip()[-400:])
        if got.returncode != 0:
            sys.exit(f"first-run-idle: fetch failed: {got.stderr[-400:]}")
        app, fetched = got.stdout.strip().splitlines()[-1], got.stderr.strip()[-300:]
    ident = bundle_id(app)
    import pwd
    # The app reads Application Support from the account's home (Foundation), or from $HOME: a step's HOME is a
    # scratch folder, so both candidates are moved aside and the report says which one the app filled.
    homes = []
    for home in (pwd.getpwuid(os.getuid()).pw_dir, os.path.expanduser("~")):
        if home not in homes:
            homes.append(home)
    roots = [os.path.join(h, "Library", "Application Support", ident, "Chromium") for h in homes]
    result = {"bench": "first-run-idle", "host": os.uname().nodename, "app": app, "bundle_id": ident, "roots": roots,
              "roots_existed": [os.path.isdir(r) for r in roots], "fetch": fetched, "rounds": {}}
    note(f"FIRSTRUN app {app} bundle {ident} roots {roots} existed {result['roots_existed']}")
    saved = []
    try:
        for root in roots:
            if os.path.isdir(root):
                shutil.rmtree(root + ".first-run-idle-saved", ignore_errors=True)
                os.rename(root, root + ".first-run-idle-saved")
                saved.append(root)
        for name in opts.rounds.split(","):
            if name == "fresh":
                for root in roots:
                    shutil.rmtree(root, ignore_errors=True)
            if name == "upgrade":
                for root in roots:
                    last = os.path.join(root, "Last Version")
                    if os.path.exists(last):
                        result["last_version"] = open(last).read().strip()
                        open(last, "w").write("100.0.0.0")
                note(f"FIRSTRUN upgrade: Last Version was {result.get('last_version')}")
            result["rounds"][name] = run_round(name, app, opts)
            result["rounds"][name]["roots_used"] = [r for r in roots if os.path.isdir(r)]
            result["rounds"][name]["root_entries"] = {r: sorted(os.listdir(r))[:60] for r in roots if os.path.isdir(r)}
            note(f"FIRSTRUN {name}: Chromium root in use {result['rounds'][name]['roots_used']}")
            with open(os.path.join(OUT, "report.json"), "w") as f:
                json.dump(result, f, indent=1)
    finally:
        for root in saved:
            shutil.rmtree(root, ignore_errors=True)
            os.rename(root + ".first-run-idle-saved", root)
        with open(os.path.join(OUT, "report.json"), "w") as f:
            json.dump(result, f, indent=1)


if __name__ == "__main__":
    main()
