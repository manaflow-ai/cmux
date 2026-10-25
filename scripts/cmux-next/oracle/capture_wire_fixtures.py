#!/usr/bin/env python3
"""Record real `session.snapshot` and `settings.snapshot` replies as schema fixtures.

Starts a hermetic cmux-tui daemon (its own HOME, XDG dirs and socket), makes a little state (a second
workspace, a split, a named tab, a closed tab, a tab group, a notification, an agent report), reads both
methods and writes them to schemas/oracle/fixtures/wire/<method>.json. check_snapshot_schema.py validates
every file there against the daemon facet, so the schema is checked against the wire, not only against
the hand-written example.

The only edits are two host strings: the temporary case root becomes /tmp/oracle-case and the host name
becomes oracle-host, so the files do not name the machine that recorded them.

Usage (on Linux or a fleet Mac, never on the person's Mac; the daemon is a cargo build):
  python3 -I scripts/cmux-next/oracle/capture_wire_fixtures.py --cmux <target>/debug/cmux-tui
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

SELECTORS = {"machine": "current", "session": "current"}
CASE_ROOT = "/tmp/oracle-case"
HOST = "oracle-host"


class Daemon:
    def __init__(self, binary: Path, root: Path):
        self.binary = str(binary)
        self.socket = str(root / "run" / "oracle.sock")
        home = root / "home"
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
            "XDG_RUNTIME_DIR": str(root / "run"),
            "SHELL": "/bin/sh",
            "TERM": "xterm-256color",
        }
        self.cwd = root / "case"
        for path in (home, root / "run", self.cwd):
            path.mkdir(parents=True, exist_ok=True)

    def run(self, *args: str) -> dict | list:
        proc = subprocess.run(
            [self.binary, "--socket", self.socket, "--json", *args],
            env=self.env, cwd=self.cwd, capture_output=True, text=True, timeout=60, check=False,
        )
        if proc.returncode != 0:
            raise SystemExit(f"cmux {' '.join(args)} failed: {proc.stdout.strip()} {proc.stderr.strip()}")
        return json.loads(proc.stdout)

    def read(self, method: str) -> dict:
        return self.run("raw", "operation", method, "--params-json", json.dumps(SELECTORS))

    def start(self) -> None:
        subprocess.run(
            [self.binary, "daemon", "ensure", "--socket", self.socket],
            env=self.env, cwd=self.cwd, capture_output=True, text=True, timeout=60, check=True,
        )

    def stop(self) -> None:
        subprocess.run(
            [self.binary, "daemon", "stop", "--socket", self.socket, "--end-terminals"],
            env=self.env, cwd=self.cwd, capture_output=True, text=True, timeout=60, check=False,
        )


def make_state(daemon: Daemon) -> None:
    created = daemon.run("workspace", "create", "--name", "second", "--focus")["value"]
    daemon.run("pane", created["pane_id"], "split", "--right")
    named = daemon.run("tab", "create", "terminal", "--name", "named-tab")["value"]
    extra = daemon.run("tab", "create", "terminal")["value"]
    daemon.run("tab", "group", "create", "--tabs", f"{created['tab_id']},{named['tab_id']}", "--name", "pair")
    daemon.run("tab", extra["tab_id"], "close")
    daemon.run("notification", "create", "--title", "build done", "--body", "all green")
    daemon.run("agent", "report", "--terminal", named["terminal_id"], "--state", "working", "--source", "socket")


def scrub(value, root: str):
    if isinstance(value, str):
        return value.replace(root, CASE_ROOT).replace(socket.getfqdn(), HOST).replace(socket.gethostname(), HOST)
    if isinstance(value, list):
        return [scrub(item, root) for item in value]
    if isinstance(value, dict):
        return {key: scrub(item, root) for key, item in value.items()}
    return value


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cmux", type=Path, required=True, help="a cmux-tui binary")
    default_out = Path(__file__).resolve().parents[3] / "schemas" / "oracle" / "fixtures" / "wire"
    parser.add_argument("--out", type=Path, default=default_out)
    args = parser.parse_args(argv)
    root = Path(tempfile.mkdtemp(prefix="oracle-wire-"))
    daemon = Daemon(args.cmux.resolve(), root)
    try:
        daemon.start()
        make_state(daemon)
        replies = {method: daemon.read(method) for method in ("session.snapshot", "settings.snapshot")}
    finally:
        daemon.stop()
        shutil.rmtree(root, ignore_errors=True)
    args.out.mkdir(parents=True, exist_ok=True)
    for method, result in replies.items():
        record = {
            "method": method,
            "params": SELECTORS,
            "recordedBy": "scripts/cmux-next/oracle/capture_wire_fixtures.py",
            "result": scrub(result, str(root / "case")),
        }
        (args.out / f"{method}.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        print(args.out / f"{method}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
