#!/usr/bin/env python3
"""Regression coverage for tagged mobile dev auto-pair route selection."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]


class MobileAttachPrefersIrohTests(unittest.TestCase):
    def test_debug_loopback_override_is_simulator_only(self) -> None:
        helper = ROOT / "scripts" / "lib" / "mobile-attach.sh"
        simulator = subprocess.run(
            [
                "bash",
                "-c",
                f"source {subprocess.list2cmdline([str(helper)])}; "
                "cmux_attach_validate_route_kind_for_target simulator debug_loopback",
            ],
            capture_output=True,
            text=True,
        )
        device = subprocess.run(
            [
                "bash",
                "-c",
                f"source {subprocess.list2cmdline([str(helper)])}; "
                "cmux_attach_validate_route_kind_for_target device debug_loopback",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(simulator.returncode, 0, simulator.stderr)
        self.assertNotEqual(device.returncode, 0)
        self.assertIn("simulator-only", device.stderr)

    def test_mint_waits_for_iroh_instead_of_accepting_ready_loopback(self) -> None:
        tag = f"iroh-route-test-{os.getpid()}"
        socket_path = Path(f"/tmp/cmux-debug-{tag}.sock")
        requests: list[dict[str, object]]

        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_root = Path(temporary_directory)
            scripts = fake_root / "scripts"
            scripts.mkdir()
            (scripts / "lib").mkdir()
            (scripts / "lib" / "attach-url.mjs").symlink_to(
                ROOT / "scripts" / "lib" / "attach-url.mjs"
            )
            requests_path = fake_root / "requests.jsonl"
            counter_path = fake_root / "call-count"
            fake_cli = scripts / "cmux-debug-cli.sh"
            fake_cli.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
request="${3:?missing request payload}"
printf '%s\\n' "$request" >> "$CMUX_TEST_REQUESTS"
count=0
if [[ -f "$CMUX_TEST_COUNTER" ]]; then
  read -r count < "$CMUX_TEST_COUNTER"
fi
count=$((count + 1))
printf '%s\\n' "$count" > "$CMUX_TEST_COUNTER"

if [[ "$request" == *'\"route_kind\":\"iroh\"'* ]]; then
  # Model the real startup race: Iroh is unavailable on the first probe and
  # becomes ready on the second. An unavailable RPC emits no usable payload.
  if [[ "$count" -eq 1 ]]; then
    exit 1
  fi
  printf '%s\\n' '{"ticket":{"version":1,"workspaceID":"","routes":[{"id":"iroh","kind":"iroh","endpoint":{"type":"peer","identity":"0123456789abcdef","hints":[]}}],"authToken":"test-token"}}'
  exit 0
fi

# This is what caused the physical-phone failure: an unfiltered request can
# succeed immediately with the already-bound loopback route.
printf '%s\\n' '{"ticket":{"version":1,"workspaceID":"","routes":[{"id":"debug_loopback","kind":"debug_loopback","endpoint":{"type":"host_port","host":"127.0.0.1","port":58465}}],"authToken":"test-token"}}'
""",
                encoding="utf-8",
            )
            fake_cli.chmod(0o755)

            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                socket_path.unlink(missing_ok=True)
                listener.bind(str(socket_path))
                listener.listen(1)
                script = f"""
source {subprocess.list2cmdline([str(ROOT / 'scripts' / 'lib' / 'mobile-attach.sh')])}
sleep() {{ :; }}
cmux_attach_mint_url {tag} 600 {subprocess.list2cmdline([str(fake_root)])} 3
"""
                result = subprocess.run(
                    ["bash", "-c", script],
                    check=True,
                    capture_output=True,
                    text=True,
                    env={
                        **os.environ,
                        "CMUX_TEST_REQUESTS": str(requests_path),
                        "CMUX_TEST_COUNTER": str(counter_path),
                    },
                )
            finally:
                listener.close()
                socket_path.unlink(missing_ok=True)

            requests = [
                json.loads(line)
                for line in requests_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertGreaterEqual(len(requests), 2)
            self.assertTrue(all(request["scope"] == "mac" for request in requests))
            self.assertTrue(all(request["route_kind"] == "iroh" for request in requests))

            parsed = urlparse(result.stdout)
            encoded_payload = parse_qs(parsed.query)["payload"][0]
            padding = "=" * (-len(encoded_payload) % 4)
            ticket = json.loads(base64.urlsafe_b64decode(encoded_payload + padding))
            self.assertEqual([route["kind"] for route in ticket["routes"]], ["iroh"])


if __name__ == "__main__":
    unittest.main()
