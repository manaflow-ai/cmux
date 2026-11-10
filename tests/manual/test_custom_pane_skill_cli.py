#!/usr/bin/env python3
"""Execute the pane skill's shell examples against a real CLI and a fake daemon.

No app, user socket, installation, or build is used. Pass the bin directory of
an existing tagged build, or of a build produced on rbx.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "Native/OptChat/optchat-chief/skills/cmux-custom-pane/SKILL.md"
BIN_DIR: Path


class SkillCommands(unittest.TestCase):
    def run_example(self, index: int, expected: dict, data: dict) -> tuple[str, list[dict]]:
        blocks = re.findall(r"```sh\n(.*?)```", SKILL.read_text(), re.S)
        with tempfile.TemporaryDirectory(prefix="pane-cli-", dir="/tmp") as directory:
            root = Path(directory)
            local = root / "local"
            local.mkdir()
            data = {**data, "local_dir": str(local)}
            wrappers = root / "bin"
            wrappers.mkdir()
            for name in ("cmux", "cmux-tui"):
                wrapper = wrappers / name
                wrapper.write_text(
                    "#!/bin/sh\nexec " + shlex.quote(str(BIN_DIR / name))
                    + ' --socket "$CMUX_TEST_SOCKET" "$@"\n'
                )
                wrapper.chmod(0o700)
            requests, errors = [], []
            stop = threading.Event()
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(root / "daemon.sock"))
            server.listen()
            server.settimeout(0.1)

            def serve():
                while not stop.is_set():
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(3)
                        try:
                            request = json.loads(connection.makefile("rb").readline())
                            # The CLI probes socket kind/build skew before parsing.
                            # Those probes carry no app command and grant no authority.
                            if request.get("cmd") == "identify" or "method" in request:
                                probe = {"id": request.get("id"), "ok": True, "data": {}}
                                connection.sendall((json.dumps(probe) + "\n").encode())
                                continue
                            requests.append(request)
                            for key, value in expected.items():
                                self.assertEqual(request.get(key), value)
                            reply = {"id": request.get("id"), "ok": True, "data": data}
                            connection.sendall((json.dumps(reply) + "\n").encode())
                        except Exception as error:
                            errors.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            env = {**os.environ, "PATH": str(wrappers) + os.pathsep + os.environ["PATH"],
                   "CMUX_TEST_SOCKET": str(root / "daemon.sock")}
            try:
                result = subprocess.run(["/bin/sh", "-c", blocks[index]], env=env,
                                        capture_output=True, text=True, timeout=10)
            finally:
                stop.set()
                worker.join(timeout=4)
                server.close()
            self.assertFalse(worker.is_alive(), "fixture did not stop")
            self.assertEqual(errors, [])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(requests), 1, result.stdout)
            if index == 0:
                self.assertTrue((local / "standup-board/web").is_dir())
            return result.stdout, requests

    def test_folder_example_discovers_the_daemon_local_directory(self):
        self.run_example(0, {"cmd": "apps-list"}, {})

    def test_log_example_reads_the_named_app(self):
        stdout, _ = self.run_example(1, {"cmd": "apps-logs", "app": "local/standup-board"},
                                     {"lines": [{"message": "synthetic pane log"}]})
        self.assertEqual(json.loads(stdout)["lines"], [{"message": "synthetic pane log"}])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BIN_DIR = args.bin_dir.absolute()
    for name in ("cmux", "cmux-tui"):
        if not (BIN_DIR / name).is_file():
            parser.error(f"missing existing CLI: {BIN_DIR / name}")
    unittest.main(argv=[__file__, *remaining])
