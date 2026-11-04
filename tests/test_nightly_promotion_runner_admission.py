#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import io
import json
import unittest
from unittest import mock
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("admission", ROOT / "scripts/ci/nightly_promotion_admission.py")
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
import fleet_admission_transport as transport


def fixture(status="pending"):
    env = dict(GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_RUN_ID="42", GITHUB_RUN_ATTEMPT="1", GITHUB_SHA="a" * 40)
    request = n.identity(env)
    lease = dict(request, lease_id=n.lease_id(request), created_at="2026-11-01T00:00:00Z", expires_at="2026-11-01T00:03:00Z", status=status, runners={})
    if status == "fleet":
        lease.update(decided_at="2026-11-01T00:00:30Z", runners={n.JOB: "cmux-promotion-" + lease["lease_id"] + "-" + n.JOB})
    if status == "overflow":
        lease.update(decided_at="2026-11-01T00:03:00Z", no_start_seconds=180)
    return request, lease


class PromotionAdmissionTests(unittest.TestCase):
    def test_fleet_receipt_selects_only_reserved_label(self):
        request, lease = fixture("fleet")
        self.assertEqual(n.select(request, lease, "overflow"), lease["runners"][n.JOB])
        for key, value in (("runners", {n.JOB: "blacksmith-2vcpu-ubuntu-2404"}), ("run_attempt", 2), ("lease_id", "b" * 24), ("decided_at", lease["expires_at"])):
            with self.subTest(key=key), self.assertRaises(ValueError):
                n.select(request, dict(lease, **{key: value}), "overflow")

    def test_overflow_requires_recorded_full_no_start_window(self):
        request, lease = fixture("overflow")
        self.assertEqual(n.select(request, lease, "overflow"), "overflow")
        for key, value in (("no_start_seconds", 179), ("no_start_seconds", "180"), ("decided_at", "2026-11-01T00:02:59Z"), ("runners", {n.JOB: "owned"}), ("expires_at", "2026-11-01T00:02:59Z")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                n.select(request, dict(lease, **{key: value}), "overflow")

    def test_future_receipt_cannot_bypass_no_start_wait(self):
        request, lease = fixture("overflow")
        with self.assertRaises(ValueError):
            n.select(request, lease, "overflow", now=n.timestamp(lease["created_at"]) + 179)
        with self.assertRaises(ValueError):
            n.select(request, dict(lease, no_start_seconds=999), "overflow")

    def test_controller_failure_never_falls_back(self):
        request, _ = fixture()
        def unavailable(*args): raise OSError("offline")
        with self.assertRaises(OSError): n.place(request, unavailable, "overflow")

    def test_wait_preserves_identity_and_durable_clock(self):
        request, pending = fixture()
        _, done = fixture("overflow")
        calls = []
        def call(method, path, body):
            calls.append((method, path, body))
            return pending if method == "POST" else done
        runner, lease = n.place(request, call, "overflow")
        self.assertEqual(runner, "overflow")
        self.assertEqual([x[0] for x in calls], ["POST", "GET"])
        self.assertIn("wait=30", calls[-1][1])
        def reset(method, path, body):
            return pending if method == "POST" else dict(done, created_at="2026-11-01T00:00:01Z")
        with self.assertRaises(ValueError): n.place(request, reset, "overflow")

    def test_terminal_tenth_poll_is_consumed(self):
        request, pending = fixture()
        _, done = fixture("overflow")
        polls = 0
        def call(method, path, body):
            nonlocal polls
            if method == "POST":
                return pending
            polls += 1
            return pending if polls < 10 else done
        runner, lease = n.place(request, call, "overflow")
        self.assertEqual(runner, "overflow")
        self.assertEqual(lease, done)
        self.assertEqual(polls, 10)

    def test_main_workflow_has_no_promotion_blacksmith_first_escape(self):
        text = (ROOT / ".github/workflows/nightly.yml").read_text()
        picker = text.split("  pick-nightly-promotion-runner:\n", 1)[1].split("\n  promote-nightly-next:", 1)[0]
        promote = text.split("\n  promote-nightly-next:\n", 1)[1].split("\n  await-release-surface-ack:", 1)[0]
        runner = next(line.strip() for line in promote.splitlines() if line.strip().startswith("runs-on:"))
        self.assertEqual(runner, "runs-on: ${{ needs.pick-nightly-promotion-runner.outputs.runner }}")
        picker_runner = next(line for line in picker.splitlines() if line.strip().startswith("runs-on:"))
        self.assertNotIn("blacksmith", picker_runner)
        self.assertNotIn("LINUX_RUNNER", picker_runner)
        self.assertIn("environment: nightly-next-promote", promote)
        self.assertLess(promote.index("run: bash scripts/ci/signing-runner-claim.sh"), promote.index("secrets.CMUX_RELEASE_APP_KEY"))
        self.assertLess(promote.index("run: bash scripts/ci/signing-runner-claim.sh"), promote.index("secrets.GLAEDA_ROUTE_APP_KEY"))
        self.assertNotIn("secrets.", picker)
        self.assertIn("vars.CMUX_FLEET_CONTROLLER", picker)


class Transport(unittest.TestCase):
    def test_http_requires_an_online_peer_of_the_running_tailnet(self):
        peer = {"BackendState": "Running", "Peer": {
            "controller": {"Online": True, "TailscaleIPs": ["100.64.0.8"]}}}
        with mock.patch.object(transport.shutil, "which", return_value="/bin/tailscale"), \
             mock.patch.object(transport.subprocess, "run") as run:
            run.return_value.stdout = json.dumps(peer)
            transport.verify_authority("http://100.64.0.8:18765/v1/admission")
            for bad in ({**peer, "BackendState": "Stopped"},
                        {**peer, "Peer": {}},
                        {**peer, "Peer": {"controller": {"Online": False, "TailscaleIPs": ["100.64.0.8"]}}}):
                run.return_value.stdout = json.dumps(bad)
                with self.subTest(status=bad), self.assertRaises(ValueError):
                    transport.verify_authority("http://100.64.0.8:18765/v1/admission")
            self.assertEqual(run.call_args.kwargs["timeout"], 5)

    def test_no_plain_dns_public_http_credentials_or_other_protocol(self):
        for url in ("http://controller/v1", "http://127.0.0.1/v1", "http://203.0.113.1/v1",
                    "https://user:password@controller/v1", "file:///tmp/receipt", "https://controller/v1#other"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                transport.verify_authority(url)

    def test_https_uses_certificate_transport_without_tailnet_probe(self):
        with mock.patch.object(transport.subprocess, "run") as run:
            transport.verify_authority("https://controller.example/v1/admission")
            run.assert_not_called()

    def test_redirect_is_never_followed(self):
        with self.assertRaises(ValueError):
            transport.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://other.example/")

    def test_exchange_disables_environment_proxies(self):
        with mock.patch.object(transport.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = io.BytesIO(b'{"status": "pending"}')
            self.assertEqual(transport.exchange("https://controller.example/v1"), {"status": "pending"})
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertIsInstance(build.call_args.args[1], transport.NoRedirect)

    def test_exchange_rejects_an_oversized_response(self):
        with mock.patch.object(transport.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = io.BytesIO(b"{}" * (transport.MAX_RESPONSE_BYTES // 2 + 1))
            with self.assertRaises(ValueError):
                transport.exchange("https://controller.example/v1")


if __name__ == "__main__":
    unittest.main()
