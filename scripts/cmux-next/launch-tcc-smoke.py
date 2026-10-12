#!/usr/bin/env python3
"""LAUNCH-NO-TCC-PROMPTS smoke: launch a tagged cmux DEV with no input for N seconds and fail when the
app or any process it starts (daemons, agents, shells, helpers they run) reads inside a folder macOS
guards with a privacy prompt, or asks TCC for anything that can prompt.

Usage (on a Mac with a GUI session, never on a laptop someone is using):
    python3 -I scripts/cmux-next/launch-tcc-smoke.py --app "<cmux DEV <tag>.app>" [--seconds 60] [--launches 2]

Two detectors run together:
1. Read audit (default): the app runs under `sandbox-exec` with a profile that allows everything
   except reading data inside the protected folders (cmux-tui/crates/acpmux/data/protected-folders.json).
   Children inherit the profile. Every denied read is in the kernel log with the process name and
   path; the script maps it to the app's process tree and prints the chain (`rg <- cursor-agent acp
   <- acpmux daemon run`). This works on any Mac, also where TCC would not prompt (no iCloud Drive,
   folders already allowed). `--no-sandbox-audit` turns it off.
2. TCC log: tccd's AUTHREQ lines for the app's bundle id or any binary in the bundle. A request
   fails when it is not a preflight (it can show a prompt) or when it is a file service
   (kTCCServiceSystemPolicy*, kTCCServiceFileProvider*). Other preflights are listed, not failed.
   Use a tag that never ran on this Mac: a new bundle id is a fresh TCC identity.

What runs at launch depends on the Mac: agent model probes start every installed harness, so run it
on a Mac that has the harnesses people use (cursor-agent, opencode, gemini, ...).
`--launches 2` also checks a normal relaunch. The script quits the app (quitEndSessions) and ends the
tag's daemons by exact PID (tag_teardown.py) after each launch.

Exit 0 = PASS; 1 = failing reads or requests (listed); 2 = the run could not be done.
The report is written to <out>/tcc-report.json ($NX_ARTIFACTS when set).
"""
import argparse, json, os, plistlib, re, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

FILE_SERVICES = ("kTCCServiceSystemPolicy", "kTCCServiceFileProvider")
MSG = re.compile(r"msgID=([0-9.]+)")
# The one protected-folder list (also read by acpmux; Swift and TypeScript get generated copies).
PROTECTED_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                              "cmux-tui", "crates", "acpmux", "data", "protected-folders.json")


def load_protected(path):
    with open(path) as handle:
        data = json.load(handle)
    return [entry["path"] for entry in data["inHome"]], [entry["path"] for entry in data["roots"]]


GUARDED_IN_HOME, GUARDED_ROOTS = [], []
DENY = re.compile(r"Sandbox: (.+?)\((\d+)\) deny\(\d+\) (file-read[\w-]*) (.+)$")


def audit_profile(home, marker):
    """A sandbox profile that allows everything except reading inside a protected folder; every
    denied read is reported in the kernel log. Children inherit it, so a read by any process the
    app starts shows with its name and path, also on a Mac where TCC would not prompt."""
    roots = [os.path.join(home, rel) for rel in GUARDED_IN_HOME] + GUARDED_ROOTS
    paths = []
    for root in roots:
        paths.append(root)
        real = os.path.realpath(root)
        if real != root:
            paths.append(real)
    subpaths = " ".join('(subpath "%s")' % path.replace('"', '\\"') for path in paths)
    return '(version 1)\n(allow default)\n(deny file-read-data %s (with message "%s"))\n' % (subpaths, marker)


class DenyLog:
    """`log stream` of the kernel's sandbox read denials that carry this run's marker (the profile's
    `with message`), so every one comes from the app's own tree, also from a process that lived
    only a few milliseconds."""

    def __init__(self):
        self.marker = "cmux-tcc-smoke-%d-%d" % (os.getpid(), int(time.time()))
        self.denials = []
        self.proc = subprocess.Popen(
            ["log", "stream", "--style", "ndjson", "--level", "info",
             "--predicate", 'sender == "Sandbox" AND eventMessage CONTAINS "deny("'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                text = json.loads(line).get("eventMessage", "")
            except ValueError:
                continue
            if self.marker not in text:
                continue
            found = DENY.search(text.strip().splitlines()[0])
            if found:
                self.denials.append({"process": found.group(1), "pid": int(found.group(2)),
                                     "operation": found.group(3), "path": found.group(4)})

    def stop(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        return list(self.denials)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, help="path of the tagged cmux DEV .app")
    p.add_argument("--seconds", type=float, default=60, help="seconds to watch each launch (default 60)")
    p.add_argument("--launches", type=int, default=2, help="1 = fresh launch only; 2 = also a relaunch")
    p.add_argument("--no-sandbox-audit", action="store_true",
                   help="launch without the read audit (sandbox-exec deny + report on protected folders)")
    p.add_argument("--protected-json", default=PROTECTED_JSON,
                   help="the protected-folder list (default: the checkout's cmux-tui/crates/acpmux/data/protected-folders.json)")
    p.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="tcc-smoke-"))
    return p.parse_args()


