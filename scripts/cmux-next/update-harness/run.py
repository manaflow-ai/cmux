#!/usr/bin/env python3
"""Update harness: a real Sparkle update between two copies of a tagged DEV
build, on a GUI host (cmux-lawrence-2, `nx-remote --needs gui`), with the
timeline of the click and the relaunch.

    run.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --out <dir> [--port N]

What it does (plans: .cmux-scratch/hq-ff/updates-plan.md, slice S0):
  1. Generates a throwaway EdDSA key in <out>/work/keys (keys.swift; deleted
     at the end). It is never a release or nightly key.
  2. Copies the app twice (v1, v2). Each copy gets SUPublicEDKey = the
     throwaway key, CMUXNextUpdateHarness = {feed, marks} and its own
     CFBundleVersion (v2 newer), and is signed again ad hoc. Only DEV
     builds read CMUXNextUpdateHarness (UpdateHarness.swift, #if DEBUG).
  3. Zips v2, signs the zip, writes a loopback appcast, serves it on
     127.0.0.1:<port>.
  4. Launches v1 (no activation, automation socket), waits for the update
     to stage (Sparkle downloads, verifies and extracts it with no prompt),
     then runs the install action through the control socket.
  5. Waits for v1 to exit (kernel exit event) and for the relaunched app's
     launch marks, then writes <out>/timeline.json and prints the numbers.
  6. Stops what it started (exact pids), the server, and deletes the key.

Waits are kernel events on the marks file and the process (kqueue), each
with a deadline; nothing sleeps to synchronize.
"""
import argparse, json, os, plistlib, select, shutil, signal, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALL_ACTION = "palette.applyUpdateIfAvailable"
CHECK_ACTION = "palette.checkForUpdates"
RESTORED_MARKS = ["launch.first_window_frame_committed", "launch.launch_snapshot_shown",
                  "launch.daemon_connected", "launch.daemon_version_handoff", "launch.daemon_snapshot_loaded",
                  "launch.sidebar_rows_shown", "launch.first_terminal_content"]


def log(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise SystemExit(f"failed ({r.returncode}): {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout.strip()


def plist_set(app, updates, harness):
    path = os.path.join(app, "Contents/Info.plist")
    with open(path, "rb") as f:
        info = plistlib.load(f)
    info.update(updates)
    info["CMUXNextUpdateHarness"] = harness
    with open(path, "wb") as f:
        plistlib.dump(info, f)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
         "--preserve-metadata=entitlements,requirements,flags,runtime", app])
    return info


class Marks:
    """The marks file, read as it grows (kqueue vnode events)."""

    def __init__(self, path):
        self.path = path
        open(path, "a").close()
        self.fd = os.open(path, os.O_RDONLY)
        self.kq = select.kqueue()
        self.kq.control([select.kevent(self.fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                       select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0)
        self.offset = 0
        self.rows = []

    def read(self):
        with open(self.path) as f:
            f.seek(self.offset)
            data = f.read()
        done = data.rfind("\n") + 1
        self.offset += len(data[:done].encode())
        for line in data[:done].splitlines():
            try:
                self.rows.append(json.loads(line))
            except ValueError:
                pass
        return self.rows

    def wait(self, predicate, timeout):
        """Returns the first row list for which predicate holds, or None at the deadline."""
        deadline = time.monotonic() + timeout
        while True:
            hit = predicate(self.read())
            if hit:
                return hit
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.kq.control(None, 1, left)


def first(rows, name, pid=None, not_pid=None):
    """The first row named `name` (a trailing * matches a prefix)."""
    for r in rows:
        matches = r["name"].startswith(name[:-1]) if name.endswith("*") else r["name"] == name
        if matches and (pid is None or r["pid"] == pid) and (not_pid is None or r["pid"] != not_pid):
            return r
    return None


def wait_exit(pid, timeout):
    kq = select.kqueue()
    try:
        kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
    except OSError:
        return time.time()  # already gone
    events = kq.control(None, 1, timeout)
    return time.time() if events else None


def wait_socket(path, timeout):
    """True once `path` accepts a connection (kqueue on its directory; each
    directory change re-checks), False at the deadline."""
    directory = os.path.dirname(path)
    fd = os.open(directory, os.O_RDONLY)
    kq = select.kqueue()
    kq.control([select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE)], 0)
    deadline = time.monotonic() + timeout
    try:
        while True:
            if os.path.exists(path):
                try:
                    c = socket.socket(socket.AF_UNIX)
                    c.settimeout(2)
                    c.connect(path)
                    c.close()
                    return True
                except OSError:
                    pass
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            # A socket that exists but refuses has no directory event to wait for; re-check within 1 s.
            kq.control(None, 1, min(left, 1.0))
    finally:
        os.close(fd)


def rpc(sock, method, params=None, timeout=10):
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(timeout)
    c.connect(sock)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf) if buf else {}


