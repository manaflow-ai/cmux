#!/usr/bin/env python3
"""A Codex Cloud chat proof on a real `chatgpt-plan` connection: the agent test account's Codex CLI login
(CODEX_AUTH_JSON, a Codex `auth.json` body) is imported into a fresh acpmux home with acpmux's CI-only
`_acpmux/connections/chatgpt.import` (cmux#49268, cmuxterm-hq#15720), and the app then runs on that home, so its
Cloud start finds a Cloud-serving Codex connection the way a person's ChatGPT sign-in makes one.

Ported from cmuxterm-hq tools/fleet-reconcilers/codex_chatgpt_import.py (hq#19593, the start matrix's Codex rows).
Without it every `agent: codex` proof refused before any machine: "No Cloud connection serves codex yet" (runs
45999014551, 46040021553). A Codex CLI login has `serves_cloud: false`; only a browser sign-in (or this import) makes
a `chatgpt-plan` one.

The import is refused unless the daemon's own environment sets ACPMUX_CI_CHATGPT_IMPORT=1, and the app passes no
such variable to the acpmux it starts (AcpmuxEnvironment.childEnvironment keeps a fixed list). So `prepare`:

1. makes a fresh, private acpmux home under /tmp (short, so its socket path fits macOS's 104 bytes; /tmp is sticky,
   which acpmux's state-folder check requires of every writable ancestor);
2. writes the login to a 0600 file in it and starts an acpmux (`daemon run`) on that home with the switch on, its
   socket its own: CMUX_NEXT_ACPMUX_BIN (the tagged build's in-tree acpmux) when set, else the bundle's own;
3. calls the import over the local unix socket (the only connection the daemon takes it on) and requires a
   `chatgpt-plan` connection that serves Cloud;
4. stops that daemon and removes the login file, so the app's own daemon (started by the app, without the switch) takes
   the home over and reads the stored connection.

The app is then launched with ACPMUX_HOME set to the home; the import also writes the connection's route beside the
user's cmux config (`routes/chatgpt.toml`); `clear` removes it when it was not there before, and the home with it.
The daemon's first refresh rotates the refresh token, so the stored secret can go stale for later jobs, as it already
does for the journey's Codex row (hq#15720).

Each stage that fails is typed: codex.import_input, codex.import_daemon, codex.import.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

SWITCH = "ACPMUX_CI_CHATGPT_IMPORT"
METHOD = "_acpmux/connections/chatgpt.import"
SOCKET_WAIT_S = 30
CALL_TIMEOUT_S = 30
STOP_WAIT_S = 20
# Where acpmux writes a connection's route: beside the user's cmux config (acpmux routes.rs `places`).
ROUTE_NAME = "chatgpt.toml"


def bundled_acpmux(bundle: Path) -> Path:
    """The acpmux the app runs: the tagged build's in-tree one (CMUX_NEXT_ACPMUX_BIN), else the bundle's own."""
    override = os.environ.get("CMUX_NEXT_ACPMUX_BIN", "").strip()
    return Path(override) if override else bundle / "Contents" / "Resources" / "bin" / "acpmux"


def route_file(home: Path) -> Path:
    return home / ".config" / "cmux" / "routes" / ROUTE_NAME


def daemon_env(acp_home: Path, sock: Path, user_home: Path) -> dict[str, str]:
    """The import daemon's environment: the user's basics, its own home and socket, and the switch. No inherited
    CMUX_ or ACPMUX_ variable reaches it."""
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "USER", "LOGNAME", "SHELL", "TMPDIR")}
    env.update(HOME=str(user_home), ACPMUX_HOME=str(acp_home), ACPMUX_SOCKET=str(sock), **{SWITCH: "1"})
    return env


def rpc(sock: Path, method: str, params: dict, timeout: float = CALL_TIMEOUT_S, connect=None) -> dict:
    """One JSON-RPC call over the daemon's unix socket (newline-delimited); the answer with the call's id."""
    conn = connect(str(sock)) if connect else socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if not connect:
            conn.settimeout(timeout)
            conn.connect(str(sock))
        stream = conn.makefile("rwb")
        stream.write((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}) + "\n").encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                return {"error": {"message": "the daemon closed the connection without an answer"}}
            try:
                answer = json.loads(line)
            except ValueError:
                continue
            if isinstance(answer, dict) and answer.get("id") == 1:
                return answer
    finally:
        conn.close()


def judge(answer: dict) -> tuple[dict | None, str]:
    """The imported connection, or why the import did not make a Cloud-serving chatgpt-plan one. Never a token."""
    if answer.get("error"):
        err = answer["error"] if isinstance(answer["error"], dict) else {}
        reason = (err.get("data") or {}).get("reason") if isinstance(err.get("data"), dict) else None
        return None, f"{METHOD} refused: {str(err.get('message') or '')[:200]}" + (f" ({reason})" if reason else "")
    conn = (answer.get("result") or {}).get("connection") if isinstance(answer.get("result"), dict) else None
    if not isinstance(conn, dict):
        return None, f"{METHOD} answered no connection"
    if conn.get("kind") != "chatgpt-plan" or conn.get("serves_cloud") is not True:
        return None, (f"{METHOD} made a {conn.get('kind')!r} connection with serves_cloud={conn.get('serves_cloud')!r},"
                      " not a Cloud-serving chatgpt-plan one")
    return {k: conn.get(k) for k in ("id", "kind", "plan", "serves_cloud", "signed_in")}, ""


class Import:
    """One run's import: `prepare` before the app launches, `clear` after it quits."""

    def __init__(self, popen=subprocess.Popen, clock=time.monotonic, sleep=time.sleep, call=rpc, run=subprocess.run,
                 user_home: Path | None = None, tmp_root: str = "/tmp"):
        self.popen, self.clock, self.sleep, self.call, self.run = popen, clock, sleep, call, run
        self.exe: Path | None = None
        self.user_home = user_home or Path.home()
        self.tmp_root = tmp_root
        self.home: Path | None = None
        self.route_existed = True
        self.connection: dict | None = None

    def _fail(self, code: str, said: str) -> dict:
        return {"error_code": code, "error": said}

    def prepare(self, bundle: Path, auth_text: str) -> dict:
        """{"home": path, "connection": {...}} on success; {"error_code", "error"} otherwise."""
        if not auth_text.strip():
            return self._fail("codex.import_input", "no Codex login: the job passes no CODEX_AUTH_JSON")
        exe = bundled_acpmux(bundle)
        if not os.access(exe, os.X_OK):
            return self._fail("codex.import_input", f"no executable acpmux at {exe}")
        self.exe = exe
        self.route_existed = route_file(self.user_home).exists()
        self.home = Path(tempfile.mkdtemp(prefix="ccp-acp-", dir=self.tmp_root))
        os.chmod(self.home, 0o700)
        secret = self.home / "codex-auth.json"
        fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(auth_text)
        sock = self.home / "i.sock"
        proc = None
        try:
            try:
                with (self.home / "import-daemon.log").open("wb") as log:  # the child keeps its own copy of the fd
                    proc = self.popen([str(exe), "daemon", "run"], env=daemon_env(self.home, sock, self.user_home),
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log,
                                      start_new_session=True)
            except OSError as err:
                return self._fail("codex.import_daemon", f"starting acpmux failed: {err}")
            deadline = self.clock() + SOCKET_WAIT_S
            while not sock.exists():
                if proc.poll() is not None:
                    return self._fail("codex.import_daemon", f"acpmux exited {proc.returncode} before its socket: "
                                      + self._daemon_said())
                if self.clock() >= deadline:
                    return self._fail("codex.import_daemon", f"acpmux made no socket within {SOCKET_WAIT_S} s: "
                                      + self._daemon_said())
                self.sleep(0.5)
            try:
                answer = self.call(sock, METHOD, {"secret_file": str(secret)})
            except OSError as err:
                return self._fail("codex.import", f"{METHOD} over the socket failed: {err}")
            conn, why = judge(answer)
            if conn is None:
                return self._fail("codex.import", why)
            self.connection = conn
            return {"home": str(self.home), "connection": conn}
        finally:
            secret.unlink(missing_ok=True)
            if proc is not None:
                self._stop(proc)

    def _daemon_said(self) -> str:
        try:
            text = (self.home / "import-daemon.log").read_text(errors="replace") if self.home else ""
        except OSError:
            return "(no log)"
        lines = [line for line in text.splitlines() if line.strip()]
        return (lines[-1] if lines else "(empty log)")[-300:]

    def _stop(self, proc) -> None:
        """Stops the import daemon's own session (start_new_session made its pid the group's id). A pid of 0 or less
        is never signalled as a group: os.killpg(0) is the caller's own group, which would end the probe itself."""
        if proc.poll() is not None:
            return
        own_group = isinstance(proc.pid, int) and proc.pid > 0
        try:
            if not own_group:
                raise ProcessLookupError
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            proc.terminate()
        try:
            proc.wait(timeout=STOP_WAIT_S)
        except subprocess.TimeoutExpired:
            try:
                if not own_group:
                    raise ProcessLookupError
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.wait(timeout=STOP_WAIT_S)

    def clear(self) -> list[str]:
        """After the app quit: stops whatever daemon still serves the run's home (the app's own outlives it while a
        client or task holds it), then removes the home and, when the run wrote it, the route; what is left."""
        left: list[str] = []
        if self.home is not None and self.exe is not None:
            env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "USER", "LOGNAME")}
            env.update(HOME=str(self.user_home), ACPMUX_HOME=str(self.home))
            try:
                self.run([str(self.exe), "daemon", "shutdown"], env=env, capture_output=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                pass  # none running, or it would not stop: the home's removal below says what is left
        if not self.route_existed:
            try:
                route_file(self.user_home).unlink(missing_ok=True)
            except OSError as err:
                left.append(f"route {ROUTE_NAME}: {err}")
        if self.home is not None:
            shutil.rmtree(self.home, ignore_errors=True)
            if self.home.exists():
                left.append(f"acpmux home {self.home}")
            self.home = None
        return left
