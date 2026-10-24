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
   its executable is inside the app bundle; or it is a terminal host whose
   `--owner <bundle>:<tag>@<pid>` names this bundle id AND, as `<pid>`, a daemon of this bundle path
   (hosts run from a content-addressed copy outside the bundle, host_exe.rs, and keep the pid of the
   daemon that spawned them); or its direct parent is one of those (the daemon's holder, `cmux-holder`
   or `__holder`, and the app's own children); or its direct parent is a host or holder of the tag (the
   shells of its terminals). A process matched once stays matched while the same pid runs the same
   command, so a host or holder whose daemon already exited (the shutdown in steps 1-2) is still found.
   This script and its ancestors never match (a script run from a terminal of the tag);
4. prints the counts.

Use: `teardown = TagTeardown(app_path)`, `teardown.install()` once (SIGTERM and SIGHUP raise
SystemExit, so a `finally` runs), and `teardown.end()` in the script's `finally`. A script whose app
daemon may restart mid-run calls `teardown.remember()` after each launch, so hosts the earlier daemon
spawned are still found by its pid.
"""
import os, plistlib, re, signal, subprocess, sys, time

# A terminal host's argv (host_session.rs host_owner_args): `--owner <bundle>:<tag>@<daemon pid>`, each part
# sanitized to [A-Za-z0-9._-].
OWNER = re.compile(r"(?:^|\s)--owner ([A-Za-z0-9._-]+):([A-Za-z0-9._-]+)@(\d+)(?:\s|$)")


class TagTeardown:
    def __init__(self, app, acpmux_home=None, acpmux_socket=None, log=None):
        self.app = os.path.realpath(app).rstrip("/")
        self.bin = os.path.join(self.app, "Contents/Resources/bin")
        self.acpmux_home = acpmux_home
        self.acpmux_socket = acpmux_socket
        self.log = log or (lambda line: print(line, flush=True))
        self.done = False
        self.seen = {}  # pid -> (command, role) of every process matched so far (matches)

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
        """{pid: (ppid, command)} of every process (`ps -A`; no environment is read)."""
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        rows = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                rows[int(parts[0])] = (int(parts[1]), parts[2])
        return rows

    @staticmethod
    def _lineage(rows, pid):
        """`pid` and each of its ancestors in `rows` ({pid: (ppid, command)})."""
        seen = set()
        while pid > 1 and pid not in seen:
            seen.add(pid)
            pid = rows.get(pid, (0, ""))[0]
        return seen

    def in_bundle(self, command):
        # The app names some helpers by /var/... or /tmp/... without the /private its realpath
        # carries (an app copy in $TMPDIR); match them by the resolved spelling.
        resolved = "/private" + command if command.startswith(("/var/", "/tmp/")) else command
        return resolved.startswith(self.app + "/") or resolved.startswith(self.app + " ")

    @staticmethod
    def _is_holder(command):
        """A terminal holder: the standalone `cmux-holder` (argv0, host_exe.rs HOLDER_NAME) or the host binary's
        built-in `__holder`."""
        words = command.split()
        return bool(words) and (os.path.basename(words[0]) == "cmux-holder" or (len(words) > 1 and words[1] == "__holder"))

    def matches(self, rows, bundle, exclude=None):
        """The rows ({pid: (ppid, command)}) that are this tag's processes (see the module doc), as sorted
        (pid, command). `exclude` (default: this process and its ancestors) never matches. Records what it matched
        in `self.seen` ({pid: (command, role)}), so a later call still finds a host or holder whose daemon exited."""
        seen = self.seen
        exclude = self._lineage(rows, os.getpid()) if exclude is None else set(exclude)
        roles = {}
        # A process matched before keeps its role while the same pid runs the same command.
        for pid, (ppid, command) in rows.items():
            if pid in seen and seen[pid][0] == command:
                roles[pid] = seen[pid][1]
        for pid, (ppid, command) in rows.items():
            if self.in_bundle(command):
                roles[pid] = "bundle"
        # A host's `@<pid>` must be a daemon of this bundle path, now or earlier (a daemon that exited keeps its pid
        # in `seen`), and its bundle part this bundle id: another path's daemon with the same id has another pid.
        daemons = {pid for pid, role in roles.items() if role == "bundle"} | {pid for pid, (_, role) in seen.items() if role == "bundle"}
        owner_bundle = self._owner_part(bundle) if bundle else None
        for pid, (ppid, command) in rows.items():
            found = OWNER.search(command) if owner_bundle else None
            if found and found.group(1) == owner_bundle and int(found.group(3)) in daemons:
                roles[pid] = "host"
        # One level down from a bundle process (its holder, the app's own children), one from a host or holder (the
        # shells of the tag's terminals); never further, never by environment.
        for parents, child_role in ((("bundle", "host"), None), (("host", "holder"), "child")):
            for pid, (ppid, command) in rows.items():
                if pid in roles or roles.get(ppid) not in parents:
                    continue
                roles[pid] = child_role or ("holder" if self._is_holder(command) else "child")
        found = {}
        for pid, role in roles.items():
            if pid in exclude:
                continue
            seen[pid] = (rows[pid][1], role)
            found[pid] = rows[pid][1]
        return sorted(found.items())

    def processes(self):
        """(pid, command) of every process of this tag."""
        return self.matches(self._table(), self.bundle_id())

    def remember(self):
        """Records the tag's processes now (its daemons' pids): call after a launch when the daemon may restart
        before end()."""
        return self.processes()

    def shown(self, command):
        """`command` for the log: relative to the bundle when it runs from it, else whole; shortened."""
        return (command[len(self.app):] if self.in_bundle(command) else command)[:160]

    @staticmethod
    def _environment(pid):
        """NAME=value words of a process's own environment (`ps eww`, same user only)."""
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        return dict(word.split("=", 1) for word in out.split() if "=" in word and word.split("=", 1)[0].isupper())

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
