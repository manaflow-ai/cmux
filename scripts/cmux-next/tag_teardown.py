"""Ends a tagged test build's daemons when a live script exits, also on a failure, Ctrl-C or SIGTERM.

The app keeps cmux-tui (headless), acpmux and their terminal and agent hosts running after it quits
(keep-on-quit), so a live script that only quits the app leaves them behind. Each one holds PTYs,
and a host that runs many scripts runs out of them. `TagTeardown.end()`:

1. `acpmux daemon shutdown --end-agents` with the tag daemon's own ACPMUX_HOME and ACPMUX_SOCKET;
2. `cmux-tui --socket <its socket> session <its session> shutdown --force` for the tag's headless
   session;
3. waits for every process of the tag to exit, then stops each leftover by its exact PID (TERM, then
   KILL); never a pattern kill. A process is the tag's by this bundle path, never by name, bundle id,
   environment or launcher ancestry (the daemons detach through `cmux-tui server ensure`; two copies of a
   tag at two paths, two tags that sanitize to one id, or a `reload.sh --bundle-id` share a bundle id):
   - its executable is inside the app bundle ("bundle");
   - a terminal host ("host") whose `--owner <bundle>:<tag>@<pid>` names this bundle id AND either names,
     as `<pid>`, a daemon of this bundle path that runs now (hosts run from a content-addressed copy
     outside the bundle, host_exe.rs, and keep the pid of the daemon that spawned them), or is the
     `host_pid` of a host record (`<host root>/<terminal>.json`) in one of the tag's host roots;
   - a terminal holder ("holder", `cmux-holder` or `__holder`) whose `--socket` is the socket of one of the
     tag's host roots (`/tmp/cmux-hd-<uid>/<fnv1a of the host root>.sock`, holder_runtime/service.rs);
   - a direct child of a bundle process or host (the daemon's holder, the app's own children), or of a
     host or holder of the tag (the shells of its terminals); never further.
   The tag's host roots are the `terminal-hosts-*` folders of its daemon state root, the
   `CMUX_TUI_STATE_DIR` a daemon of this bundle path runs with (read once per daemon, from its own
   environment; kept after it exits). So a host or holder whose daemon died (a crash, or the shutdown
   in steps 1-2) is still found, also by a new process (`tag_teardown.py <app>`) when the app started
   another daemon since. A process matched once also stays matched while the same process runs: the same
   pid with the same start time and command (a pid reused by another `-zsh` is another process).
   This script and its ancestors never match (a script run from a terminal of the tag);
4. prints the counts.

Use: `teardown = TagTeardown(app_path)`, `teardown.install()` once (SIGTERM and SIGHUP raise
SystemExit, so a `finally` runs), and `teardown.end()` in the script's `finally`. A script that may
end the tag more than once (a relaunch) keeps one TagTeardown and calls `teardown.remember()` after each
launch: it records the daemon's state root while the daemon runs, so a daemon that dies before end() still
leaves its hosts and holders findable, and it arms end() again for that launch.
"""
import ctypes, glob, json, os, plistlib, re, signal, struct, subprocess, sys, time

# A terminal host's argv (host_session.rs host_owner_args): `--owner <bundle>:<tag>@<daemon pid>`, each part
# sanitized to [A-Za-z0-9._-].
OWNER = re.compile(r"(?:^|\s)--owner ([A-Za-z0-9._-]+):([A-Za-z0-9._-]+)@(\d+)(?:\s|$)")
# The daemon inside the bundle, relative to it.
DAEMON = "/Contents/Resources/bin/cmux-tui "


class Records:
    """What the tag's host roots name: the `host_pid` of every host record and the socket of every root's holder."""

    def __init__(self, host_pids=(), holder_sockets=()):
        self.host_pids = set(host_pids)
        self.holder_sockets = set(holder_sockets)


def fnv1a(data):
    """64-bit FNV-1a (holder_runtime/service.rs fnv1a)."""
    value = 0xcbf29ce484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return value


def holder_socket(host_root, uid=None):
    """The socket of a host root's holder: `/tmp/cmux-hd-<uid>/<fnv1a of the root's bytes>.sock` (service.rs
    socket_path)."""
    uid = os.getuid() if uid is None else uid
    return f"/tmp/cmux-hd-{uid}/{fnv1a(os.fsencode(host_root)):016x}.sock"


