"""Session survival across an update (cx-ncc.45 S4, cx-6so.26), for run.py.

A real update replaces the app and, when the bundled daemon is another build, hands the running
daemons off: the app asks the old cmux-tui daemon to exit without ending its terminals (their
hosts stay), and the old acpmux to exit without ending its agents (their agent hosts stay); the
new daemons adopt them. Two copies of one build would skip the handoff ("same build"), so
`patch_build_stamp` gives v2's cmux-tui and acpmux another build commit (the same bytes
otherwise), which makes the app take the real handoff path.

`Terminal` starts a counter in a terminal before the click and checks after the relaunch that
the same terminal and the same process kept counting through the swap. `Agent` starts an agent
turn that waits on a FIFO (acpmux's own test agent), and checks after the relaunch that the same
agent process was adopted and its turn completes once released.
"""
import json, os, re, select, signal, socket, stat, subprocess, threading, time

HEX = "0123456789abcdef"


def shifted(commit):
    """Another commit of the same length: each hex digit plus one."""
    return "".join(HEX[(HEX.index(c) + 1) % 16] for c in commit)


def bundle_commit(app):
    with open(os.path.join(app, "Contents/Resources/bin/cmux-tui.version")) as f:
        for line in f:
            if line.startswith("commit="):
                return line.strip().split("=", 1)[1]
    raise SystemExit("cmux-tui.version has no commit")


def patch_build_stamp(binary, commit):
    """Rewrites every copy of `commit` (full, then its 9-digit prefix) in `binary` and signs it
    ad hoc again. Returns (full copies, short copies). Writes a new file: overwriting a signed
    Mach-O in place gets it killed at launch."""
    with open(binary, "rb") as f:
        data = f.read()
    other = shifted(commit)
    full = data.count(commit.encode())
    data = data.replace(commit.encode(), other.encode())
    short = data.count(commit[:9].encode())
    data = data.replace(commit[:9].encode(), other[:9].encode())
    mode = os.stat(binary).st_mode
    os.unlink(binary)
    with open(binary, "wb") as f:
        f.write(data)
    os.chmod(binary, stat.S_IMODE(mode))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                    "--preserve-metadata=entitlements,requirements,flags,runtime", binary],
                   check=True, capture_output=True)
    return full, short