def processes_under(root):
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if root in command and "run.py" not in command:
            found.append((int(pid), command))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=0, help="loopback port for the appcast (default: a free one)")
    ap.add_argument("--stage-timeout", type=float, default=240)
    ap.add_argument("--relaunch-timeout", type=float, default=120)
    a = ap.parse_args()

    if a.port == 0:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        a.port = probe.getsockname()[1]
        probe.close()
    out = os.path.abspath(a.out)
    work = os.path.join(out, "work")
    if os.path.exists(work):
        shutil.rmtree(work)
    keys, feed = os.path.join(work, "keys"), os.path.join(work, "feed")
    for d in (keys, feed, os.path.join(work, "v1"), os.path.join(work, "v2"), os.path.join(work, "cwd")):
        os.makedirs(d)
    marks_path = os.path.join(work, "marks.ndjson")
    name = os.path.basename(a.app.rstrip("/"))
    v1, v2 = os.path.join(work, "v1", name), os.path.join(work, "v2", name)
    feed_url = f"http://127.0.0.1:{a.port}/appcast.xml"
    sock = f"/tmp/cmux-debug-{a.tag}.sock"
    server = app = None
    result = {"tag": a.tag, "app": name}
    try:
        public_key = run(["swift", os.path.join(HERE, "keys.swift"), "generate", keys])
        run(["/usr/bin/ditto", a.app, v1])
        run(["/usr/bin/ditto", a.app, v2])
        harness = {"feed": feed_url, "marks": marks_path}
        base = int(time.time())
        i1 = plist_set(v1, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base)}, harness)
        i2 = plist_set(v2, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base + 1)}, harness)
        result.update(v1_build=i1["CFBundleVersion"], v2_build=i2["CFBundleVersion"], bundle_id=i1.get("CFBundleIdentifier"))
        archive = os.path.join(feed, "update.zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", v2, archive])
        signature = run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, archive])
        length = os.path.getsize(archive)
        short = i2.get("CFBundleShortVersionString", "0")
        appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>update harness</title>
    <item>
      <title>{short} ({i2['CFBundleVersion']})</title>
      <pubDate>{time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())}</pubDate>
      <sparkle:version>{i2['CFBundleVersion']}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <description><![CDATA[New: the update harness relaunch]]></description>
      <enclosure url="http://127.0.0.1:{a.port}/update.zip" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
        with open(os.path.join(feed, "appcast.xml"), "w") as f:
            f.write(appcast)
        server = subprocess.Popen([sys.executable, "-m", "http.server", str(a.port), "--bind", "127.0.0.1", "--directory", feed],
                                  stdout=open(os.path.join(out, "server.log"), "w"), stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL)
        marks = Marks(marks_path)
        if os.path.exists(sock):
            os.unlink(sock)
        home = os.environ["HOME"]
        env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
               "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local"}
        binary = os.path.join(v1, "Contents/MacOS", i1["CFBundleExecutable"])
        app = subprocess.Popen([binary], env=env, cwd=os.path.join(work, "cwd"), stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(out, "v1.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
        v1_pid = app.pid
        result["v1_pid"] = v1_pid
        log("v1 pid", v1_pid, "build", i1["CFBundleVersion"])
        if not marks.wait(lambda rows: first(rows, "launch.first_window_frame_committed", pid=v1_pid), 120):
            raise SystemExit("v1 showed no window")
        if not wait_socket(sock, 60):
            raise SystemExit(f"v1's control socket {sock} did not open")
        if not first(marks.read(), "updater_created", pid=v1_pid):
            raise SystemExit("v1 did not start the harness updater (is it a DEBUG build with the harness keys?)")
        # Sparkle's launch check may already run; an explicit check makes the run deterministic.
        log("check", json.dumps(rpc(sock, "action.run", {"id": CHECK_ACTION}))[:200])
        staged = marks.wait(lambda rows: first(rows, "phase.ready", pid=v1_pid) or first(rows, "phase.note", pid=v1_pid),
                            a.stage_timeout)
        if not staged or staged["name"] != "phase.ready":
            status = rpc(sock, "updates.status")
            raise SystemExit(f"no staged update: {json.dumps(status)[:1500]}")
        log("staged")
        t_send = time.time()
        reply = rpc(sock, "action.run", {"id": INSTALL_ACTION})
        t_reply = time.time()
        log("install", json.dumps(reply)[:200])
        t_exit = wait_exit(v1_pid, 60)
        if t_exit is None:
            raise SystemExit("v1 did not exit within 60 s of the install")
        app.wait(5)
        restored = marks.wait(lambda rows: all(first(rows, m, not_pid=v1_pid) for m in RESTORED_MARKS[:2]) and rows,
                              a.relaunch_timeout)
        if not restored:
            raise SystemExit("the relaunched app showed no window")
        # The later launch marks arrive within a few seconds; read what came.
        marks.wait(lambda rows: all(first(rows, m, not_pid=v1_pid) for m in RESTORED_MARKS), 20)
        rows = marks.read()
        v2_pid = next(r["pid"] for r in rows if r["pid"] != v1_pid)
        result["v2_pid"] = v2_pid
        with open(os.path.join(v1, "Contents/Info.plist"), "rb") as f:
            result["installed_build"] = plistlib.load(f)["CFBundleVersion"]
        click = first(rows, "install_clicked", pid=v1_pid)["unix_ms"]

        def at(name, pid):
            r = first(rows, name, pid=pid)
            return None if r is None else r["unix_ms"] - click

        timeline = {
            "socket_send_to_click_ms": click - t_send * 1000,
            "socket_reply_ms": (t_reply - t_send) * 1000,
            "click_to": {n: at(n, v1_pid) for n in ["install_started", "install_handed_to_sparkle", "phase.installing",
                                                     "feedback_state", "feedback_frame", "feedback_frame.stalled",
                                                     "feedback_frame_2", "feedback_frame_2.stalled",
                                                     "windows_*", "keep_previous_start", "keep_previous_end", "will_relaunch",
                                                     "main_window_closed.*", "main_window_closed.remaining_0", "will_terminate"]},
            "click_to_v1_exit_ms": t_exit * 1000 - click,
            "click_to_v2": {n: at(n, v2_pid) for n in ["process_start", "updater_created"] + RESTORED_MARKS},
        }
        result["timeline"] = timeline
        result["rows"] = rows
        result["v2_marks"] = sorted({r["name"] for r in rows if r["pid"] == v2_pid and not r["name"].startswith("launch.")})
        log(json.dumps(timeline, indent=1))
        # The relaunched app as the user sees it, and what its updater says.
        try:
            wait_socket(sock, 30)
            shot = os.path.join(out, "v2-window.png")
            result["v2_snapshot"] = rpc(sock, "debug.window_snapshot", {"path": shot}, timeout=30)
            result["v2_status"] = rpc(sock, "updates.status")
        except OSError as error:
            result["v2_socket_error"] = str(error)
    finally:
        with open(os.path.join(out, "timeline.json"), "w") as f:
            json.dump(result, f, indent=1)
        for pid in [result.get("v2_pid"), result.get("v1_pid")]:
            if pid:
                try:
                    os.kill(pid, signal.SIGTERM)
                    wait_exit(pid, 20)
                except ProcessLookupError:
                    pass
        # The tag's daemon, terminal hosts and acpmux run from the copies.
        left = processes_under(work)
        for pid, command in left:
            log("stopping", pid, command[:160])
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for pid, _ in left:
            wait_exit(pid, 10)
        log("LEFTOVERS", processes_under(work))
        if server:
            server.terminate()
            server.wait(10)
        shutil.rmtree(keys, ignore_errors=True)
        # What's New's record for this tag (the old app writes it when the update stages).
        if result.get("bundle_id"):
            record = os.path.join(os.environ["HOME"], "Library/Application Support/cmux-next", result["bundle_id"], "last-update.json")
            if os.path.exists(record):
                with open(record) as f:
                    result["last_update_record_left"] = f.read()
                os.unlink(record)
            with open(os.path.join(out, "timeline.json"), "w") as f:
                json.dump(result, f, indent=1)


if __name__ == "__main__":
    main()
