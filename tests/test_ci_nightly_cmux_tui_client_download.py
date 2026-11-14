#!/usr/bin/env python3
"""The nightly's cmux-tui client download: only the arch it ships, and a trickle fails fast.

Nightly run 42675465011 (build-nightly-app, "Bundle the cmux-tui client") failed with
  curl: (28) Operation timed out after 600004 milliseconds with 3850150 out of 202015248 bytes received
  error: download budget exceeded for https://files.cmux.com/cmux-tui/0e43718c.../cmux-tui-x86_64-apple-darwin
files.cmux.com served the x86_64 slice at about 6 KB/s, above the 1 KiB/s stall floor, so one attempt
trickled for the whole 600 s budget. That nightly-next build is arm64 only (NIGHTLY_COMPILE_ARCHS=arm64;
thin-app-bundle.sh drops the x86_64 slice before signing), so it never needed that slice.

1. Every nightly step that installs the client (the prefetch beside the compile, the pending-tree
   prefetch and the bundle step) passes --arch arm64 when NIGHTLY_COMPILE_ARCHS is arm64, and
   --arch universal when it holds both.
2. The real installer and the real curl give up on a ~5 KB/s trickle at the stall bound and retry
   on a new connection, instead of spending the whole download budget on one attempt.

Run: python3 tests/test_ci_nightly_cmux_tui_client_download.py (about 15 s, no build; part 2 needs
openssl and curl).
"""

from __future__ import annotations

import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEPS = ROOT / "scripts/ci/nightly-steps"
COMMIT = "0e43718c567fb5036b15f8c5b31bb8089509e4b6"

RECORDER = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$RECORD"
"""


class NightlyStepsPickTheShippedArch(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="nightly-tui-arch."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.record = self.tmp / "install-args"
        repo = self.tmp / "repo"
        (repo / "scripts/ci/nightly-steps").mkdir(parents=True)
        (repo / "scripts/cmux-next").mkdir(parents=True)
        for name in ("app-bundle-cmux-tui-client.sh", "app-fetch-tree-companions.sh",
                     "app-prefetch-pending-cmux-tui.sh"):
            shutil.copy(STEPS / name, repo / "scripts/ci/nightly-steps" / name)
        stubs = {
            "scripts/install-cmux-tui-client.sh": RECORDER,
            "scripts/strip-release-bundle.sh": "#!/bin/sh\n",
            "scripts/cmux-next/write-cmux-tui-version.sh": "#!/bin/sh\n",
            "scripts/cmux-next/check-daemon-capabilities.sh": "#!/bin/sh\n",
            "scripts/cmux-next/await-tree-client.sh": f"#!/bin/sh\necho {COMMIT}\n",
            "scripts/cmux-next/pin-cmux-tui.sh":
                '#!/bin/sh\n[ "$1" = acpmux-path ] && echo "$ACPMUX_STUB"\nexit 0\n',
            # `start ... -- COMMAND` runs COMMAND in the foreground here.
            "scripts/ci/background_build.py":
                "import subprocess, sys\n"
                "if sys.argv[1] == 'start':\n"
                "    sys.exit(subprocess.call(sys.argv[sys.argv.index('--') + 1:]))\n",
        }
        for rel, body in stubs.items():
            path = repo / rel
            path.write_text(body)
            path.chmod(0o755)
        acpmux = self.tmp / "acpmux"
        acpmux.write_text("#!/bin/sh\n")
        acpmux.chmod(0o755)
        self.repo = repo
        self.runner_temp = self.tmp / "runner"
        self.runner_temp.mkdir()
        self.env_base = {
            "PATH": os.environ["PATH"], "HOME": str(self.tmp), "RECORD": str(self.record),
            "RUNNER_TEMP": str(self.runner_temp), "GITHUB_ENV": str(self.tmp / "github-env"),
            "GITHUB_OUTPUT": str(self.tmp / "github-output"), "ACPMUX_STUB": str(acpmux),
            "CMUX_TUI_CLIENT_COMMIT": COMMIT, "CMUX_TUI_CLIENT_KEY": "k" * 40,
            "CMUX_TUI_CLIENT_CACHE": str(self.tmp / "cache"), "TREE_PENDING": "false",
            "TREE_CANDIDATES": COMMIT,
        }

    def run_step(self, archs: str, *argv: str) -> list[str]:
        self.record.unlink(missing_ok=True)
        env = dict(self.env_base, NIGHTLY_COMPILE_ARCHS=archs)
        result = subprocess.run(["bash", *argv], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.record.exists(), f"{argv} did not run install-cmux-tui-client.sh")
        return self.record.read_text().splitlines()

    def assert_arch(self, archs: str, want: str, *argv: str) -> None:
        for line in self.run_step(archs, *argv):
            words = line.split()
            self.assertIn("--arch", words, f"{argv[0]} installs without --arch: {line}")
            self.assertEqual(words[words.index("--arch") + 1], want, f"{argv[0]} with {archs!r}: {line}")

    def test_every_install_step_takes_the_compiled_arch(self) -> None:
        steps = [
            ("scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh",),
            ("scripts/ci/nightly-steps/app-fetch-tree-companions.sh",),
            ("scripts/ci/nightly-steps/app-prefetch-pending-cmux-tui.sh", "run"),
        ]
        for argv in steps:
            with self.subTest(step=argv[0]):
                self.assert_arch("arm64", "arm64", *argv)
                self.assert_arch("arm64 x86_64", "universal", *argv)


TRICKLE_SERVER = r"""
import os, socket, ssl, sys, threading, time
root = sys.argv[1]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(f"{root}/cert.pem", f"{root}/key.pem")
listener = socket.create_server(("127.0.0.1", 0))
with open(f"{root}/port.tmp", "w") as handle:
    handle.write(str(listener.getsockname()[1]))
