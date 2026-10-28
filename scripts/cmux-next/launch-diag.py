#!/usr/bin/env python3
"""SCRATCH MEASUREMENT REF ONLY (cp/proof-ab-measure, never lands): why does bench-startup.py's seeding launch
"never draw a terminal" on an optimized build with fresh state (prove-or-remove step p08-08, job e673f4cf)?

For each app (fleet artifacts by sha256, fetched like the reload stub does) it repeats the seeding launch exactly:
bench-startup.py's reset_state(tag), then its Launch env (the launch-marks pipe, CMUX_NEXT_NO_ACTIVATE=1,
CMUX_NEXT_SOCKET_MODE=automation, CMUX_NEXT_TEST_WINDOW_SCREEN=last, a scratch cmux.json), with the app's stdout and
stderr kept in a log. It records every launch mark with its arrival time, and at 10, 30, 60 and 90 s after the spawn
reads the control socket: debug.timings, debug.windows, debug.window_list, debug.surfaces, debug.focus, debug.hangs,
snapshot.get (workspace/tab counts and kinds) and features.list (count on, plus the launch-relevant switches). It
then quits the app, ends the tag's processes, and copies new crash reports of the bundle. One JSON report.

  split-spring.sh --config=<sha256> --suite=launch-diag --diag-apps=<sha256>,<sha256> --diag-tries=2
"""
import argparse, glob, importlib.util, json, os, select, shutil, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)
from bench_launch import socket_candidates, finder_limits  # noqa: E402

READS = ["debug.timings", "debug.windows", "debug.window_list", "debug.surfaces", "debug.focus", "debug.hangs",
         "snapshot.get", "features.list"]
WATCH = ("savedWindowPicture", "launchVisiblePanesOnly", "launchWindowsByOcclusion", "cefLaunchOrigin",
         "browserLaunchPictures", "terminalLaunchPrefetch", "controlSocketEarlyBind", "sentryHandlersFirst",
         "launchStartDeferral", "terminalHolder", "terminalStreams", "agentChromium")


def rpc(path, method, params=None, timeout=8):
    reply = b""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(timeout)
            stream.connect(path)
            stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            while not reply.endswith(b"\n"):
                chunk = stream.recv(1 << 20)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply or b"{}")
        return answer.get("result", answer)
    except (OSError, ValueError) as error:
        return {"diag_error": f"{type(error).__name__}: {error}"[:200]}


def shrink(method, reply):
    """Keeps what answers 'is there a terminal': counts and kinds, not whole trees."""
    if method == "features.list" and isinstance(reply, dict) and isinstance(reply.get("features"), list):
        feats = reply["features"]
        return {"on": sum(1 for f in feats if f.get("state") == "on"), "total": len(feats),
                "watched": {f["name"]: [f.get("state"), f.get("source")] for f in feats if f.get("name") in WATCH}}
    if method == "snapshot.get" and isinstance(reply, dict):
        topo = reply.get("topology") or reply
        text = json.dumps(topo)
        kinds = {}
        for kind in ("terminal", "browser", "agent", "home", "newTab", "page", "chat"):
            kinds[kind] = text.count(f'"kind": "{kind}"') + text.count(f'"kind":"{kind}"')
        return {"bytes": len(text), "workspaces": text.count('"workspace'), "kinds": kinds, "head": text[:1500]}
    text = json.dumps(reply)
    return reply if len(text) <= 6000 else {"truncated": text[:6000]}


def fetch(sha, dest):
    out = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha, "--dest", dest],
                         capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"launch-diag: fetch {sha[:12]} failed: {out.stderr[-400:]}")
    return out.stdout.strip().splitlines()[-1]


def crash_reports(since, words):
    found = []
    for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*")):
        try:
            if os.path.getmtime(path) >= since and any(w in os.path.basename(path) for w in words):
                found.append({"file": os.path.basename(path), "head": open(path, errors="replace").read(3000)})
        except OSError:
            pass
    return found


