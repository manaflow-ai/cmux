"""Fail-closed proof transitions; these tests do not claim a live simulator run."""
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import Mock, patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "screen_proof", Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_screen_sharing_proof.py")
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


class Rig:
    def __init__(self):
        self.now, self.phase, self.calls, self.shots = 0, "idle", [], []
        self.fps, self.wrong_viewer, self.sticky, self.stale = "Direct · 30 fps · 20 KB/s", False, False, False
        self.keys = []
        self.visible_probe = True

    def clock(self): return self.now
    def sleep(self, seconds): self.now += seconds
    def open_host(self, name):
        self.calls.append("mounted-start")
        self.phase = "pending"
    def stats(self): return self.fps
    def screenshot(self, name): self.shots.append(name)
    def live_frame(self, name):
        self.screenshot(name)
        return self.visible_probe
    def type_challenge(self, nonce):
        self.calls.append("phone-keys")
        self.keys.append({"kind": "key", "t": -1 if self.stale else self.now, "chars": nonce})
    def close(self):
        self.calls.append("mounted-stop")
        if not self.sticky: self.phase = "stopped"
    def back_on_page(self): return True
    def hub(self, params):
        if params["action"] == "decide":
            self.calls.append("approval")
            self.phase = "live"
            return {"decided": "once"}
        pending = [{"id": "session", "viewer": "phone", "viewer_name": "wrong" if self.wrong_viewer else "Phone",
                    "scope": "full"}] if self.phase == "pending" else []
        live = {"id": "session", "viewer": "phone", "scope": "full", "connected": True} if self.phase == "live" else None
        return {"signed_in": True, "this_device": "host", "sharing": True,
                "host_session": live, "pending_requests": pending}
    def instance(self):
        return proof.ScreenProof(self, self.hub, lambda: self.keys, clock=self.clock,
                                 wall=self.clock, sleep=self.sleep, timeout=1)