class TccLog:
    """`log stream` of tccd's AUTHREQ lines, grouped per (tccd pid, message id)."""

    def __init__(self):
        self.requests = {}
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            ["log", "stream", "--style", "ndjson", "--level", "info",
             "--predicate", 'process == "tccd" AND eventMessage BEGINSWITH "AUTHREQ"'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            text = event.get("eventMessage", "")
            found = MSG.search(text)
            if not found:
                continue
            key = "%s/%s" % (event.get("processID"), found.group(1))
            with self.lock:
                entry = self.requests.setdefault(key, {"time": event.get("timestamp")})
                if text.startswith("AUTHREQ_CTX"):
                    entry["service"] = (re.search(r"service=(\w+)", text) or [None, None])[1]
                    entry["preflight"] = (re.search(r"preflight=(\w+)", text) or [None, None])[1]
                    entry["function"] = (re.search(r"function=(\w+)", text) or [None, None])[1]
                elif text.startswith("AUTHREQ_ATTRIBUTION"):
                    entry["attribution"] = text
                elif text.startswith("AUTHREQ_RESULT"):
                    entry["result"] = (re.search(r"authValue=(\d+)", text) or [None, None])[1]

    def stop(self):
        time.sleep(2)  # test harness: let log stream deliver the last lines before it stops
        self.proc.terminate()
        self.proc.wait(timeout=10)
        with self.lock:
            return dict(self.requests)


def process_field(attribution, role, field):
    block = re.search(role + r"=\{TCCDProcess: ([^}]*)\}", attribution or "")
    if not block:
        return None
    value = re.search(field + r"=([^,]*)", block.group(1))
    return value.group(1).strip() if value else None


def ours(entry, bundle_id, app):
    att = entry.get("attribution")
    for role in ("responsible", "accessing"):
        if process_field(att, role, "identifier") == bundle_id:
            return True
        for field in ("binary_path", "responsible_path"):
            path = process_field(att, role, field) or ""
            if path.startswith(app + "/"):
                return True
    return False


def rpc(sock_path, method, params=None, timeout=10):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(sock_path)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


class ProcessTree:
    """Every process seen under `root` (sampled every 0.2 s), to print which process started the one
    that read a protected folder. A process that lived under 0.2 s has no chain; its read still
    counts (the deny log marker proves it came from the app's tree)."""

    def __init__(self, root, app):
        self.root = root
        self.app = app
        self.pids = {root}
        self.info = {}
        self.running = True
        threading.Thread(target=self._sample, daemon=True).start()

    def _sample(self):
        while self.running:
            out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
            parent = {}
            for line in out.split("\n"):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    parent[int(parts[0])] = int(parts[1])
                    if len(parts) == 3:
                        self.info.setdefault(int(parts[0]), (int(parts[1]), parts[2][:200]))
                    # A daemon the app started is re-parented to launchd: its binary is in the bundle.
                    if len(parts) == 3 and parts[2].startswith(self.app + "/"):
                        self.pids.add(int(parts[0]))
            for pid in parent:
                chain, cursor = [], pid
                while cursor in parent and cursor not in self.pids and cursor > 1 and len(chain) < 64:
                    chain.append(cursor)
                    cursor = parent[cursor]
                if cursor in self.pids:
                    self.pids.update(chain)
            time.sleep(0.2)  # test harness: sampling interval of the process tree

    def stop(self):
        self.running = False
        return set(self.pids)

    def chain(self, pid):
        """`command <- parent command <- ...` up to the app, for a report line."""
        out, cursor = [], pid
        while cursor in self.info and len(out) < 6:
            ppid, command = self.info[cursor]
            out.append(command.replace(self.app + "/", "<app>/"))
            if cursor == self.root:
                break
            cursor = ppid
        return " <- ".join(out)


def launch_once(app, tag, seconds, out, index, marker):
    binary = os.path.join(app, "Contents/MacOS/cmux DEV")
    sock_path = "/tmp/cmux-debug-%s.sock" % tag
    scratch = tempfile.mkdtemp(prefix="tcc-smoke-cfg-")
    open(os.path.join(scratch, "cmux.json"), "w").write("{}")
    open(os.path.join(scratch, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
           "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    log = open(os.path.join(out, "app-launch%d.log" % index), "a")
    started = time.time()
    argv = [binary]
    if marker:
        argv = ["/usr/bin/sandbox-exec", "-p", audit_profile(os.environ["HOME"], marker), binary]
    proc = subprocess.Popen(argv, env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, cwd="/tmp")
    tree = ProcessTree(proc.pid, app)
    print("launch %d: pid %d, watching %d s with no input" % (index, proc.pid, seconds), flush=True)
    while time.time() - started < seconds and proc.poll() is None:
        time.sleep(1)  # test harness: a fixed watch window is the measurement itself
    alive = proc.poll() is None
    tree.stop()
    print("launch %d: app %s after %.0f s" % (index, "running" if alive else "exited %s" % proc.returncode,
                                              time.time() - started), flush=True)
    if alive:
        rpc(sock_path, "action.run", {"id": "quitEndSessions"})
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()  # the exact PID this script started
            proc.wait(timeout=10)
    return alive, tree


def main():
    args = parse_args()
    GUARDED_IN_HOME[:], GUARDED_ROOTS[:] = load_protected(args.protected_json)
    app = os.path.realpath(args.app).rstrip("/")
    info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
    bundle_id = info["CFBundleIdentifier"]
    tag = info.get("LSEnvironment", {}).get("CMUX_TAG") or bundle_id.rsplit(".debug.", 1)[-1].replace(".", "-")
    os.makedirs(args.out, exist_ok=True)
    if os.path.exists("/tmp/cmux-debug-%s.sock" % tag):
        print("tag %s already has a socket on this Mac: pick a fresh tag" % tag, flush=True)
        return 2
    teardown = TagTeardown(app)
    teardown.install()
    launches = []
    failing = []
    try:
        for index in range(1, args.launches + 1):
            tcc = TccLog()
            denies = None if args.no_sandbox_audit else DenyLog()
            time.sleep(1)  # test harness: log stream needs a moment before it delivers
            alive, tree = launch_once(app, tag, args.seconds, args.out, index, denies.marker if denies else None)
            requests = tcc.stop()
            home = os.environ["HOME"]
            roots = [os.path.join(home, rel) for rel in GUARDED_IN_HOME] + GUARDED_ROOTS
            denials = []
            for denial in (denies.stop() if denies else []):
                if not any(denial["path"] == r or denial["path"].startswith(r + "/") for r in roots):
                    continue
                if any(d["pid"] == denial["pid"] and d["path"] == denial["path"] for d in denials):
                    continue
                denial["chain"] = tree.chain(denial["pid"]) or "(exited before the process sample)"
                denials.append(denial)
            mine = []
            for key, entry in sorted(requests.items(), key=lambda kv: kv[1].get("time") or ""):
                if not ours(entry, bundle_id, app):
                    continue
                service = entry.get("service") or "?"
                row = {"key": key, "time": entry.get("time"), "service": service,
                       "preflight": entry.get("preflight"), "function": entry.get("function"),
                       "result": entry.get("result"),
                       "accessing": process_field(entry.get("attribution"), "accessing", "binary_path"),
                       "requesting": process_field(entry.get("attribution"), "requesting", "binary_path")}
                row["fails"] = entry.get("preflight") != "yes" or service.startswith(FILE_SERVICES)
                mine.append(row)
                if row["fails"]:
                    failing.append(dict(row, launch=index))
            launches.append({"launch": index, "app_alive_at_end": alive, "requests": mine, "denied_reads": denials})
            for denial in denials:
                failing.append(dict(denial, launch=index, kind="protected-read"))
                print("launch %d: FAIL read in a protected folder: %s(%d) %s %s\n    by: %s" % (
                    index, denial["process"], denial["pid"], denial["operation"], denial["path"],
                    denial.get("chain")), flush=True)
            for row in mine:
                print("launch %d: %s %s preflight=%s accessing=%s requesting=%s" % (
                    index, "FAIL" if row["fails"] else "info", row["service"], row["preflight"],
                    row["accessing"], row["requesting"]), flush=True)
            print("launch %d: %d TCC requests for the app, %d failing; %d protected reads" % (
                index, len(mine), sum(r["fails"] for r in mine), len(denials)), flush=True)
            if index < args.launches:
                teardown.end()
                teardown.done = False
    finally:
        teardown.end()
    report = {"app": app, "bundle_id": bundle_id, "tag": tag, "seconds": args.seconds,
              "launches": launches, "failing": failing}
    with open(os.path.join(args.out, "tcc-report.json"), "w") as handle:
        json.dump(report, handle, indent=2)
    print("TCC_SMOKE %s: %d failing request(s) over %d launch(es); report %s" % (
        "FAIL" if failing else "PASS", len(failing), len(launches), os.path.join(args.out, "tcc-report.json")),
        flush=True)
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
