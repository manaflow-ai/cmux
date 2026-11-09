#!/usr/bin/env python3
"""`web-overlay.sh status` (`cmux live status`) starts by saying what the app loads its web UI from, and why.

Lucas asked whether cmux Live and Live Web Reload were two features, and why his React pages went
blank: status printed raw JSON and never said which of the app's checks sent it back to the shipped
web UI. Each case below is one of those checks, in the order the app makes them (WebDevOverride.swift).
"""

import hashlib
import hmac
import http.server
import json
import os
import stat
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/web-overlay.sh"
TOKEN = "a" * 48


def serve(token: str | None):
    """A loopback server for /agent-pane/index.html that proves `token` (None: sends no proof)."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            nonce = self.headers.get("X-Cmux-Dev-Nonce")
            if token and nonce:
                proof = hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest()
                self.send_header("X-Cmux-Dev-Proof", proof)
            self.end_headers()
            self.wfile.write(b"<!doctype html>")

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class WebOverlayStatusExplainsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="web-overlay-status-"))
        self.config = self.tmp / "config"
        self.state = self.tmp / "state"
        self.bin = self.tmp / "bin"
        for folder in (self.config, self.state, self.bin):
            folder.mkdir()
        self.setting("true")

    def setting(self, value: str):
        fake = self.bin / "cmux"
        fake.write_text(f"#!/bin/sh\necho {value}\n")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)

    def web_dev(self, value: dict):
        (self.config / "web-dev.json").write_text(json.dumps(value))

    def status(self) -> str:
        env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.tmp / "home"),
            "CMUX_NEXT_CONFIG_FILE": str(self.config / "cmux-next.json"),
            "CMUX_WEB_OVERLAY_DIR": str(self.tmp / "overlay"),
            "CMUX_WEB_SLOT_STATE_DIR": str(self.state),
            "CMUX_WEB_OVERLAY_APP": str(self.tmp / "no-app"),
        }
        result = subprocess.run(["bash", str(SCRIPT), "status"], env=env, capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split("\n\n", 1)[0]

    def test_setting_off(self):
        self.setting("false")
        self.web_dev({"server": "http://127.0.0.1:9/", "token": TOKEN})
        out = self.status()
        self.assertIn("cmux Live (Settings > General, updates.liveWebReload): off", out)
        self.assertIn("from the web UI it shipped with", out)
        self.assertIn("cmux Live is off", out)

    def test_no_web_dev_json(self):
        out = self.status()
        self.assertIn("from the web UI it shipped with", out)
        self.assertIn("there is no", out)

    def test_server_does_not_answer_and_stopped_on_its_own(self):
        server = serve(TOKEN)
        port = server.server_address[1]
        server.shutdown()
        server.server_close()
        self.web_dev({"server": f"http://127.0.0.1:{port}/", "token": TOKEN})
        (self.state / "dev-server.exit").write_text("2026-11-09T10:00:00Z bun exited with status 1\n")
        out = self.status()
        self.assertIn("does not answer", out)
        self.assertIn("stopped on its own at 2026-11-09T10:00:00Z: bun exited with status 1", out)
        self.assertIn("from the web UI it shipped with", out)

    def test_server_with_another_token_falls_back_to_the_overlay(self):
        server = serve("b" * 48)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        overlay = self.tmp / "my-overlay"
        overlay.mkdir()
        (overlay / "manifest.json").write_text(json.dumps({"commit": "abc123"}))
        self.web_dev({"server": f"http://127.0.0.1:{server.server_address[1]}/", "token": TOKEN,
                      "overlay": str(overlay)})
        out = self.status()
        self.assertIn("not with the token in web-dev.json", out)
        self.assertIn(f"from the overlay at {overlay} (commit abc123)", out)

    def test_server_without_proof(self):
        server = serve(None)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.web_dev({"server": f"http://127.0.0.1:{server.server_address[1]}/", "token": TOKEN})
        self.assertIn("(it sent no proof)", self.status())

    def test_server_that_proves_its_token(self):
        server = serve(TOKEN)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_address[1]}/"
        self.web_dev({"server": url, "token": TOKEN})
        out = self.status()
        self.assertIn(f"cmux loads its web UI from the dev server at {url}", out)
        self.assertIn("answers with its token", out)


if __name__ == "__main__":
    unittest.main()