def wait_path(path, predicate, timeout):
    """Re-reads `path` on each change of its directory (kqueue) until predicate(path) is truthy;
    returns the value, or None at the deadline. A 1 s cap covers changes inside a subdirectory."""
    directory = path if os.path.isdir(path) else os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd = os.open(directory, os.O_RDONLY)
    kq = select.kqueue()
    kq.control([select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                              select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0)
    deadline = time.monotonic() + timeout
    try:
        while True:
            value = predicate(path)
            if value:
                return value
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            kq.control(None, 1, min(left, 1.0))
    finally:
        os.close(fd)


class Owned:
    """The session processes this run started (agent harnesses and hosts, terminal counters), each by pid and identity
    (start time and command, from `table`: TagTeardown._table). The cleanup ends exactly these, also when every daemon
    that knew them has exited (a cancellation during the handoff), and never a reused pid."""

    def __init__(self, table):
        self.table = table
        self.identities = {}

    def add(self, pid):
        row = self.table().get(pid) if pid else None
        if row:
            self.identities[pid] = row[1:]

    def alive(self):
        rows = self.table()
        return sorted(pid for pid, identity in self.identities.items() if pid in rows and rows[pid][1:] == identity)

    def end(self, log, grace=5):
        """TERM, then KILL, each recorded process that still runs, by its exact pid. Returns the pids left."""
        for signum in (signal.SIGTERM, signal.SIGKILL):
            for pid in self.alive():
                log("stopping session process", pid, signal.Signals(signum).name)
                try:
                    os.kill(pid, signum)  # an exact pid this run started, never a pattern
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + grace
            while self.alive() and time.monotonic() < deadline:
                time.sleep(0.1)
            if not self.alive():
                break
        return self.alive()


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Terminal:
    """A counter in one terminal of the tag's cmux-tui session."""

    COUNTER = ("$|=1; use Time::HiRes qw(time); while (1) { open(my $f, '>>', $ARGV[0]) or die; "
               "printf $f \"%.3f %d\\n\", time, $$; close $f; select(undef, undef, undef, 0.1) }")

    def __init__(self, app, work, log, session):
        # The app's own session (`cmux-app-<tag slug>`); Chief sessions run beside it.
        self.session_name = session
        self.cli = os.path.join(app, "Contents/Resources/bin/cmux")
        self.script = os.path.join(work, "counter.pl")
        self.file = os.path.join(work, "counter.txt")
        self.log = log
        self.socket = None
        self.term = None
        self.pid = None
        with open(self.script, "w") as f:
            f.write(self.COUNTER + "\n")

    @staticmethod
    def daemons(root):
        """(pid, command, start) of the tag's headless cmux-tui daemons; `start` (ps lstart) tells a reused pid apart."""
        out = subprocess.run(["ps", "-axo", "pid=,lstart=,command="], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            parts = line.strip().split(None, 6)
            if len(parts) < 7 or not parts[0].isdigit():
                continue
            command = parts[6]
            if command.startswith(root) and "/cmux-tui " in command and "--headless" in command:
                found.append((int(parts[0]), command, " ".join(parts[1:6])))
        return found

    def session_daemon(self, root, exclude=()):
        """((pid, start), socket) of the daemon that serves this session (`--socket <path>` on its command line), not
        one whose (pid, start) is in `exclude`; or None. The socket path is the same for every daemon of the session,
        so only the identity tells a replacement daemon from the original one."""
        for pid, command, start in self.daemons(root):
            words = command.split()
            if (pid, start) not in exclude and "--socket" in words and self.session_name in words:
                return (pid, start), words[words.index("--socket") + 1]
        return None

    def daemon_socket(self, root, exclude=()):
        """The tag daemon's socket, from its command line (`--socket <path>`)."""
        found = self.session_daemon(root, exclude)
        return found[1] if found else None

    def run(self, *args):
        done = subprocess.run([self.cli, "--socket", self.socket, "--json", *args], capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            raise SystemExit(f"cmux {' '.join(args)} failed ({done.returncode}): {done.stdout}{done.stderr}")
        return done.stdout

    def start(self, root):
        self.socket = wait_path("/", lambda _: self.daemon_socket(root), 60)
        if not self.socket:
            raise SystemExit("no cmux-tui daemon of this tag runs")
        created = self.run("tab", "create", "terminal")
        terms = re.findall(r'"(term_[A-Za-z0-9_-]+)"', created)
        if not terms:
            raise SystemExit(f"tab create terminal named no terminal: {created}")
        self.term = terms[0]
        self.run("terminal", self.term, "write", "--text", f"perl {self.script} {self.file}\n")
        if not wait_path(self.file, lambda p: os.path.exists(p) and os.path.getsize(p) > 0, 30):
            raise SystemExit("the counter did not start")
        self.pid = self.process_pid()
        daemons = self.daemons(root)
        self.daemon_pids = [pid for pid, _, _ in daemons]
        self.daemon_ids = {(pid, start) for pid, _, start in daemons}
        self.log("terminal", self.term, "counter pid", self.pid, "daemons", self.daemon_pids)

    def list_quietly(self):
        try:
            return self.run("terminal", "list")
        except SystemExit as error:
            return str(error)

    def process_pid(self):
        """The counter records its own PID; the terminal API may name only its shell."""
        with open(self.file) as f:
            rows = [line.split() for line in f if line.strip()]
        return int(rows[-1][1]) if rows else None

    def samples(self):
        with open(self.file) as f:
            return [float(line.split()[0]) for line in f if line.strip()]

    def check(self, root, click_unix, relaunched_unix, handoff=True):
        """After the relaunch: the same terminal, the same process, counting through the swap."""
        # The handed-off daemon exits; the new one adopts the terminal hosts after it starts. A handoff passes only
        # through a replacement daemon, told by its identity (pid and start time): it binds the same socket path, and
        # a daemon that never handed off would still list the terminal there.
        socket_before = self.socket
        replacement = None
        if handoff:
            replacement = wait_path("/", lambda _: self.session_daemon(root, exclude=self.daemon_ids), 60)
            self.socket = replacement[1] if replacement else None
        listed = None
        if self.socket:
            listed = wait_path("/", lambda _: (lambda out: out if self.term in out else None)(self.list_quietly()), 30)
        same_terminal = listed is not None
        listed = listed or (self.list_quietly() if self.socket else "no replacement terminal daemon")
        pid_after = self.process_pid() if same_terminal else None
        values = self.samples()
        window = [v for v in values if click_unix - 1 <= v <= relaunched_unix + 1]
        gaps = [b - a for a, b in zip(window, window[1:])]
        return {
            "terminal": self.term, "same_terminal_listed": same_terminal,
            "daemons_before": self.daemon_pids, "daemons_after": [pid for pid, _, _ in self.daemons(root)],
            "socket_before": socket_before, "socket_after": self.socket,
            "replacement_daemon": bool(replacement), "replacement_daemon_pid": replacement[0][0] if replacement else None,
            "list_after": listed[:2000],
            "pid_before": self.pid, "pid_after": pid_after, "pid_alive": bool(self.pid and alive(self.pid)),
            "samples_during_swap": len(window), "max_gap_s": round(max(gaps), 3) if gaps else None,
            "last_sample_after_relaunch": bool(values and values[-1] > relaunched_unix),
        }


class Agent:
    """One agent turn on acpmux's test agent that waits on a FIFO across the update."""

    def __init__(self, acp_home, fake_agent, work, log, configure=True):
        self.home = acp_home
        self.socket = os.path.join(acp_home, "acpmux.sock")
        self.gate = os.path.join(work, "agent-gate")
        self.log = log
        self.session = None
        self.harness_pid = None
        self.conn = None
        os.makedirs(acp_home, exist_ok=True)
        if not configure:
            return
        config = os.path.join(acp_home, "config.json")
        if os.path.exists(config):
            raise SystemExit(f"{config} exists: use a fresh tag")
        with open(config, "w") as f:
            json.dump({"harnesses": {"fake": {"argv": ["python3", fake_agent]}}, "defaultHarness": "fake",
                       "permissionPolicy": "approve-all"}, f)

    def call(self, conn, method, params, reply=True):
        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": method, "method": method, "params": params}) + "\n").encode())
        if not reply:
            return None
        reader = conn.makefile("r")
        for line in reader:
            message = json.loads(line)
            if message.get("id") == method:
                if "error" in message:
                    raise SystemExit(f"acpmux {method}: {message['error']}")
                return message["result"]
        raise SystemExit(f"acpmux closed the socket during {method}")

    def events(self):
        directory = os.path.join(self.home, "sessions", self.session, "events")
        rows = []
        for name in sorted(os.listdir(directory)) if os.path.isdir(directory) else []:
            with open(os.path.join(directory, name)) as f:
                rows += [json.loads(line) for line in f if line.strip()]
        return rows

    def wait_event(self, predicate, timeout):
        return wait_path(os.path.join(self.home, "sessions", self.session, "events"),
                         lambda _: next((e for e in self.events() if predicate(e)), None), timeout)

    def host_record(self):
        with open(os.path.join(self.home, "hosts", f"{self.session}.json")) as f:
            return json.load(f)

    def start(self, timeout=60):
        if not wait_path(self.socket, lambda p: os.path.exists(p), timeout):
            raise SystemExit("the tag's acpmux did not start")
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(30)
        conn.connect(self.socket)
        self.session = self.call(conn, "session/new", {"cwd": os.path.dirname(self.gate), "mcpServers": []})["sessionId"]
        os.mkfifo(self.gate, 0o600)
        # The prompt's reply comes only when the turn ends: send it and keep the connection.
        self.call(conn, "session/prompt",
                  {"sessionId": self.session, "prompt": [{"type": "text", "text": f"gate: {self.gate}"}]}, reply=False)
        self.conn = conn
        if not self.wait_event(lambda e: "before-gate" in json.dumps(e) and e.get("kind") != "prompt", 30):
            raise SystemExit("the agent turn did not start")
        self.host_before = self.identity()
        self.events_before = self.events()
        self.harness_pid = self.host_before.get("harness_pid")
        with open(os.path.join(self.home, "daemon.pid")) as f:
            self.daemon_pid = int(f.read().strip())
        self.log("agent session", self.session, "harness pid", self.harness_pid)

    def identity(self):
        # The host record also contains controller credentials: never publish those.
        record = self.host_record()
        return {key: record.get(key) for key in ("session_id", "incarnation", "start_nonce", "host_pid", "harness_pid")}

    def check(self, timeout=90, handoff=True):
        """After the relaunch: the same agent was adopted; released, its turn completes once."""
        alive_after = bool(self.harness_pid and alive(self.harness_pid))
        adopted = self.wait_event(lambda e: e.get("kind") == "host_adopted", timeout) if handoff else None
        host_after = self.identity()
        with open(os.path.join(self.home, "daemon.pid")) as f:
            daemon_after = int(f.read().strip())
        # The FIFO open blocks until the agent reads it: write from a thread with a deadline.
        writer = threading.Thread(target=lambda: open(self.gate, "w").write("go"), daemon=True)
        writer.start()
        writer.join(timeout)
        result = self.wait_event(lambda e: e.get("kind") == "turn_result", timeout)
        events = self.events()
        if self.conn:
            self.conn.close()
        return {
            "session": self.session, "harness_pid": self.harness_pid, "harness_alive_after_swap": alive_after,
            "host_before": self.host_before, "host_after": host_after, "same_host": self.host_before == host_after,
            "daemon_before": self.daemon_pid, "daemon_after": daemon_after,
            "transcript_prefix_preserved": events[:len(self.events_before)] == self.events_before,
            "turn_results": sum(e.get("kind") == "turn_result" for e in events),
            "host_adopted": bool(adopted), "gate_released": not writer.is_alive(),
            "turn_status": (result or {}).get("msg", {}).get("status"),
            "before_gate_chunks": sum(1 for e in events if "before-gate" in json.dumps(e) and e.get("kind") != "prompt"),
            "after_gate_chunks": sum(1 for e in events if "after-gate" in json.dumps(e) and e.get("kind") != "prompt"),
            "outcome_unknown": any("outcome_unknown" in json.dumps(e) for e in events),
        }