os.rename(f"{root}/port.tmp", f"{root}/port")
def trickle(connection):
    # About 5 KB/s, the rate files.cmux.com served in run 42675465011: above a 1 KiB/s floor.
    try:
        with context.wrap_socket(connection, server_side=True) as tls:
            tls.recv(65536)
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 202015248\r\n\r\n")
            while True:
                tls.sendall(b"x" * 512)
                time.sleep(0.1)
    except OSError:
        pass
while True:
    connection, _ = listener.accept()
    with open(f"{root}/connections", "a") as handle:
        handle.write("accepted\n")
    threading.Thread(target=trickle, args=(connection,), daemon=True).start()
"""


@unittest.skipUnless(shutil.which("openssl") and shutil.which("curl"), "needs openssl and curl")
class TrickleFailsAtTheStallBound(unittest.TestCase):
    def test_a_trickle_is_retried_not_waited_out(self) -> None:
        tmp = Path(tempfile.mkdtemp(prefix="nightly-tui-trickle."))
        self.addCleanup(shutil.rmtree, tmp, True)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", tmp / "key.pem", "-out", tmp / "cert.pem"],
                       check=True, capture_output=True)
        # The certificate is self-signed; this test is about throughput, not trust.
        (tmp / ".curlrc").write_text("insecure\n")
        server = subprocess.Popen([sys.executable, "-c", TRICKLE_SERVER, str(tmp)])
        self.addCleanup(server.kill)
        deadline = time.monotonic() + 10
        while not (tmp / "port").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        port = (tmp / "port").read_text()
        app = tmp / "Trickle.app"
        (app / "Contents").mkdir(parents=True)
        env = dict(os.environ, CURL_HOME=str(tmp), CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS="2",
                   CMUX_TUI_CLIENT_DOWNLOAD_STALL_SECONDS="2", CMUX_TUI_CLIENT_DOWNLOAD_MAX_SECONDS="40")
        result = subprocess.run(
            ["bash", ROOT / "scripts/install-cmux-tui-client.sh", app, "--allow-unattested",
             "--cache-dir", tmp / "cache", "--manifest-url", f"https://127.0.0.1:{port}/manifest.json"],
            env=env, capture_output=True, text=True, timeout=90)
        log = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, log)
        # The stall detector, not the overall budget, ended each attempt: a trickle that ran to the
        # budget would say so in the log. That is the causal check; the wall time it took is not asserted.
        self.assertNotIn("download budget exceeded", log, f"one trickling attempt spent the budget:\n{log}")
        self.assertIn(f"could not download https://127.0.0.1:{port}/manifest.json after 2 attempts", log, log)
        self.assertEqual(len((tmp / "connections").read_text().splitlines()), 2,
                         "each attempt dials its own connection")


if __name__ == "__main__":
    unittest.main()
