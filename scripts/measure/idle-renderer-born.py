#!/usr/bin/env python3
"""idle-renderer-born: which Chromium renderer the untouched idle NEXT starts, and why.

ram-baseline (cmuxterm-hq goals/ram-baseline.md, 2026-11-28 rivals step 26aa99a2): in a 300 s idle soak of the
published NIGHTLY, two renderers were born at 162 s (90 MB and 25 MB) and one went, +25 MB/min with nobody
touching the app. rivals.py names a process only by kind. This launches the same NIGHTLY the same way (scratch
HOME, mock keychain, updates off), polls the app's process tree every POLL s for SOAK s, and for each process
born or gone prints its full command line, its RSS and the app's own log lines within WINDOW s of the event
(subsystem com.cmuxterm.app.next), so the spawner is named, not guessed.

Usage: idle-renderer-born.py --app PATH.app [--soak 300] [--poll 2] [--window 6] [--out DIR]
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time
from datetime import datetime, timezone


def tree(root: int) -> dict:
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    keep, frontier = {}, [root]
    while frontier:
        pid = frontier.pop()
        if pid in rows and pid not in keep:
            keep[pid] = rows[pid]
            frontier += [p for p, r in rows.items() if r[0] == pid]
    return keep


def kind(command: str) -> str:
    m = re.search(r"--type=(\S+)", command)
    if not m:
        return os.path.basename(command.split(" --")[0])[:60]
    k = m.group(1)
    for flag in ("--extension-process", "--renderer-client-id=\\S+", "--utility-sub-type=\\S+"):
        f = re.search(flag, command)
        if f:
            k += " " + f.group(0)
    return k


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--soak", type=float, default=300)
    ap.add_argument("--poll", type=float, default=2)
    ap.add_argument("--window", type=float, default=6)
    ap.add_argument("--out", default="artifacts/idle-renderer-born")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="idle-born-")
    home, tmp = os.path.join(profile, "home"), os.path.join(profile, "tmp")
    os.makedirs(os.path.join(home, "Library"))
    os.makedirs(tmp)
    config = os.path.join(profile, "cmux.json")
    json.dump({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, open(config, "w"))
    env = {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/", "USER": os.environ.get("USER", ""),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_MOCK_KEYCHAIN": "1",
           "CMUX_NEXT_NO_ACTIVATE": "1"}
    exe_dir = os.path.join(a.app, "Contents", "MacOS")
    before = set(tree(1))
    start_wall = datetime.now(timezone.utc)
    argv = ["open", "-n", "-g"] + [x for k, v in env.items() for x in ("--env", f"{k}={v}")] + ["-a", a.app]
    subprocess.run(argv, check=True, timeout=60)
    t0 = time.monotonic()
    app_pid = None
    while time.monotonic() - t0 < 60 and app_pid is None:
        for pid, (_, _, cmd) in tree(1).items():
            if pid not in before and cmd.startswith(exe_dir):
                app_pid = pid
                break
        time.sleep(0.5)
    if app_pid is None:
        print("IDLE-BORN error: app process not found within 60 s")
        return 1
    print(f"IDLE-BORN app pid={app_pid} bundle={a.app} launched={start_wall.isoformat()}")
    seen: dict = {}
    events = []
    samples = []
    while time.monotonic() - t0 < a.soak:
        now = time.monotonic() - t0
        cur = tree(app_pid)
        if not cur:
            events.append({"t": round(now, 1), "event": "app-gone", "pid": app_pid})
            break
        for pid, (ppid, rss, cmd) in cur.items():
            if pid not in seen:
                seen[pid] = {"kind": kind(cmd), "command": cmd, "ppid": ppid, "born": round(now, 1), "gone": None,
                             "first_rss_mb": round(rss / 1024, 1)}
                if now > 3 * a.poll:
                    events.append({"t": round(now, 1), "event": "born", "pid": pid, "wall": datetime.now(timezone.utc).isoformat()})
            seen[pid]["last_rss_mb"] = round(rss / 1024, 1)
        for pid, info in seen.items():
            if info["gone"] is None and pid not in cur:
                info["gone"] = round(now, 1)
                events.append({"t": round(now, 1), "event": "gone", "pid": pid, "wall": datetime.now(timezone.utc).isoformat()})
        samples.append({"t": round(now, 1), "rss_mb": {p: round(r[1] / 1024, 1) for p, r in cur.items()}})
        time.sleep(a.poll)
    # the app's own log for the whole run
    log_path = os.path.join(a.out, "app.log")
    start = start_wall.strftime("%Y-%m-%d %H:%M:%S")
    subprocess.run(["log", "show", "--style", "compact", "--info", "--start", start, "--predicate",
                    f'processID == {app_pid} OR subsystem BEGINSWITH "com.cmuxterm"'],
                   stdout=open(log_path, "w"), stderr=subprocess.DEVNULL, timeout=300)
    lines = open(log_path, errors="replace").read().splitlines()

    def near(wall: str) -> list:
        at = datetime.fromisoformat(wall).timestamp()
        hits = []
        for line in lines:
            m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
            if not m:
                continue
            ts = datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f").astimezone().timestamp()
            if abs(ts - at) <= a.window:
                hits.append(line[:400])
        return hits

    print("\n## Processes (full tree, born/gone seconds after launch)\n")
    for pid, info in sorted(seen.items(), key=lambda kv: kv[1]["born"]):
        print(f"- pid {pid} {info['kind']} born {info['born']} gone {info['gone']} rss {info['first_rss_mb']} -> {info['last_rss_mb']} MB")
    print("\n## Events after launch settled\n")
    for e in events:
        info = seen.get(e["pid"], {})
        print(f"### t={e['t']} s {e['event']} pid {e['pid']} {info.get('kind', '')}")
        print(f"command: {info.get('command', '')[:2000]}")
        for hit in near(e["wall"]) if "wall" in e else []:
            print(f"    {hit}")
        print()
    json.dump({"app_pid": app_pid, "processes": seen, "events": events, "samples": samples},
              open(os.path.join(a.out, "result.json"), "w"), indent=1)
    subprocess.run(["kill", "-TERM", str(app_pid)])
    time.sleep(10)
    shutil.rmtree(profile, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
