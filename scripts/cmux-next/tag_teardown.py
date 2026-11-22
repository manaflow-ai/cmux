"""Ends a tagged test build's daemons when a live script exits, also on a failure, Ctrl-C or SIGTERM.

The app keeps cmux-tui (headless), acpmux and their terminal and agent hosts running after it quits
(keep-on-quit), so a live script that only quits the app leaves them behind. Each one holds PTYs,
and a host that runs many scripts runs out of them. `TagTeardown.end()`:

1. `acpmux daemon shutdown` with the tag daemon's own ACPMUX_HOME and ACPMUX_SOCKET;
2. `cmux-tui --socket <its socket> session <its session> shutdown --force` for the tag's headless
   session;
3. waits for every process whose executable is inside the app bundle to exit, then stops each
   leftover by its exact PID (TERM, then KILL); never a pattern kill;
4. prints the counts.

Use: `teardown = TagTeardown(app_path)`, `teardown.install()` once (SIGTERM and SIGHUP raise
SystemExit, so a `finally` runs), and `teardown.end()` in the script's `finally`.
"""
import os, signal, subprocess, sys, time


class TagTeardown:
    def __init__(self, app, acpmux_home=None, acpmux_socket=None, log=None):
        self.app = os.path.realpath(app).rstrip("/")
        self.bin = os.path.join(self.app, "Contents/Resources/bin")
        self.acpmux_home = acpmux_home
        self.acpmux_socket = acpmux_socket
        self.log = log or (lambda line: print(line, flush=True))
        self.done = False

    def install(self):
        def stop(signum, _frame):
            raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, stop)

    def processes(self):
        """(pid, command) of every process whose executable is inside this app bundle."""
        out = subprocess.run(["ps", "-A", "-o", "pid=,command="], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and (parts[1].startswith(self.app + "/") or parts[1].startswith(self.app + " ")):
                found.append((int(parts[0]), parts[1]))
        return found

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
            self.log(f"teardown: acpmux daemon shutdown (ACPMUX_HOME={home}): {self._run([acpmux, 'daemon', 'shutdown'], env)}")
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
            self.log(f"teardown: STILL RUNNING {pid} {cmd[len(self.app):][:120]}")


def pty_count():
    """Open /dev/ptmx handles on this host (the PTY budget), for a before and after check."""
    out = subprocess.run(["lsof", "-n", "/dev/ptmx"], capture_output=True, text=True).stdout
    return max(0, len(out.splitlines()) - 1)


if __name__ == "__main__":
    # `tag_teardown.py <app path>`: end that bundle's daemons now.
    TagTeardown(sys.argv[1]).end()