def host_records(state_roots, uid=None):
    """The ``Records`` of the `terminal-hosts-*` folders (unix terminal_host_root) of `state_roots`."""
    records = Records()
    for root in state_roots:
        # PathBuf::join spelling: the root as the daemon got it, one `/`, the folder name.
        for host_root in glob.glob(os.path.join(glob.escape(root), "terminal-hosts-*")):
            if not os.path.isdir(host_root):
                continue
            records.holder_sockets.add(holder_socket(host_root, uid))
            for path in glob.glob(os.path.join(glob.escape(host_root), "*.json")):
                try:
                    with open(path) as f:
                        pid = json.load(f).get("host_pid")
                except (OSError, ValueError, AttributeError):
                    continue
                if isinstance(pid, int) and pid > 1:
                    records.host_pids.add(pid)
    return records


def procargs(pid):
    """(argv, environment dict) of a process of this user, exactly as it got them (sysctl KERN_PROCARGS2), or None.
    `ps eww` joins words with spaces, so a value with a space (`~/Library/Application Support/...`) cannot be read
    back from it."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        size = ctypes.c_int(0)
        length = ctypes.c_size_t(ctypes.sizeof(size))
        if libc.sysctl((ctypes.c_int * 2)(1, 8), 2, ctypes.byref(size), ctypes.byref(length), None, 0) != 0:  # KERN_ARGMAX
            return None
        buffer = ctypes.create_string_buffer(size.value)
        length = ctypes.c_size_t(size.value)
        if libc.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buffer, ctypes.byref(length), None, 0) != 0:  # KERN_PROCARGS2
            return None
    except (OSError, AttributeError):
        return None
    raw = buffer.raw[:length.value]
    if len(raw) < 4:
        return None
    argc = struct.unpack_from("i", raw)[0]
    # argc, the exec path, NUL padding, then argc argument strings and the environment strings.
    words = [word for word in raw[4:].split(b"\0")]
    words = words[1:]  # the exec path
    while words and words[0] == b"":
        words.pop(0)
    argv, rest = words[:argc], words[argc:]
    env = {}
    for word in rest:
        if not word:
            break
        name, sep, value = word.partition(b"=")
        if sep:
            env[os.fsdecode(name)] = os.fsdecode(value)
    return [os.fsdecode(word) for word in argv], env


class TagTeardown:
    def __init__(self, app, acpmux_home=None, acpmux_socket=None, log=None, acpmux_home_ok=None):
        self.app = os.path.realpath(app).rstrip("/")
        # acpmux_home_ok(home): False keeps step 1 from sending `daemon shutdown` to that home (a daemon of the bundle
        # in a home that is not the tag's own may be a client of another daemon there); step 3 still stops the
        # bundle's own process by its PID. None: every home.
        self.acpmux_home_ok = acpmux_home_ok
        self.bin = os.path.join(self.app, "Contents/Resources/bin")
        self.acpmux_home = acpmux_home
        self.acpmux_socket = acpmux_socket
        self.log = log or (lambda line: print(line, flush=True))
        self.done = False
        # (pid, start) -> (command, role) of every process matched so far that still runs (matches).
        self.seen = {}
        # The daemon state roots of this bundle path's daemons (CMUX_TUI_STATE_DIR), kept after a daemon exits, and
        # the (pid, start) of each daemon already read.
        self.state_roots = set()
        self.daemons_read = set()

    def install(self):
        def stop(signum, _frame):
            raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, stop)

    def bundle_id(self):
        try:
            with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as f:
                return plistlib.load(f).get("CFBundleIdentifier")
        except (OSError, ValueError):
            return None

    @staticmethod
    def _owner_part(value):
        """cmux-tui's `--owner` spelling of a bundle id (host_session.rs owner_part)."""
        return re.sub(r"[^A-Za-z0-9._-]", "_", value[:96]) if value else "-"

    @staticmethod
    def _table():
        """{pid: (ppid, start, command)} of every process (`ps -A`; `start` is its `lstart`, so a pid with another start
        is another process; no environment is read)."""
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,lstart=,command="], capture_output=True, text=True).stdout
        rows = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 7)
            if len(parts) == 8 and parts[0].isdigit() and parts[1].isdigit():
                rows[int(parts[0])] = (int(parts[1]), " ".join(parts[2:7]), parts[7])
        return rows

    @staticmethod
    def _lineage(rows, pid):
        """`pid` and each of its ancestors in `rows` ({pid: (ppid, start, command)})."""
        seen = set()
        while pid > 1 and pid not in seen:
            seen.add(pid)
            pid = rows.get(pid, (0,))[0]
        return seen

    def in_bundle(self, command):
        return self._relative(command) is not None

    def _relative(self, command):
        """`command` relative to the bundle when it runs from it, else None. The app names some helpers by /var/...
        or /tmp/... without the /private its realpath carries (an app copy in $TMPDIR); match them by the resolved
        spelling."""
        resolved = "/private" + command if command.startswith(("/var/", "/tmp/")) else command
        if resolved.startswith(self.app + "/") or resolved.startswith(self.app + " "):
            return resolved[len(self.app):]
        return None

    @staticmethod
    def _is_holder(command):
        """A terminal holder: the standalone `cmux-holder` (argv0, host_exe.rs HOLDER_NAME) or the host binary's
        built-in `__holder`."""
        words = command.split()
        return bool(words) and (os.path.basename(words[0]) == "cmux-holder" or " __holder " in f" {command} ")

    def matches(self, rows, bundle, exclude=None, records=None):
        """The rows ({pid: (ppid, start, command)}) that are this tag's processes (see the module doc), as sorted
        (pid, command). `records` (``Records``) are what the tag's host roots name. `exclude` (default: this process
        and its ancestors) never matches. Records what it matched in `self.seen`, so a later call still finds a
        process whose parent or daemon exited, while that same process runs."""
        records = records or Records()
        exclude = self._lineage(rows, os.getpid()) if exclude is None else set(exclude)
        roles = {}
        for pid, (ppid, start, command) in rows.items():
            known = self.seen.get((pid, start))
            if known and known[0] == command:
                roles[pid] = known[1]
        for pid, (ppid, start, command) in rows.items():
            if self.in_bundle(command):
                roles[pid] = "bundle"
        # A host's `@<pid>` must be a daemon of this bundle path that runs now (a pid of a daemon that exited may be
        # another process's), or the host must be in one of the tag's host records; its bundle part must be this
        # bundle id either way (another path's daemon with the same id has another pid). Two copies of one tag share
        # one daemon session and state root, so they never run their own daemons at once.
        daemons = {pid for pid, (_, _, command) in rows.items() if self.in_bundle(command)}
        owner_bundle = self._owner_part(bundle) if bundle else None
        for pid, (ppid, start, command) in rows.items():
            found = OWNER.search(command) if owner_bundle else None
            if found and found.group(1) == owner_bundle and (int(found.group(3)) in daemons or pid in records.host_pids):
                roles[pid] = "host"
            elif self._is_holder(command) and self._flag(command, "--socket") in records.holder_sockets:
                roles[pid] = "holder"
        # One level down from a bundle process (its holder, the app's own children), one from a host or holder (the
        # shells of the tag's terminals); never further, never by environment.
        for parents, child_role in ((("bundle", "host"), None), (("host", "holder"), "child")):
            for pid, (ppid, start, command) in rows.items():
                if pid in roles or roles.get(ppid) not in parents:
                    continue
                roles[pid] = child_role or ("holder" if self._is_holder(command) else "child")
        # A process that no longer runs never comes back with the same pid and start: forget it.
        self.seen = {key: value for key, value in self.seen.items() if rows.get(key[0], (0, None))[1] == key[1]}
        found = {}
        for pid, role in roles.items():
            if pid in exclude:
                continue
            self.seen[(pid, rows[pid][1])] = (rows[pid][2], role)
            found[pid] = rows[pid][2]
        return sorted(found.items())

    def learn_state_roots(self, rows, read=procargs):
        """Adds the CMUX_TUI_STATE_DIR of each daemon of this bundle path in `rows` not read yet to `state_roots`
        (`read`: procargs)."""
        for pid, (_, start, command) in rows.items():
            relative = self._relative(command)
            if relative is None or not relative.startswith(DAEMON) or (pid, start) in self.daemons_read:
                continue
            self.daemons_read.add((pid, start))
            found = read(pid)
            root = found[1].get("CMUX_TUI_STATE_DIR") if found else None
            if root:
                self.state_roots.add(root)

    def processes(self):
        """(pid, command) of every process of this tag."""
        rows = self._table()
        self.learn_state_roots(rows)
        return self.matches(rows, self.bundle_id(), records=host_records(self.state_roots))

    def remember(self):
        """Records the tag's processes and its daemon's state root now, and arms end() again: call after each launch
        (the daemon runs then), so a daemon that dies before end() still leaves its hosts and holders findable."""
        self.done = False
        return self.processes()

    def shown(self, command):
        """`command` for the log: relative to the bundle when it runs from it, else whole; shortened."""
        relative = self._relative(command)
        return (command if relative is None else relative)[:160]

    @staticmethod
    def _environment(pid):
        """A process's own environment (same user only), exactly (procargs)."""
        found = procargs(pid)
        return found[1] if found else {}

    @staticmethod
    def _flag(command, name):
        words = command.split()
        return words[words.index(name) + 1] if name in words and words.index(name) + 1 < len(words) else None

    def _run(self, argv, env=None, timeout=30):
        try:
            done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
            return f"exit {done.returncode} {(done.stdout + done.stderr).strip()[:200]}"
        except (OSError, subprocess.TimeoutExpired) as error:
            return f"failed: {error}"

    def end(self):
        if self.done:
            return
        self.done = True
        before = self.processes()
        # 1. acpmux, with its own home and socket.
        acpmux = os.path.join(self.bin, "acpmux")
        daemons = [(pid, cmd) for pid, cmd in before if cmd.startswith(acpmux + " daemon run")]
        homes = {(self.acpmux_home, self.acpmux_socket)} if self.acpmux_home else set()
        for pid, _ in daemons:
            found = self._environment(pid)
            if found.get("ACPMUX_HOME"):
                homes.add((found["ACPMUX_HOME"], found.get("ACPMUX_SOCKET")))
        for home, sock in homes:
            if self.acpmux_home_ok is not None and not self.acpmux_home_ok(home):
                self.log(f"teardown: no acpmux daemon shutdown in ACPMUX_HOME={home}: not a home of this tag")
                continue
            env = dict(os.environ, ACPMUX_HOME=home)
            if sock:
                env["ACPMUX_SOCKET"] = sock
            # The tag's own agents end (`--end-agents`, cx-qryd0); a bundle of a build before the
            # flag refuses it, and its plain shutdown ends them.
            result = self._run([acpmux, 'daemon', 'shutdown', '--end-agents'], env)
            if "unexpected argument" in result:
                result = self._run([acpmux, 'daemon', 'shutdown'], env)
            self.log(f"teardown: acpmux daemon shutdown --end-agents (ACPMUX_HOME={home}): {result}")
        # 2. The tag's cmux-tui headless session.
        tui = os.path.join(self.bin, "cmux-tui")
        for pid, cmd in before:
            if not cmd.startswith(tui + " --headless"):
                continue
            session, sock = self._flag(cmd, "--session"), self._flag(cmd, "--socket")
            if session and sock:
                self.log(f"teardown: cmux-tui session {session} shutdown: {self._run([tui, '--socket', sock, 'session', session, 'shutdown', '--force'])}")
        # 3. Every process of the bundle exits; a leftover is stopped by its exact PID.
        deadline = time.time() + 15
        while time.time() < deadline and self.processes():
            time.sleep(0.5)
        left = self.processes()
        for pid, _ in left:
            try:
                os.kill(pid, signal.SIGTERM)  # an exact PID of this bundle, never a pattern
            except ProcessLookupError:
                pass
        deadline = time.time() + 5
        while time.time() < deadline and self.processes():
            time.sleep(0.5)
        killed = self.processes()
        for pid, _ in killed:
            try:
                os.kill(pid, signal.SIGKILL)  # an exact PID of this bundle, never a pattern
            except ProcessLookupError:
                pass
        time.sleep(0.5)
        after = self.processes()
        # 4. The counts.
        self.log(f"teardown: {len(before)} processes of the bundle at exit, {len(left)} left after the shutdowns "
                 f"(TERM by PID), {len(killed)} after TERM (KILL by PID), {len(after)} left now")
        for pid, cmd in after:
            self.log(f"teardown: STILL RUNNING {pid} {self.shown(cmd)}")


def pty_count():
    """Open /dev/ptmx handles on this host (the PTY budget), for a before and after check."""
    out = subprocess.run(["lsof", "-n", "/dev/ptmx"], capture_output=True, text=True).stdout
    return max(0, len(out.splitlines()) - 1)


if __name__ == "__main__":
    # `tag_teardown.py <app path>`: end that bundle's daemons now.
    TagTeardown(sys.argv[1]).end()