def one_try(app, out_dir, seconds):
    tag = bs.app_tag(app)
    bs.APPS[tag] = os.path.abspath(app)
    bs.RUN_TAGS[:] = [tag]
    bs.stop(bs.tag_pids(tag))
    bs.reset_state(tag)
    scratch = tempfile.mkdtemp(prefix=f"launch-diag-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as f:
        f.write("{}\n")
    read_fd, write_fd = os.pipe()
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
           "CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd)}
    log_path = os.path.join(out_dir, f"app-{tag}-{int(time.time())}.log")
    started = time.time()
    with open(log_path, "wb") as log, finder_limits():
        proc = subprocess.Popen([bs.app_binary(tag)], env=env, stdout=log, stderr=log, start_new_session=True,
                                pass_fds=(write_fd,))
    os.close(write_fd)
    t0 = time.monotonic()
    marks, buf, reads = [], b"", {}
    checkpoints = [10, 30, 60, seconds]
    while checkpoints:
        left = checkpoints[0] - (time.monotonic() - t0)
        if left <= 0:
            at = checkpoints.pop(0)
            path = next((p for p in socket_candidates(tag) if os.path.exists(p)), None)
            reads[str(at)] = {"socket": path, "alive": proc.poll() is None,
                              **({m: shrink(m, rpc(path, m)) for m in READS} if path else {})}
            continue
        ready, _, _ = select.select([read_fd], [], [], min(left, 1.0))
        if ready:
            chunk = os.read(read_fd, 65536)
            if chunk:
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    name, _, ms = line.decode(errors="replace").partition(" ")
                    marks.append({"mark": name, "app_ms": ms, "arrived_s": round(time.monotonic() - t0, 3)})
    exit_code = proc.poll()
    try:
        os.close(read_fd)
    except OSError:
        pass
    if proc.poll() is None:
        bs.stop([proc.pid], timeout=20)
    bs.stop(bs.tag_pids(tag))
    with open(log_path, errors="replace") as handle:
        log_text = handle.read()
    got = {m["mark"] for m in marks}
    return {"tag": tag, "app": app, "exit_before_end": exit_code, "marks": marks,
            "reached_first_terminal_frame": bs.FINAL_MARK in got, "reached_agent_handshake": bs.AGENT_MARK in got,
            "reads": reads, "app_log_tail": log_text[-6000:], "app_log_bytes": len(log_text),
            "crash_reports": crash_reports(started, ["cmux", "CmuxNext"])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag")
    ap.add_argument("--app")
    ap.add_argument("--out")
    ap.add_argument("--json")
    ap.add_argument("--diag-apps", default="", help="comma list of fleet artifact sha256 (the --config app is first)")
    ap.add_argument("--diag-tries", type=int, default=2)
    ap.add_argument("--diag-seconds", type=int, default=90)
    a, _ = ap.parse_known_args([x for x in sys.argv[1:] if x != "--suite=launch-diag"])
    out_dir = a.out or tempfile.mkdtemp()
    os.makedirs(out_dir, exist_ok=True)
    apps = [a.app] if a.app else []
    for sha in [s for s in a.diag_apps.split(",") if s]:
        apps.append(fetch(sha, os.path.join(out_dir, "apps", sha[:12])))
    report = {"bench": "launch-diag", "host": socket.gethostname().split(".")[0],
              "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
              "load_before": os.getloadavg(), "tries": []}
    for app in apps:
        for index in range(a.diag_tries):
            row = one_try(app, out_dir, a.diag_seconds)
            row["try"] = index
            report["tries"].append(row)
            print(f"LAUNCH-DIAG {row['tag']} try {index}: first_terminal_frame={row['reached_first_terminal_frame']} "
                  f"agent_handshake={row['reached_agent_handshake']} marks={len(row['marks'])} exit={row['exit_before_end']} "
                  f"crashes={len(row['crash_reports'])}", flush=True)
            if a.json:
                with open(a.json, "w") as handle:
                    json.dump(report, handle)
    report["load_after"] = os.getloadavg()
    if a.json:
        with open(a.json, "w") as handle:
            json.dump(report, handle)
    return 0


if __name__ == "__main__":
    sys.exit(main())
