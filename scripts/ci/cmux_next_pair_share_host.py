"""The tagged Mac's read-only evidence for an iPhone-initiated screen share."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def share_without_asking_off(reply):
    """Whether the Mac's `settings.get macScreen.shareWithoutAsking` reply says off.

    An explicit `false` is off. So is a key the settings file does not set (`exists: false`, `value: null`),
    since the setting's default is off. Anything else (`true`, an error, a reply with no `exists`) is not.
    """
    if not isinstance(reply, dict) or "error" in reply:
        return False
    if reply.get("value") is False:
        return True
    return reply.get("exists") is False and reply.get("value") is None


_URL = re.compile(r"\b\w+://\S+")
_TOKEN = re.compile(r"\b[A-Za-z0-9_\-]{32,}\b")


def share_log_line(line):
    """One daemon log line, its URLs and token-like runs cut, at most 240 characters."""
    line = _TOKEN.sub("<cut>", _URL.sub("<url>", line.strip()))
    return line if len(line) <= 240 else line[:239] + "…"


class TaggedShareHost:
    def __init__(self, mac_app, env):
        self.cli = Path(mac_app) / "Contents/Resources/bin/acpmux"
        self.env = env
        self.home = Path(env["ACPMUX_HOME"])
        self.credential = self.home / "machine-credential.json"
        self.audit = self.home / "share-host/audit.jsonl"
        self.log = self.home / "daemon.log"
        self.log_cursor = 0
        self.target = None

    def _command(self, *args, timeout):
        try:
            result = subprocess.run([self.cli, "--json", *args], env=self.env, timeout=timeout,
                                    capture_output=True, text=True, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"acpmux {' '.join(args)}: {type(error).__name__}") from error
        # Some daemon commands include authenticated URLs in their output.
        if result.returncode:
            raise RuntimeError(f"acpmux {' '.join(args)} exited {result.returncode}")
        return result.stdout

    def _status(self):
        try:
            status = json.loads(self._command("share-host", "status", timeout=8))
        except ValueError as error:
            raise RuntimeError("acpmux share-host status returned invalid JSON") from error
        if not isinstance(status, dict) or status.get("schema") != "acpmux.share-host.status/1":
            raise RuntimeError("acpmux share-host status has no share-host status record")
        return status

    def summary(self):
        """The share host's state as booleans and a count, for a failed share check's note."""
        try:
            status = self._status()
        except RuntimeError as error:
            return f"share host: {error}"
        sessions = status.get("sessions")
        count = len(sessions) if isinstance(sessions, (list, dict)) else sessions if isinstance(sessions, int) else "?"
        # state and linkUp say whether its User DO socket is up (the phone's row reads Offline without one).
        state = status.get("state") if isinstance(status.get("state"), str) and status.get("state").isidentifier() else "?"
        return (f"share host: state {state}, link up {status.get('linkUp')}, sharing {status.get('sharing')}, "
                f"app attached {status.get('appAttached')}, sessions {count}")

    def share_log(self, limit=12):
        """The daemon log's share-host and stop lines since the detached baseline (the share host and its
        session processes write there), URLs and tokens cut, for a failed share check's note."""
        try:
            with self.log.open("rb") as log:
                log.seek(self.log_cursor)
                text = log.read(4 << 20).decode("utf-8", "replace")
        except OSError as error:
            return f"share-host log: {type(error).__name__}"
        # And the daemon's own stop line ("stopping: <why>", daemon.rs): a host that stopped says which rule did it.
        lines = [share_log_line(line) for line in text.splitlines() if "share-host" in line or "stopping:" in line]
        if not lines:
            return "share-host log: no share-host lines"
        return "share-host log: " + " | ".join(lines[-limit:])

    def prepare(self):
        """Before quitting the app, wait for its normal signed-in machine enrollment."""
        deadline = time.monotonic() + 90
        while not self.credential.is_file():
            if time.monotonic() >= deadline:
                raise RuntimeError("the tagged Mac did not enroll on sign-in within 90s")
            time.sleep(1)
        # A daemon launched before this new home enrolled tries its share host once at startup.
        if self._status().get("state") == "not_joined":
            self._command("daemon", "restart", timeout=60)
        deadline = time.monotonic() + 60
        while True:
            status = self._status()
            if status.get("running") is True and status.get("linkUp") is True:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f"the tagged share host did not come online (state={status.get('state')})")
            time.sleep(1)
        if status.get("hub") != "https://cmux-device-hub-dev.debussy.workers.dev":
            raise RuntimeError("the tagged share host is not on the staging device hub")
        if not all(status.get(field) for field in ("deviceId", "deviceName", "userId")):
            raise RuntimeError("the tagged share host has no enrolled device or owner")
        self.target = status
        return status

    def detached_baseline(self):
        """After the tagged GUI has exited, pin the previously unshared target and audit offset."""
        deadline = time.monotonic() + 15
        while True:
            status = self._status()
            if status.get("appAttached") is False:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("the tagged share host did not report its app detached")
            time.sleep(0.5)
        if (status.get("linkUp") is not True or status.get("sharing") is not False
                or status.get("sessions") != []
                or any(status.get(field) != self.target[field] for field in ("deviceId", "userId", "hub"))):
            raise RuntimeError("the tagged Mac must be online with the same owner, sharing off and no sessions")
        try:
            self.log_cursor = self.log.stat().st_size
        except OSError:
            self.log_cursor = 0
        try:
            return self.audit.stat().st_size
        except FileNotFoundError:
            return 0

    def admission(self, cursor, nonce_digest, timeout=35):
        """Read only decisions written after the baseline, for the enrolled Mac and this iPhone."""
        deadline = time.monotonic() + timeout
        while True:
            if self.audit.is_file():
                with self.audit.open("rb") as audit:
                    audit.seek(cursor)
                    while True:
                        line = audit.readline()
                        if not line.endswith(b"\n"):
                            break
                        cursor = audit.tell()
                        try:
                            row = json.loads(line)
                        except ValueError as error:
                            raise RuntimeError("the share-host audit contains an invalid decision") from error
                        if not isinstance(row, dict):
                            raise RuntimeError("the share-host audit contains an invalid decision")
                        nonce = row.get("nonce")
                        if (not isinstance(nonce, str) or not nonce
                                or hashlib.sha256(nonce.encode()).hexdigest() != nonce_digest
                                or row.get("device") != self.target["deviceId"]
                                or row.get("carrier") != "device-hub" or row.get("via") != "same-account"):
                            continue
                        if row.get("event") == "remote_host.share_refused":
                            raise RuntimeError(f"the Mac refused the iPhone's approval ({row.get('code')})")
                        if (row.get("event") == "remote_host.share_admitted"
                                and row.get("confirmed_by") == self.target["userId"]
                                and row.get("asker") and row.get("confirmed_on") == row["asker"]):
                            if self._status().get("appAttached") is not False:
                                raise RuntimeError("the Mac app was attached when admission was checked")
                            return row
            if time.monotonic() >= deadline:
                raise RuntimeError("no fresh admission for this iPhone and Mac in the share-host audit")
            time.sleep(0.5)

    def leave(self):
        """After the app quits, revoke only this rig's machine enrollment."""
        if self.credential.is_file():
            self._command("machine", "leave", timeout=60)