class ProofTests(unittest.TestCase):
    def test_full_sequence_requires_host_input_and_stop(self):
        rig = Rig()
        receipt = rig.instance().run("Mac", "Phone", "abcxyz")
        self.assertTrue(receipt["passed"])
        self.assertEqual(rig.calls, ["mounted-start", "approval", "phone-keys", "mounted-stop"])
        self.assertEqual(rig.shots, ["live", "input", "stopped"])
        self.assertNotIn("session", receipt.values())

    def test_wrong_viewer_never_approved(self):
        rig = Rig(); rig.wrong_viewer = True
        with self.assertRaises(proof.ProofFailure): rig.instance().run("Mac", "Phone", "abc")
        self.assertEqual(rig.calls, ["mounted-start"])

    def test_zero_fps_never_claims_live_frame(self):
        rig = Rig(); rig.fps = "Direct · 0 fps · 0 KB/s"
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["live_frame"])
        self.assertNotIn("phone-keys", rig.calls)

    def test_positive_fps_with_blank_renderer_is_not_live(self):
        rig = Rig(); rig.visible_probe = False
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["live_frame"])
        self.assertNotIn("phone-keys", rig.calls)

    def test_stale_input_never_counts_as_reception(self):
        rig = Rig(); rig.stale = True
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["host_input"])

    def test_ui_dismissal_does_not_prove_host_stop(self):
        rig = Rig(); rig.sticky = True
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertTrue(attempt.receipt["viewer_stop"])
        self.assertFalse(attempt.receipt["host_stopped"])
        self.assertFalse(attempt.receipt["passed"])

    def test_session_ended_before_close_is_not_proven_stopped_by_phone(self):
        rig = Rig()
        original = rig.screenshot
        def screenshot(name):
            original(name)
            if name == "input": rig.phase = "stopped"
        rig.screenshot = screenshot
        attempt = rig.instance()
        with self.assertRaises(proof.ProofFailure): attempt.run("Mac", "Phone", "abc")
        self.assertFalse(attempt.receipt["viewer_stop"])
        self.assertNotIn("mounted-stop", rig.calls)

    def test_public_success_waits_for_simulator_cleanup_and_fails_on_teardown_error(self):
        for status in (0, 1):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                receipt = Rig().instance().run("Mac", "Phone", "abc")
                receipt["cleanup"] = True
                self.assertFalse(proof.export_receipt(receipt, directory))
                result = proof.main(["--finalize-cleanup", "--status", str(status), "--out", directory])
                public = json.loads((Path(directory) / "screen-sharing-proof.json").read_text())
                self.assertEqual(result, status)
                self.assertEqual(public["passed"], status == 0)
                self.assertEqual(public["simulator_cleanup"], status == 0)
                self.assertEqual(public["cleanup"], status == 0)

    def test_export_excludes_raw_files_and_rejects_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "private.log").write_text("account secret")
            receipt = Rig().instance().run("Mac", "Phone", "abc")
            receipt["cleanup"] = True
            receipt["simulator_cleanup"] = True
            self.assertTrue(proof.export_receipt(receipt, root))
            with zipfile.ZipFile(root / "evidence.zip") as archive:
                self.assertEqual(archive.namelist(), ["screen-sharing-proof.json"])
                self.assertTrue(json.loads(archive.read(archive.namelist()[0]))["passed"])
            with self.assertRaises(proof.ProofFailure):
                proof.export_receipt({**receipt, "account": "private"}, root)

    def test_incomplete_receipt_cannot_export_success(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(proof.export_receipt({"passed": True, "start": True}, directory))


class HostTests(unittest.TestCase):
    def setUp(self):
        self.host = proof.host_module()

    def test_artifact_requires_completed_verified_exact_source(self):
        source, digest = "a" * 40, "b" * 64
        job = dict(kind="cmux", state="done", source_digest=source,
                   source_tree_verified=True, artifact="sha256:" + digest, tag="capabc123")
        self.host.validate_job(job, source, digest)
        for field, value in (("state", "running"), ("source_digest", "c" * 40),
                             ("source_tree_verified", False), ("artifact", "sha256:" + "d" * 64),
                             ("tag", "next")):
            with self.subTest(field=field), self.assertRaises(self.host.HostFailure):
                self.host.validate_job({**job, field: value}, source, digest)

    def test_secure_enclave_failure_prevents_further_host_setup(self):
        with patch.object(self.host, "command", return_value="unavailable") as command:
            with self.assertRaisesRegex(self.host.HostFailure, "secure_enclave_unavailable"):
                self.host.preflight()
        self.assertEqual(command.call_count, 1)

    def make_host(self):
        instance = self.host.Host(Path("/tmp/owned.app"), {}, "/tmp/owned", ("account", "password"))
        instance.proc, instance.probe, instance.log = Mock(), Mock(), Mock()
        instance.owns_auth = True
        return instance

    def test_signout_is_read_back_before_owned_process_stop(self):
        instance = self.make_host()
        order = []
        def rpc(_socket, method):
            order.append(method)
            return {"ended": True} if method.endswith("end_session") else {"signed_in": False, "restoring": False}
        with patch.object(self.host, "rpc", side_effect=rpc), patch.object(self.host, "stop", side_effect=lambda p: order.append(p)):
            instance.__exit__()
        self.assertTrue(instance.cleanup_ok)
        self.assertEqual(order, [instance.probe, "debug.cloud.end_session", "auth.status", instance.proc])

    def test_failed_signout_still_stops_owned_app_and_fails_cleanup(self):
        instance = self.make_host()
        with patch.object(self.host, "rpc", side_effect=self.host.HostFailure("failure")), patch.object(self.host, "stop") as stop:
            instance.__exit__()
        self.assertFalse(instance.cleanup_ok)
        stop.assert_any_call(instance.proc)

    def test_preexisting_auth_is_never_signed_out(self):
        instance = self.make_host(); instance.owns_auth = False
        with patch.object(self.host, "rpc") as rpc, patch.object(self.host, "stop"):
            instance.__exit__()
        rpc.assert_not_called()

    def test_shell_teardown_failure_invalidates_public_receipt(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "scripts/ci/cmux-next-ios-sim.sh").read_text()
        cleanup = source[source.index("cleanup() {"):source.index("trap cleanup EXIT")]
        for fails in (False, True):
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                sims, out = work / "sims", work / "out"
                sims.mkdir()
                receipt = Rig().instance().run("Mac", "Phone", "abc")
                receipt["cleanup"] = True
                proof.export_receipt(receipt, out)
                script = ('set -euo pipefail\nmode=screen-proof\nsims="$1"\nout="$2"\n'
                          'xcodegen_dir=""\nwork=""\nxcrun() { return ' + str(int(fails)) + '; }\n'
                          + cleanup + '\ntrap cleanup EXIT\nexit 0\n')
                result = subprocess.run(["bash", "-c", script, "proof-cleanup", str(sims), str(out)],
                                        cwd=root, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, int(fails), result.stderr)
                with zipfile.ZipFile(out / "evidence.zip") as archive:
                    public = json.loads(archive.read("screen-sharing-proof.json"))
                self.assertEqual(public["passed"], not fails)
                self.assertFalse(sims.exists())

    def test_missing_cleanup_cannot_publish_green(self):
        receipt = Rig().instance().run("Mac", "Phone", "abc")
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(proof.export_receipt(receipt, directory))

    def test_public_string_fields_cannot_contain_private_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(proof.ProofFailure):
                proof.export_receipt({"error_code": "secret@example.test"}, directory)


if __name__ == "__main__":
    unittest.main()
